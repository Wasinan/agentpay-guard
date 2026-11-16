#!/usr/bin/env node
/**
 * AgentPay Guard — demo payment agent.
 *
 * A deterministic, rule-based proposer: it reads a batch of invoices,
 * checks each one against the on-chain session guardrails BEFORE sending
 * anything (revoked? expired? recipient allowlisted? within per-payment
 * and total caps? vault funded?), logs every decision with its reason,
 * and executes only the payments that pass every check.
 *
 * The guardrails are enforced twice: once here (so the agent never wastes
 * gas on a doomed transaction) and once in AgentVault.executePayment
 * (so a compromised or buggy agent still cannot exceed them).
 *
 * No external AI API is required. An optional LLM review hook
 * (reviewWithLLM) is provided as a documented stub: wire it to any
 * OpenAI-compatible endpoint to add a second opinion on invoice
 * legitimacy. The hook can only REJECT a payment, never approve one
 * the policy checks rejected — the on-chain guardrails stay final.
 *
 * Usage (local anvil demo):
 *   node agent/agent.mjs                  # decide + execute
 *   node agent/agent.mjs --dry-run        # decide only, no transactions
 *
 * Config via environment:
 *   RPC_URL        default http://127.0.0.1:8545
 *   VAULT_ADDRESS  default: read from broadcast/DeployLocal.s.sol/31337/run-latest.json
 *   SESSION_ID     default 0
 *   AGENT_KEY      default: anvil's well-known test account #1 key
 *                  (public test key, local chains only — never use on
 *                  any network with real value; on Aevum, use a
 *                  dedicated session key with no other funds)
 *   INVOICES_FILE  default agent/invoices.json
 */

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

const VAULT_ABI = [
  "function getSession(uint256) view returns (address agent, uint256 cap, uint256 perTxCap, uint256 expiry, uint256 spent, bool revoked, address[] recipients)",
  "function remainingCap(uint256) view returns (uint256)",
  "function isRecipientAllowed(uint256, address) view returns (bool)",
  "function vaultBalance() view returns (uint256)",
  "function executePayment(uint256 sessionId, address to, uint256 amount, string memo)",
  "function sessionCount() view returns (uint256)",
];

const AEVUM_CHAIN_ID = 44005n;
const AEVUM_EXPLORER = "https://explorer-test.qday.info";
const ANVIL_AGENT_KEY =
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"; // anvil account #1 — local test key only

// ---------------------------------------------------------------------------
// Optional LLM review hook (disabled by default).
// Return { approve: false, reason } to veto a payment, or null to abstain.
// It can never override a policy rejection, and a null return means the
// deterministic policy decision stands on its own.
// ---------------------------------------------------------------------------
async function reviewWithLLM(_invoice, _session) {
  // Not wired up: set LLM_REVIEW=1 and implement a call to your
  // OpenAI-compatible endpoint here. Keep the veto-only contract.
  return null;
}

function loadVaultAddress(rpcUrl) {
  if (process.env.VAULT_ADDRESS) return process.env.VAULT_ADDRESS;
  const artifact = join(
    ROOT,
    "broadcast/DeployLocal.s.sol/31337/run-latest.json",
  );
  if (!existsSync(artifact)) {
    throw new Error(
      "No VAULT_ADDRESS set and no local broadcast artifact found. " +
        "Run the local deploy first (see README), or set VAULT_ADDRESS.",
    );
  }
  const run = JSON.parse(readFileSync(artifact, "utf8"));
  const deploy = run.transactions.find((t) => t.contractName === "AgentVault");
  if (!deploy) throw new Error("AgentVault deployment not found in broadcast artifact.");
  return deploy.contractAddress;
}

function fmt(amount) {
  return ethers.formatUnits(amount, 6);
}

