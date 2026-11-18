#!/usr/bin/env bash
# Deploy mocks + AgentPolicyDesk to a local unlocked node (anvil).
# Does not read or embed a private key. The sender must be unlocked on that node.
set -euo pipefail

RPC="${1:-http://127.0.0.1:8545}"
SENDER="${2:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"

forge script script/DeployLocal.s.sol:DeployLocal \
  --rpc-url "$RPC" \
  --broadcast \
  --unlocked \
  --sender "$SENDER"
