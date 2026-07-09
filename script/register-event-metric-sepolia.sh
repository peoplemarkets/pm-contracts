#!/usr/bin/env bash
# Fix C — phased UMA metric-registration runbook for a Base Sepolia event market.
#
# eventId IS the UMA metricId. A market cannot settle (and, post Fix D, cannot even be CREATED)
# until its metric is registered on the UMAAdapter via the two-step governance timelock.
#
# Phases (each write SIMULATES first, then broadcasts):
#   propose  -> UMAAdapter.proposeRegisterMetric(eventId, bond, liveness, identifier, currency)
#   ...wait TIMELOCK_DELAY (adapter floor 1h)...
#   activate -> UMAAdapter.activateRegisterMetric(eventId)  (asserts metricOf().registered)
#   verify   -> read-only: requires registered == true
#
# Usage:
#   export DEPLOYER_PK=0x<UMAAdapter governance key>
#   export UMA_ADAPTER=0x<umaAdapter proxy>
#   export EVENT_ID=0x<bytes32 eventId == metricId>
#   [export BOND=1000000]                        # default 1 USDC (MIN_BOND)
#   [export LIVENESS=7200]                       # default 2h dispute window
#   [export UMA_IDENTIFIER=0x4153534552545f54525554480000...]  # default bytes32("ASSERT_TRUTH")
#   [export BOND_CURRENCY=<usdc>]                # defaults to $USDC
#   [export SEPOLIA_RPC=<dedicated rpc>]
#
#   ./script/register-event-metric-sepolia.sh propose
#   ...wait 1 hour...
#   ./script/register-event-metric-sepolia.sh activate
#   ./script/register-event-metric-sepolia.sh verify
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

RPC="${SEPOLIA_RPC:-${BASE_SEPOLIA_RPC_URL:-https://sepolia.base.org}}"

export USDC="${USDC:-0x036CbD53842c5426634e7929541eC2318f3dCF7e}"
export BOND="${BOND:-1000000}"                 # 1 USDC
export LIVENESS="${LIVENESS:-7200}"            # 2h
# bytes32("ASSERT_TRUTH")
export UMA_IDENTIFIER="${UMA_IDENTIFIER:-0x4153534552545f545255544800000000000000000000000000000000000000}"
export BOND_CURRENCY="${BOND_CURRENCY:-$USDC}"

S="script/RegisterEventMetric.s.sol:RegisterEventMetric"

need() { [ -n "${!1:-}" ] || { echo "ERROR: export $1 first"; exit 1; }; }

run_forge() { # <--sig 'fn()'>
  echo "── simulate: $S $* ──"
  forge script "$S" "$@" --rpc-url "$RPC"
  echo "── broadcast: $S $* ──"
  forge script "$S" "$@" --rpc-url "$RPC" --broadcast
}

case "${1:-}" in
  propose)
    need DEPLOYER_PK; need UMA_ADAPTER; need EVENT_ID
    run_forge --sig 'propose()'
    echo ">>> wait TIMELOCK_DELAY (adapter floor 1h), then: $0 activate"
    ;;
  activate)
    need DEPLOYER_PK; need UMA_ADAPTER; need EVENT_ID
    run_forge --sig 'activate()'
    echo ">>> next: $0 verify"
    ;;
  verify)
    need UMA_ADAPTER; need EVENT_ID
    echo "── verify (read-only) ──"
    forge script "$S" --sig 'verify()' --rpc-url "$RPC"
    echo "metricOf(eventId).registered:"
    cast call "$UMA_ADAPTER" 'metricOf(bytes32)((uint256,uint64,bytes32,address,bool))' "$EVENT_ID" --rpc-url "$RPC"
    ;;
  *)
    echo "usage: $0 {propose|activate|verify}"
    exit 1
    ;;
esac
