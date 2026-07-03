// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {EventMarketFactory} from "../src/events/EventMarketFactory.sol";
import {EventMarketRouter} from "../src/events/EventMarketRouter.sol";

/// @title  EnableEventOperator — allowlist the custodial event-dispatch path on a live deployment.
///
/// @notice Executes the two-layer operator allowlisting that turns on the engine-relayed event
///         market path (pm-engine #10 dogfood). It wires:
///
///           (i)  the ROUTER  as an operator on the FACTORY  — so every market accepts the router's
///                `*For` calls (`factory.isOperator(router) == true`); and
///           (ii) the ENGINE OPERATOR key as an operator on the ROUTER — so only that KMS/signer key
///                can relay an approving trader's USDC (`router.isOperator(EVENT_OPERATOR) == true`).
///
/// @dev    Both allowlists are governance-timelocked (propose -> wait -> activate). On Base Sepolia
///         the delay is set short (~225s) for the dogfood, so this is a genuine two-step operation:
///
///           STEP 1 (propose):   forge script script/EnableEventOperator.s.sol:EnableEventOperator \
///                                 --sig "propose()" --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
///           ...wait timelockDelay seconds (printed by step 1)...
///           STEP 2 (activate):  forge script script/EnableEventOperator.s.sol:EnableEventOperator \
///                                 --sig "activate()" --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
///
///         The default entrypoint `run()` performs STEP 1 (propose) — the safe first action.
///         For a stack whose timelock is already elapsed / zero (e.g. the fresh WorldCup test
///         stack) `activate()` can be called immediately after `propose()`.
///
/// @dev    All actions are IDEMPOTENT: already-active operators are skipped, already-pending
///         proposals are not re-proposed, and not-yet-ready activations are reported rather than
///         reverting. Safe to re-run.
///
/// @dev    Required env:
///           EVENT_MARKET_FACTORY  — EventMarketFactory proxy address
///           EVENT_MARKET_ROUTER   — EventMarketRouter proxy address
///           EVENT_OPERATOR        — engine operator SIGNER address to allowlist on the router
///                                   (MUST equal the engine's `chain.event_operator` signer)
///           DEPLOYER_PK / PRIVATE_KEY — governance key (must be the factory + router `governance`)
contract EnableEventOperator is Script {
    function _cfg() internal view returns (EventMarketFactory factory, EventMarketRouter router, address operator) {
        factory = EventMarketFactory(vm.envAddress("EVENT_MARKET_FACTORY"));
        router = EventMarketRouter(vm.envAddress("EVENT_MARKET_ROUTER"));
        operator = vm.envAddress("EVENT_OPERATOR");
        require(operator != address(0), "EVENT_OPERATOR unset");
    }

    function _beginBroadcast() internal {
        uint256 key = vm.envOr("DEPLOYER_PK", uint256(0));
        if (key == 0) key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) vm.startBroadcast();
        else vm.startBroadcast(key);
    }

    /// @notice Default entrypoint: STEP 1 — propose both operator adds.
    function run() external {
        propose();
    }

    /// @notice STEP 1 — propose the router->factory and operator->router allowlist adds.
    function propose() public {
        (EventMarketFactory factory, EventMarketRouter router, address operator) = _cfg();

        console2.log("=== EnableEventOperator: PROPOSE ===");
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
        console2.log("Wait timelockDelay seconds, then run --sig \"activate()\".");
        console2.log("router.timelockDelay (s):", router.timelockDelay());
        console2.log("factory.timelockDelay (s):", factory.timelockDelay());
    }

    /// @notice STEP 2 — activate both adds once their timelocks have elapsed.
    function activate() public {
        (EventMarketFactory factory, EventMarketRouter router, address operator) = _cfg();

        console2.log("=== EnableEventOperator: ACTIVATE ===");

        _beginBroadcast();

        // Layer (i).
        if (factory.isOperator(address(router))) {
            console2.log("[factory] router already active - skip");
        } else {
            uint64 readyAt = factory.pendingOperatorActivatesAt(address(router));
            if (readyAt == 0) {
                console2.log("[factory] no pending router add - run propose() first");
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
                console2.log("[router] no pending operator add - run propose() first");
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
        console2.log("Engine config -> chain.event_market_router:", address(router));
        console2.log("Engine config -> event_market_factory     :", address(factory));
        console2.log("Engine config -> event_operator signer    :", operator);
    }
}
