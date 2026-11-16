#!/usr/bin/env bash
# Local end-to-end demo of AgentPay Guard on anvil.
#
# Flow: deploy mock tUSD8 + vault -> fund vault -> grant the agent a
# scoped session -> agent dry-run -> agent executes the invoice batch ->
# verify balances -> owner revokes the session -> agent re-run proves
# the revoked session can no longer pay.
#
# Requires: anvil, forge, cast, node. No secrets: anvil's well-known
# local test keys only. Run from the repo root:
#   bash scripts-local/run-e2e.sh
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
AGENT=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
RPC=http://127.0.0.1:8545

echo "== 1. starting anvil =="
anvil --silent > /tmp/agentpay-anvil.log 2>&1 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
sleep 2

echo "== 2. deploying MockTUSD8 + AgentVault =="
forge script script/DeployLocal.s.sol --rpc-url $RPC --sender $OWNER --unlocked --broadcast --silent

TOKEN=$(node -e "const r=require('./broadcast/DeployLocal.s.sol/31337/run-latest.json'); console.log(r.transactions.find(t=>t.contractName==='MockTUSD8').contractAddress)")
VAULT=$(node -e "const r=require('./broadcast/DeployLocal.s.sol/31337/run-latest.json'); console.log(r.transactions.find(t=>t.contractName==='AgentVault').contractAddress)")
echo "token: $TOKEN"
echo "vault: $VAULT"

echo "== 3. owner funds the vault with 1000 tUSD8 =="
cast send "$TOKEN" "approve(address,uint256)" "$VAULT" 1000000000 --unlocked --from $OWNER --rpc-url $RPC --silent > /dev/null
cast send "$VAULT" "deposit(uint256)" 1000000000 --unlocked --from $OWNER --rpc-url $RPC --silent > /dev/null
echo "vault balance: $(cast call "$VAULT" "vaultBalance()" --rpc-url $RPC) base units (6 decimals)"

echo "== 4. owner grants the agent a session: cap 500, per-tx 200, 24h, allowlist 3 payees =="
EXPIRY=$(( $(date +%s) + 86400 ))
cast send "$VAULT" \
  "createSession(address,uint256,uint256,uint256,address[])" \
  "$AGENT" 500000000 200000000 "$EXPIRY" \
  "[0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,0x90F79bf6EB2c4f870365E785982E1f101E93b906,0x15d34AAf54267DB7EE8cD6fB0802D8c9E47e9F11]" \
  --unlocked --from $OWNER --rpc-url $RPC --silent > /dev/null
echo "session 0 created"

echo "== 5. agent dry-run (decisions only) =="
VAULT_ADDRESS=$VAULT node agent/agent.mjs --dry-run

echo "== 6. agent executes the invoice batch =="
VAULT_ADDRESS=$VAULT node agent/agent.mjs

echo "== 7. verify payee balances =="
for addr in 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 0x90F79bf6EB2c4f870365E785982E1f101E93b906 0x15d34AAf54267DB7EE8cD6fB0802D8c9E47e9F11 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc; do
  echo "$addr -> $(cast call "$TOKEN" "balanceOf(address)" "$addr" --rpc-url $RPC) base units"
done

echo "== 8. owner revokes the session; agent re-run must reject everything =="
cast send "$VAULT" "revokeSession(uint256)" 0 --unlocked --from $OWNER --rpc-url $RPC --silent > /dev/null
VAULT_ADDRESS=$VAULT node agent/agent.mjs || true

echo "== e2e complete =="
