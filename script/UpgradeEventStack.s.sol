// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {LPVault} from "../src/core/LPVault.sol";
import {EventMarket} from "../src/events/EventMarket.sol";
import {EventMarketFactory} from "../src/events/EventMarketFactory.sol";
import {EventMarketRouter} from "../src/events/EventMarketRouter.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title  UpgradeEventStack — in-place upgrade ceremony for the LIVE Base Sepolia event-market stack.
///
/// @notice Upgrades the three deployed proxies (LPVault, EventMarketFactory, and — via the factory's
///         governance-timelocked market-implementation setter — the EventMarket clone template) to
///         `current main`, then allowlists the operator relay path. RUN THE FORK TEST FIRST
///         (`test/integration/UpgradeCeremonyFork.t.sol`) — the LPVault proxy also backs live perp
///         positions, so its NAV/share-price reads MUST be unchanged across the upgrade.
///
/// @dev    THIS SCRIPT IS PHASED so the live runbook can wait the 1h timelock floor between the
///         propose and activate legs (mirrors EnableEventOperator's propose()/activate() split):
///
///           PHASE 1  deploy()                — deploy 3 new impls (plain `new`, no proxies). PRINTS
///                                              the impl addresses; export them for the next phases.
///           PHASE 2  upgrade()               — upgradeToAndCall(newImpl, "") on the LPVault proxy,
///                                              then on the EventMarketFactory proxy (NO reinit).
///           PHASE 3  proposeSetMarketImpl()  — factory.proposeSetMarketImplementation(newEventImpl).
///           ...wait factory.timelockDelay (3600s)...
///           PHASE 4  activateSetMarketImpl() — factory.activateSetMarketImplementation().
///           PHASE 5  proposeOperators()      — factory.proposeAddOperator(router)
///                                              AND router.proposeAddOperator(EVENT_OPERATOR).
///           ...wait 1 hour (router MIN_TIMELOCK_DELAY floor)...
///           PHASE 6  activateOperators()     — activateAddOperator on factory AND router.
///
///         Every phase is IDEMPOTENT (skips already-done steps) and read-back logs its effect.
///
/// @dev    Required env:
///           LP_VAULT_ADDRESS         — LPVault proxy (0x6347…)
///           EVENT_MARKET_FACTORY     — EventMarketFactory proxy (0xb73f…)
///           EVENT_MARKET_ROUTER      — EventMarketRouter proxy (0x0AE0…)
///           EVENT_OPERATOR           — engine operator signer to allowlist on the router (0xbFE2…)
///         Required env for upgrade()/set-market-impl phases (the impls printed by deploy()):
///           NEW_LPVAULT_IMPL, NEW_FACTORY_IMPL, NEW_EVENT_MARKET_IMPL
///           DEPLOYER_PK / PRIVATE_KEY — GOVERNANCE key (must be the vault + factory + router owner).
contract UpgradeEventStack is Script {
    function _beginBroadcast() internal {
        uint256 key = vm.envOr("DEPLOYER_PK", uint256(0));
        if (key == 0) key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) vm.startBroadcast();
        else vm.startBroadcast(key);
    }

    function _vault() internal view returns (LPVault) {
        return LPVault(vm.envAddress("LP_VAULT_ADDRESS"));
    }

    function _factory() internal view returns (EventMarketFactory) {
        return EventMarketFactory(vm.envAddress("EVENT_MARKET_FACTORY"));
    }

    function _router() internal view returns (EventMarketRouter) {
        return EventMarketRouter(vm.envAddress("EVENT_MARKET_ROUTER"));
    }

    /// @notice Default entrypoint: PHASE 1 — deploy the three new implementations (safe, no proxies touched).
    function run() external {
        deploy();
    }

    // ------------------------------------------------------------------------------------------
    // PHASE 1 — deploy the three new implementations (plain `new`, no proxies, no wiring changes).
    // ------------------------------------------------------------------------------------------
    function deploy() public returns (address newVaultImpl, address newFactoryImpl, address newEventMarketImpl) {
        console2.log("=== UpgradeEventStack: PHASE 1 DEPLOY (impls only) ===");
        _beginBroadcast();

        LPVault vaultImpl = new LPVault();
        EventMarketFactory factoryImpl = new EventMarketFactory();
        EventMarket eventMarketImpl = new EventMarket();

        vm.stopBroadcast();

        newVaultImpl = address(vaultImpl);
        newFactoryImpl = address(factoryImpl);
        newEventMarketImpl = address(eventMarketImpl);

        console2.log("New LPVault impl            :", newVaultImpl);
        console2.log("New EventMarketFactory impl :", newFactoryImpl);
        console2.log("New EventMarket impl        :", newEventMarketImpl);
        console2.log("--------------------------------------");
        console2.log("Export these, then run PHASE 2 upgrade():");
        console2.log("  export NEW_LPVAULT_IMPL=", newVaultImpl);
        console2.log("  export NEW_FACTORY_IMPL=", newFactoryImpl);
        console2.log("  export NEW_EVENT_MARKET_IMPL=", newEventMarketImpl);
    }

    // ------------------------------------------------------------------------------------------
    // PHASE 2 — upgrade the LPVault + EventMarketFactory proxies to their new impls (NO reinit).
    //
    // Storage-compat to current main is verified GO (append-only) for both proxies, so the second
    // arg to upgradeToAndCall is empty ("") — no reinitializer is run.
    // ------------------------------------------------------------------------------------------
    function upgrade() public {
        LPVault vault = _vault();
        EventMarketFactory factory = _factory();
        address newVaultImpl = vm.envAddress("NEW_LPVAULT_IMPL");
        address newFactoryImpl = vm.envAddress("NEW_FACTORY_IMPL");
        require(newVaultImpl.code.length != 0, "NEW_LPVAULT_IMPL has no code");
        require(newFactoryImpl.code.length != 0, "NEW_FACTORY_IMPL has no code");

        console2.log("=== UpgradeEventStack: PHASE 2 UPGRADE (proxies) ===");
        console2.log("vault proxy   :", address(vault));
        console2.log("factory proxy :", address(factory));

        // Perp-safety pre-reads (money-safety: these MUST be identical after the vault upgrade).
        uint256 taBefore = vault.totalAssets();
        uint256 ppsBefore = vault.convertToAssets(1e18);
        uint256 pcBefore = vault.positionCollateral();
        uint256 faBefore = vault.freeAssets();
        console2.log("PRE  totalAssets        :", taBefore);
        console2.log("PRE  pps(1e18 shares)   :", ppsBefore);
        console2.log("PRE  positionCollateral :", pcBefore);
        console2.log("PRE  freeAssets         :", faBefore);

        _beginBroadcast();
        // (b) LPVault proxy -> new LPVault impl.
        UUPSUpgradeable(address(vault)).upgradeToAndCall(newVaultImpl, "");
        // (c) EventMarketFactory proxy -> new factory impl.
        UUPSUpgradeable(address(factory)).upgradeToAndCall(newFactoryImpl, "");
        vm.stopBroadcast();

        uint256 taAfter = vault.totalAssets();
        uint256 ppsAfter = vault.convertToAssets(1e18);
        uint256 pcAfter = vault.positionCollateral();
        uint256 faAfter = vault.freeAssets();
        console2.log("POST totalAssets        :", taAfter);
        console2.log("POST pps(1e18 shares)   :", ppsAfter);
        console2.log("POST positionCollateral :", pcAfter);
        console2.log("POST freeAssets         :", faAfter);

        // Perp-money-safety guard: with NO live event markets present, NAV accounting is byte-identical.
        require(taAfter == taBefore, "MONEY-SAFETY FAIL: totalAssets changed");
        require(ppsAfter == ppsBefore, "MONEY-SAFETY FAIL: share price changed");
        require(pcAfter == pcBefore, "MONEY-SAFETY FAIL: positionCollateral changed");
        console2.log("--------------------------------------");
        console2.log("Vault perp reads UNCHANGED across upgrade. Next: PHASE 3 proposeSetMarketImpl().");
    }

    // ------------------------------------------------------------------------------------------
    // PHASE 3 — propose the new EventMarket clone template on the factory (timelocked).
    // ------------------------------------------------------------------------------------------
    function proposeSetMarketImpl() public {
        EventMarketFactory factory = _factory();
        address newEventMarketImpl = vm.envAddress("NEW_EVENT_MARKET_IMPL");
        require(newEventMarketImpl.code.length != 0, "NEW_EVENT_MARKET_IMPL has no code");

        console2.log("=== UpgradeEventStack: PHASE 3 PROPOSE setMarketImplementation ===");
        console2.log("new EventMarket impl:", newEventMarketImpl);

        _beginBroadcast();
        if (factory.marketImplementation() == newEventMarketImpl) {
            console2.log("[factory] marketImplementation already == new impl - skip");
        } else if (factory.pendingMarketImplementationActivatesAt() != 0) {
            console2.log("[factory] a market-impl proposal is already pending - skip");
            console2.log("  pending impl :", factory.pendingMarketImplementation());
            console2.log("  activatesAt  :", factory.pendingMarketImplementationActivatesAt());
        } else {
            factory.proposeSetMarketImplementation(newEventMarketImpl);
            console2.log("[factory] proposed; activatesAt:", factory.pendingMarketImplementationActivatesAt());
        }
        vm.stopBroadcast();

        console2.log("--------------------------------------");
        console2.log("Wait factory.timelockDelay (s):", factory.timelockDelay());
        console2.log("Then run PHASE 4 activateSetMarketImpl().");
    }

    // ------------------------------------------------------------------------------------------
    // PHASE 4 — activate the new EventMarket clone template once its timelock has elapsed.
    // ------------------------------------------------------------------------------------------
    function activateSetMarketImpl() public {
        EventMarketFactory factory = _factory();

        console2.log("=== UpgradeEventStack: PHASE 4 ACTIVATE setMarketImplementation ===");

        _beginBroadcast();
        uint64 readyAt = factory.pendingMarketImplementationActivatesAt();
        if (readyAt == 0) {
            if (vm.envOr("NEW_EVENT_MARKET_IMPL", address(0)) == factory.marketImplementation()) {
                console2.log("[factory] marketImplementation already == new impl - skip");
            } else {
                console2.log("[factory] no pending market-impl proposal - run PHASE 3 first");
            }
        } else if (block.timestamp < readyAt) {
            console2.log("[factory] timelock not elapsed; readyAt:", readyAt);
            console2.log("[factory] now:", block.timestamp);
        } else {
            factory.activateSetMarketImplementation();
            console2.log("[factory] ACTIVATED; marketImplementation now:", factory.marketImplementation());
        }
        vm.stopBroadcast();
    }

    // ------------------------------------------------------------------------------------------
    // PHASE 5 — propose operator allowlist adds: router->factory AND EVENT_OPERATOR->router.
    // ------------------------------------------------------------------------------------------
    function proposeOperators() public {
        EventMarketFactory factory = _factory();
        EventMarketRouter router = _router();
        address operator = vm.envAddress("EVENT_OPERATOR");
        require(operator != address(0), "EVENT_OPERATOR unset");

        console2.log("=== UpgradeEventStack: PHASE 5 PROPOSE operators ===");
        console2.log("factory :", address(factory));
        console2.log("router  :", address(router));
        console2.log("operator:", operator);

        _beginBroadcast();

        // Layer (i): router as a factory operator.
        if (factory.isOperator(address(router))) {
            console2.log("[factory] router already an operator - skip");
        } else if (factory.pendingOperatorActivatesAt(address(router)) != 0) {
            console2.log("[factory] router add already pending - skip");
        } else {
            factory.proposeAddOperator(address(router));
            console2.log("[factory] proposed router; activatesAt:", factory.pendingOperatorActivatesAt(address(router)));
        }

        // Layer (ii): engine operator key as a router operator.
        if (router.isOperator(operator)) {
            console2.log("[router] operator already set - skip");
        } else if (router.pendingOperatorActivatesAt(operator) != 0) {
            console2.log("[router] operator add already pending - skip");
        } else {
            router.proposeAddOperator(operator);
            console2.log("[router] proposed operator; activatesAt:", router.pendingOperatorActivatesAt(operator));
        }

        vm.stopBroadcast();

        console2.log("--------------------------------------");
        console2.log("Wait max(router,factory) timelockDelay, then PHASE 6 activateOperators().");
        console2.log("router.timelockDelay (s) :", router.timelockDelay());
        console2.log("factory.timelockDelay (s):", factory.timelockDelay());
    }

    // ------------------------------------------------------------------------------------------
    // PHASE 6 — activate both operator adds once their timelocks have elapsed.
    // ------------------------------------------------------------------------------------------
    function activateOperators() public {
        EventMarketFactory factory = _factory();
        EventMarketRouter router = _router();
        address operator = vm.envAddress("EVENT_OPERATOR");

        console2.log("=== UpgradeEventStack: PHASE 6 ACTIVATE operators ===");

        _beginBroadcast();

        // Layer (i).
        if (factory.isOperator(address(router))) {
            console2.log("[factory] router already active - skip");
        } else {
            uint64 readyAt = factory.pendingOperatorActivatesAt(address(router));
            if (readyAt == 0) {
                console2.log("[factory] no pending router add - run PHASE 5 first");
            } else if (block.timestamp < readyAt) {
                console2.log("[factory] timelock not elapsed; readyAt:", readyAt);
                console2.log("[factory] now:", block.timestamp);
            } else {
                factory.activateAddOperator(address(router));
                console2.log("[factory] router ACTIVATED as operator");
            }
        }

        // Layer (ii).
        if (router.isOperator(operator)) {
            console2.log("[router] operator already active - skip");
        } else {
            uint64 readyAt = router.pendingOperatorActivatesAt(operator);
            if (readyAt == 0) {
                console2.log("[router] no pending operator add - run PHASE 5 first");
            } else if (block.timestamp < readyAt) {
                console2.log("[router] timelock not elapsed; readyAt:", readyAt);
                console2.log("[router] now:", block.timestamp);
            } else {
                router.activateAddOperator(operator);
                console2.log("[router] operator ACTIVATED");
            }
        }

        vm.stopBroadcast();

        console2.log("--------------------------------------");
        console2.log("Final state:");
        console2.log("  factory.isOperator(router)  :", factory.isOperator(address(router)));
        console2.log("  router.isOperator(operator) :", router.isOperator(operator));
    }
}
