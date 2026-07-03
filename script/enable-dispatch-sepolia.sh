#!/usr/bin/env bash
# Enable the custodial event-dispatch path on Base Sepolia (pm-engine #10, ops leg).
#
# On-chain state this assumes (verified 2026-07-03):
#   - LPVault proxy 0x6347… already upgraded to the event-markets impl
#   - vault.eventMarketFactory already set to the live factory 0xb73f…
#   => only the Router deploy + operator allowlisting remain.
#
# Usage:
#   export DEPLOYER_PK=0x<governance private key>   # 0x0183A2e2F30264ebB89995854e09Bab51Ca251bE
#   export EVENT_OPERATOR=0x<engine operator address>
#   [export SEPOLIA_RPC=<dedicated rpc>]            # defaults to https://sepolia.base.org
#
#   ./script/enable-dispatch-sepolia.sh deploy      # deploy router (prints EVENT_MARKET_ROUTER)
#   export EVENT_MARKET_ROUTER=0x<router proxy from deploy output>
#   ./script/enable-dispatch-sepolia.sh propose     # propose both operator grants
#   ...wait 1 hour (router timelock floor)...
#   ./script/enable-dispatch-sepolia.sh activate    # activate both grants
#   ./script/enable-dispatch-sepolia.sh verify      # read-only sanity checks
#
# Every write step runs a SIMULATION first and aborts if it fails.
set -euo pipefail
cd "$(dirname "$0")/.."

# Pick up repo .env (DEPLOYER_PK, GOVERNANCE, USDC, TIMELOCK_DELAY, EVENT_OPERATOR, …).
# .env is the source of truth here — its values override prior shell exports.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

RPC="${SEPOLIA_RPC:-${BASE_SEPOLIA_RPC_URL:-https://sepolia.base.org}}"

# Fixed Base Sepolia wiring (from pm-infra registry + on-chain verification).
export GOVERNANCE="${GOVERNANCE:-0x0183A2e2F30264ebB89995854e09Bab51Ca251bE}"
export EVENT_MARKET_FACTORY="${EVENT_MARKET_FACTORY:-0xb73fed3c858ce69376c349c17368f4ff1726ffbf}"
export USDC="${USDC:-0x036CbD53842c5426634e7929541eC2318f3dCF7e}"
export TIMELOCK_DELAY="${TIMELOCK_DELAY:-3600}"

need() { [ -n "${!1:-}" ] || { echo "ERROR: export $1 first"; exit 1; }; }

run_forge() { # <script:contract> [--sig 'fn()']
  echo "── simulate: $* ──"
  forge script "$@" --rpc-url "$RPC"
  echo "── broadcast: $* ──"
  forge script "$@" --rpc-url "$RPC" --broadcast
}

case "${1:-}" in
  deploy)
    need DEPLOYER_PK
    run_forge script/DeployEventRouter.s.sol:DeployEventRouter
    echo
    echo ">>> export EVENT_MARKET_ROUTER=<EventMarketRouter Proxy printed above>, then: $0 propose"
    ;;
  propose)
    need DEPLOYER_PK; need EVENT_MARKET_ROUTER; need EVENT_OPERATOR
    run_forge script/EnableEventOperator.s.sol:EnableEventOperator --sig 'propose()'
    echo
    echo ">>> wait 1 hour (router timelock floor), then: $0 activate"
    ;;
  activate)
    need DEPLOYER_PK; need EVENT_MARKET_ROUTER; need EVENT_OPERATOR
    run_forge script/EnableEventOperator.s.sol:EnableEventOperator --sig 'activate()'
    "$0" verify
    ;;
  verify)
    need EVENT_MARKET_ROUTER; need EVENT_OPERATOR
    V=0x6347e37ee6597a99de63eb00f469d19771ae41f2
    echo "vault.eventMarketFactory (want $EVENT_MARKET_FACTORY):"
    cast call "$V" "eventMarketFactory()(address)" --rpc-url "$RPC"
    echo "factory.isOperator(router) (want true):"
    cast call "$EVENT_MARKET_FACTORY" "isOperator(address)(bool)" "$EVENT_MARKET_ROUTER" --rpc-url "$RPC"
    echo "router.isOperator(EVENT_OPERATOR) (want true):"
    cast call "$EVENT_MARKET_ROUTER" "isOperator(address)(bool)" "$EVENT_OPERATOR" --rpc-url "$RPC"
    echo "operator ETH balance (needs gas):"
    cast balance "$EVENT_OPERATOR" --rpc-url "$RPC"
    ;;
  *)
    echo "usage: $0 {deploy|propose|activate|verify}"; exit 1
    ;;
esac