async function main() {
  const dryRun = process.argv.includes("--dry-run");
  const rpcUrl = process.env.RPC_URL || "http://127.0.0.1:8545";
  const sessionId = BigInt(process.env.SESSION_ID || "0");
  const isLocal = rpcUrl.includes("127.0.0.1") || rpcUrl.includes("localhost");
  const agentKey = process.env.AGENT_KEY || (isLocal ? ANVIL_AGENT_KEY : null);
  if (!agentKey) {
    console.error("AGENT_KEY env var is required for non-local RPC URLs.");
    process.exit(1);
  }
  const invoicesFile = process.env.INVOICES_FILE || join(ROOT, "agent/invoices.json");

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const network = await provider.getNetwork();
  const vaultAddress = loadVaultAddress(rpcUrl);
  const wallet = new ethers.Wallet(agentKey, provider);
  const vault = new ethers.Contract(vaultAddress, VAULT_ABI, wallet);

  console.log("== AgentPay Guard — payment agent ==");
  console.log(`chain: ${network.name} (${network.chainId})  vault: ${vaultAddress}`);
  console.log(`agent: ${wallet.address}  session: ${sessionId}  mode: ${dryRun ? "DRY RUN" : "EXECUTE"}`);

  const session = await vault.getSession(sessionId);
  if (session.agent.toLowerCase() !== wallet.address.toLowerCase()) {
    throw new Error(
      `This wallet (${wallet.address}) is not the session agent (${session.agent}). Refusing to run.`,
    );
  }
  const now = Math.floor(Date.now() / 1000);
  console.log(
    `session: cap ${fmt(session.cap)}  per-tx ${fmt(session.perTxCap)}  spent ${fmt(session.spent)}  ` +
      `remaining ${fmt(await vault.remainingCap(sessionId))}  expires in ${Math.max(0, Number(session.expiry) - now)}s  ` +
      `revoked: ${session.revoked}`,
  );

  const { invoices } = JSON.parse(readFileSync(invoicesFile, "utf8"));
  const proposals = [];

  // Track the nonce explicitly: querying it fresh for every transaction
  // races on fast local chains (anvil auto-mines), producing duplicate
  // nonces. One sequential counter, incremented only after a send is
  // accepted, is deterministic on anvil and on Aevum alike.
  let nextNonce = await provider.getTransactionCount(wallet.address, "pending");

  for (const inv of invoices) {
    const amount = ethers.parseUnits(inv.amount, 6);
    const decision = { id: inv.id, payee: inv.payee, payeeName: inv.payeeName, amount: inv.amount, memo: inv.memo };
    let reason = null;

    // Re-read live state before each decision: earlier payments in this
    // batch reduce the remaining cap.
    const live = await vault.getSession(sessionId);
    const remaining = await vault.remainingCap(sessionId);
    const balance = await vault.vaultBalance();
    const allowed = await vault.isRecipientAllowed(sessionId, inv.payee);

    if (live.revoked) reason = "session revoked";
    else if (BigInt(now) > live.expiry) reason = "session expired";
    else if (!allowed) reason = "recipient not on session allowlist";
    else if (amount > live.perTxCap) reason = `amount ${inv.amount} exceeds per-payment cap ${fmt(live.perTxCap)}`;
    else if (amount > remaining) reason = `amount ${inv.amount} exceeds remaining session cap ${fmt(remaining)}`;
    else if (amount > balance) reason = `amount ${inv.amount} exceeds vault balance ${fmt(balance)}`;

    if (!reason && process.env.LLM_REVIEW === "1") {
      const veto = await reviewWithLLM(inv, live);
      if (veto && veto.approve === false) reason = `LLM review veto: ${veto.reason}`;
    }

    if (reason) {
      decision.status = "rejected";
      decision.reason = reason;
      console.log(`[REJECT] ${inv.id} -> ${inv.payeeName} ${inv.amount} tUSD8 — ${reason}`);
    } else if (dryRun) {
      decision.status = "approved (dry run — not executed)";
      decision.reason = "passes all guardrails";
      console.log(`[WOULD PAY] ${inv.id} -> ${inv.payeeName} ${inv.amount} tUSD8 — passes all guardrails`);
    } else {
      try {
        const tx = await vault.executePayment(sessionId, inv.payee, amount, inv.memo, { nonce: nextNonce });
        nextNonce += 1;
        const receipt = await tx.wait();
        decision.status = "executed";
        decision.reason = "passes all guardrails";
        decision.txHash = receipt.hash;
        decision.explorerUrl =
          network.chainId === AEVUM_CHAIN_ID ? `${AEVUM_EXPLORER}/tx/${receipt.hash}` : null;
        console.log(`[PAID] ${inv.id} -> ${inv.payeeName} ${inv.amount} tUSD8 — tx ${receipt.hash}`);
      } catch (err) {
        decision.status = "failed";
        decision.reason = `on-chain revert: ${err.shortMessage || err.message}`;
        console.log(`[FAILED] ${inv.id} — ${decision.reason}`);
      }
    }
    proposals.push(decision);
  }

  // Publish the proposal log where the demo UI can show it.
  const outPath = join(ROOT, "web/proposals.json");
  writeFileSync(outPath, JSON.stringify({ generatedAt: new Date().toISOString(), vault: vaultAddress, sessionId: sessionId.toString(), proposals }, null, 2));
  console.log(`\nproposal log written to web/proposals.json`);

  const paid = proposals.filter((p) => p.status === "executed").length;
  const rejected = proposals.filter((p) => p.status === "rejected").length;
  console.log(`summary: ${paid} paid, ${rejected} rejected, ${proposals.length - paid - rejected} other`);
  console.log(`vault balance now: ${fmt(await vault.vaultBalance())} tUSD8 | session remaining: ${fmt(await vault.remainingCap(sessionId))} tUSD8`);
}

main().catch((err) => {
  console.error("agent error:", err.shortMessage || err.message);
  process.exit(1);
});
