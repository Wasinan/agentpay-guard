# Demo script — AgentPay Guard (3–5 minute video demo)

Target: show one complete payment flow end to end on Aevum testnet, with the
guardrails visibly working. Rehearse once against the local anvil run, then
record against testnet. Total target: under 4 minutes.

## Before recording

1. Vault deployed on Aevum; address pasted into `web/index.html` (`VAULT_ADDRESS`) and the UI served (or open the file directly — it only needs a wallet).
2. MetaMask on Aevum Testnet (chain 44005), funded with tQDAY from the faucet.
3. Vault funded with 1,000 tUSD8; session #0 granted to the demo agent key:
   cap 500, per-payment cap 200, expiry +24h, allowlist = the 3 demo payees.
4. `agent/invoices.json` holds the 4 demo invoices (2 payable, 1 over-cap,
   1 non-allowlisted). Terminal ready to run the agent.
5. Aevum explorer open in a second tab for the audit-link click.

## Click path (narration cues in italics)

**0:00–0:30 — The problem (UI open, no clicks yet)**
*"AI agents can pay now. The question is what stops one from paying too much,
to the wrong address, or after you changed your mind. This vault answers that
on-chain."*
Point at the vault balance and the session card: cap, per-payment cap, expiry
countdown, allowlist.

**0:30–1:00 — Grant (already done) + the agent's decisions**
Switch to the terminal. Run `node agent/agent.mjs --dry-run`.
*"The agent checks every guardrail before sending anything. Two invoices pass.
One is over the per-payment cap, one payee isn't allowlisted — both rejected,
with reasons, before any gas is spent."*

**1:00–2:00 — Execute**
Run `node agent/agent.mjs`.
*"Same batch, live. Two payments land on-chain."* Note the two tx hashes in
the terminal. Refresh the UI: vault balance drops 1,000 → 670, session spent
330 / 500, remaining 170. Open the Proposals panel: 2 paid, 2 rejected.

**2:00–2:45 — The audit trail**
Scroll to the audit log. Click one PaymentExecuted tx link → explorer opens
showing the transfer. *"Every payment is a permanent, verifiable record —
amount, recipient, invoice memo, session."*

**2:45–3:30 — The kill switch**
Back in the UI, click **Revoke session instantly**, confirm in MetaMask.
Re-run the agent in the terminal: all four invoices rejected, "session
revoked". *"One click and the agent can never pay again. The remaining funds
stay in the vault, withdrawable by the owner."* Optionally withdraw the
remaining 670 to show the funds were never locked.

**3:30–4:00 — Close**
*"Caps, expiry, allowlist, revocation, audit trail — all enforced by the
contract, not by the agent's goodwill. That's AgentPay Guard."*
End on the UI showing the revoked session and the audit log.

## If something goes wrong live

- Agent shows "session revoked/expired": grant a fresh session from the UI
  (form on the right) and re-run with the new `SESSION_ID`.
- MetaMask on the wrong chain: the UI's network selector switches/adds Aevum
  automatically on connect.
- No tQDAY for gas: faucet at https://faucet.qday.info (once per 24h).
- Fallback: the full local run is one command — `bash scripts-local/run-e2e.sh`
  — and reproduces the entire story on anvil, including revocation.
