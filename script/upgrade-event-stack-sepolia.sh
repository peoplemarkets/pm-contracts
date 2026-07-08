#!/usr/bin/env bash
# In-place UPGRADE ceremony for the LIVE Base Sepolia event-market stack.
#
#   >>> RUN THE FORK TEST FIRST — it is the safety gate. The LPVault proxy also backs LIVE perp
#   >>> positions, so this ceremony must not move its NAV / share price. Do not run any broadcast
#   >>> phase until the fork test is green:
#   >>>
#   >>>   BASE_SEPOLIA_RPC_URL=https://sepolia.base.org \
#   >>>     forge test --match-contract UpgradeCeremonyFork -vvv
#
# What this upgrades (all IN PLACE, storage-compat to current main verified GO / append-only):
#   - LPVault proxy            0x6347E37eE6597A99DE63eb00F469d19771AE41F2  -> new LPVault impl (#13 NAV fix)
#   - EventMarketFactory proxy 0xb73feD3C858CE69376C349c17368f4Ff1726ffBF  -> new factory impl (operator relay + timelocked setMarketImpl)
#   - EventMarket clone template (via factory.setMarketImplementation)     -> new EventMarket (buyOutcomeFor/sellOutcomeFor + fixed priceOf + currentRecoverable)
# Then allowlists the operator relay path (router->factory, EVENT_OPERATOR->router).
#
# Phases (each write SIMULATES first, then broadcasts; read-only cast checks run between steps):
#   deploy                  -> deploy the 3 new impls (prints their addresses)
#   upgrade                 -> upgradeToAndCall on the LPVault + Factory proxies (asserts perp reads unchanged)
#   set-market-impl-propose -> factory.proposeSetMarketImplementation(new EventMarket)
#   ...wait 1 hour (factory timelockDelay = 3600s)...
#   set-market-impl-activate-> factory.activateSetMarketImplementation()
#   operator-propose        -> factory.proposeAddOperator(router) + router.proposeAddOperator(EVENT_OPERATOR)
#   ...wait 1 hour (router MIN_TIMELOCK_DELAY floor)...
#   operator-activate       -> activateAddOperator on both
#   verify                  -> read-only sanity checks
#
# Usage:
#   export DEPLOYER_PK=0x<governance private key>   # 0x0183A2e2F30264ebB89995854e09Bab51Ca251bE
#   export EVENT_OPERATOR=0xbFE20c727F50003C8DBa8CF5E0C297670FE2390E
#   [export SEPOLIA_RPC=<dedicated rpc>]            # defaults to https://sepolia.base.org
#
#   ./script/upgrade-event-stack-sepolia.sh deploy
#   export NEW_LPVAULT_IMPL=0x...  NEW_FACTORY_IMPL=0x...  NEW_EVENT_MARKET_IMPL=0x...  # from deploy output
#   ./script/upgrade-event-stack-sepolia.sh upgrade
#   ./script/upgrade-event-stack-sepolia.sh set-market-impl-propose
#   ...wait 1 hour...
#   ./script/upgrade-event-stack-sepolia.sh set-market-impl-activate
#   ./script/upgrade-event-stack-sepolia.sh operator-propose
#   ...wait 1 hour...
#   ./script/upgrade-event-stack-sepolia.sh operator-activate
#   ./script/upgrade-event-stack-sepolia.sh verify
set -euo pipefail
cd "$(dirname "$0")/.."

# Pick up repo .env (DEPLOYER_PK, USDC, TIMELOCK_DELAY, EVENT_OPERATOR, …).
# .env is the source of truth — its values override prior shell exports.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

RPC="${SEPOLIA_RPC:-${BASE_SEPOLIA_RPC_URL:-https://sepolia.base.org}}"

# Fixed Base Sepolia wiring (deployed proxies; from pm-infra registry + on-chain verification).
export LP_VAULT_ADDRESS="${LP_VAULT_ADDRESS:-0x6347E37eE6597A99DE63eb00F469d19771AE41F2}"
export EVENT_MARKET_FACTORY="${EVENT_MARKET_FACTORY:-0xb73feD3C858CE69376C349c17368f4Ff1726ffBF}"
export EVENT_MARKET_ROUTER="${EVENT_MARKET_ROUTER:-0x0AE0E0744ACD79a26F5ACC5c8Ec8231Bc47d7a16}"
export GOVERNANCE="${GOVERNANCE:-0x0183A2e2F30264ebB89995854e09Bab51Ca251bE}"
export USDC="${USDC:-0x036CbD53842c5426634e7929541eC2318f3dCF7e}"
export TIMELOCK_DELAY="${TIMELOCK_DELAY:-3600}"

S="script/UpgradeEventStack.s.sol:UpgradeEventStack"

need() { [ -n "${!1:-}" ] || { echo "ERROR: export $1 first"; exit 1; }; }

