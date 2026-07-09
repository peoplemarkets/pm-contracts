#!/usr/bin/env bash
# Fix C — phased bonded-asserter runbook the platform runs to self-bond a UMA event resolution.
#
# Finalizes a UMA-source event market: approve the bond, propose the assertion (posting the bond),
# wait the metric's liveness window, settle the assertion on UMA, then finalize the market via
# EventMarket.settleResolution().
#
#   NOTE: proposeAssertion PULLS the bond from the asserter (ASSERTER_PK). UMA refunds the bond on a
#   truthful (undisputed) assertion and SLASHES it on a lost dispute. Only assert an outcome you can
#   defend. Also: unfreeze/settle the subject lifecycle before settling its event markets — a frozen
#   subject blocks settleResolution (the feedback hop reverts) for BOTH UMA and objective markets.
#
# Phases (each write SIMULATES first, then broadcasts):
#   approve  -> usdc.approve(umaAdapter, bond)
#   propose  -> umaAdapter.proposeAssertion(eventId, outcome, claim); prints assertionId + expiresAt
#   ...wait the metric's LIVENESS window...
#   settle   -> umaAdapter.settleAssertion(assertionId); EventMarket.settleResolution()
#
# Usage:
#   export ASSERTER_PK=0x<self-bonding asserter key>
#   export UMA_ADAPTER=0x<umaAdapter proxy>
#   export EVENT_ID=0x<bytes32 eventId>
#   export OUTCOME=1                 # 1=YES 2=NO 3=VOID
#   export MARKET_ADDRESS=0x<EventMarket clone>
#   [export BOND=1000000]            # must match the metric's configured bond
#   [export BOND_CURRENCY=<usdc>]    # defaults to $USDC
#   [export SEPOLIA_RPC=<dedicated rpc>]
#
#   ./script/assert-event-resolution-sepolia.sh approve
#   ./script/assert-event-resolution-sepolia.sh propose
#   export ASSERTION_ID=0x...        # from propose output
#   ...wait LIVENESS...
#   ./script/assert-event-resolution-sepolia.sh settle
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
export BOND="${BOND:-1000000}"
export BOND_CURRENCY="${BOND_CURRENCY:-$USDC}"

S="script/AssertEventResolution.s.sol:AssertEventResolution"

need() { [ -n "${!1:-}" ] || { echo "ERROR: export $1 first"; exit 1; }; }

run_forge() { # <--sig 'fn()'>
  echo "── simulate: $S $* ──"
  forge script "$S" "$@" --rpc-url "$RPC"
  echo "── broadcast: $S $* ──"
  forge script "$S" "$@" --rpc-url "$RPC" --broadcast
}

case "${1:-}" in
  approve)
    need ASSERTER_PK; need UMA_ADAPTER; need BOND_CURRENCY
    run_forge --sig 'approve()'
    echo ">>> next: $0 propose"
    ;;
  propose)
    need ASSERTER_PK; need UMA_ADAPTER; need EVENT_ID; need OUTCOME
    run_forge --sig 'propose()'
    echo ">>> export ASSERTION_ID (from output), wait the metric LIVENESS, then: $0 settle"
    ;;
  settle)
    need ASSERTER_PK; need UMA_ADAPTER; need ASSERTION_ID; need MARKET_ADDRESS
    run_forge --sig 'settle()'
    echo "market outcome (1=YES 2=NO 3=VOID):"
    cast call "$MARKET_ADDRESS" 'outcome()(uint8)' --rpc-url "$RPC"
    ;;
  *)
    echo "usage: $0 {approve|propose|settle}"
    exit 1
    ;;
esac