run_forge() { # <--sig 'fn()'>
  echo "── simulate: $S $* ──"
  forge script "$S" "$@" --rpc-url "$RPC"
  echo "── broadcast: $S $* ──"
  forge script "$S" "$@" --rpc-url "$RPC" --broadcast
}

# Read-only vault perp snapshot (money-safety visibility around the upgrade).
vault_reads() {
  echo "vault.totalAssets()        : $(cast call "$LP_VAULT_ADDRESS" 'totalAssets()(uint256)' --rpc-url "$RPC")"
  echo "vault.convertToAssets(1e18): $(cast call "$LP_VAULT_ADDRESS" 'convertToAssets(uint256)(uint256)' 1000000000000000000 --rpc-url "$RPC")"
  echo "vault.positionCollateral() : $(cast call "$LP_VAULT_ADDRESS" 'positionCollateral()(uint256)' --rpc-url "$RPC")"
  echo "vault.freeAssets()         : $(cast call "$LP_VAULT_ADDRESS" 'freeAssets()(uint256)' --rpc-url "$RPC")"
  echo "vault.liveEventMarketCount : $(cast call "$LP_VAULT_ADDRESS" 'liveEventMarketCount()(uint256)' --rpc-url "$RPC")"
}

case "${1:-}" in
  deploy)
    need DEPLOYER_PK
    echo ">>> Reminder: the fork test (UpgradeCeremonyFork) MUST be green before broadcasting further phases."
    run_forge --sig 'deploy()'
    echo
    echo ">>> export NEW_LPVAULT_IMPL / NEW_FACTORY_IMPL / NEW_EVENT_MARKET_IMPL (from output), then: $0 upgrade"
    ;;
  upgrade)
    need DEPLOYER_PK; need NEW_LPVAULT_IMPL; need NEW_FACTORY_IMPL
    echo "── vault perp reads BEFORE upgrade ──"; vault_reads
    run_forge --sig 'upgrade()'
    echo "── vault perp reads AFTER upgrade (totalAssets/pps/positionCollateral MUST match above) ──"; vault_reads
    echo ">>> next: $0 set-market-impl-propose"
    ;;
  set-market-impl-propose)
    need DEPLOYER_PK; need NEW_EVENT_MARKET_IMPL
    run_forge --sig 'proposeSetMarketImpl()'
    echo "pending marketImpl activatesAt: $(cast call "$EVENT_MARKET_FACTORY" 'pendingMarketImplementationActivatesAt()(uint64)' --rpc-url "$RPC")"
    echo ">>> wait 1 hour (factory timelockDelay = ${TIMELOCK_DELAY}s), then: $0 set-market-impl-activate"
    ;;
  set-market-impl-activate)
    need DEPLOYER_PK
    run_forge --sig 'activateSetMarketImpl()'
    echo "factory.marketImplementation(): $(cast call "$EVENT_MARKET_FACTORY" 'marketImplementation()(address)' --rpc-url "$RPC")"
    echo "  (want == NEW_EVENT_MARKET_IMPL = ${NEW_EVENT_MARKET_IMPL:-<unset>})"
    echo ">>> next: $0 operator-propose"
    ;;
  operator-propose)
    need DEPLOYER_PK; need EVENT_OPERATOR
    run_forge --sig 'proposeOperators()'
    echo ">>> wait 1 hour (router MIN_TIMELOCK_DELAY floor), then: $0 operator-activate"
    ;;
  operator-activate)
    need DEPLOYER_PK; need EVENT_OPERATOR
    run_forge --sig 'activateOperators()'
    "$0" verify
    ;;
  verify)
    need EVENT_OPERATOR
    echo "── vault perp reads (final) ──"; vault_reads
    echo "vault.eventMarketFactory (want $EVENT_MARKET_FACTORY):"
    cast call "$LP_VAULT_ADDRESS" 'eventMarketFactory()(address)' --rpc-url "$RPC"
    echo "factory.marketImplementation (want NEW_EVENT_MARKET_IMPL):"
    cast call "$EVENT_MARKET_FACTORY" 'marketImplementation()(address)' --rpc-url "$RPC"
    echo "factory.isOperator(router) (want true):"
    cast call "$EVENT_MARKET_FACTORY" 'isOperator(address)(bool)' "$EVENT_MARKET_ROUTER" --rpc-url "$RPC"
    echo "router.isOperator(EVENT_OPERATOR) (want true):"
    cast call "$EVENT_MARKET_ROUTER" 'isOperator(address)(bool)' "$EVENT_OPERATOR" --rpc-url "$RPC"
    echo "operator ETH balance (needs gas to relay trades):"
    cast balance "$EVENT_OPERATOR" --rpc-url "$RPC"
    ;;
  *)
    echo "usage: $0 {deploy|upgrade|set-market-impl-propose|set-market-impl-activate|operator-propose|operator-activate|verify}"
    exit 1
    ;;
esac
