// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {UMAAdapter} from "../src/oracle/UMAAdapter.sol";

/// @title  RegisterEventMetric — timelocked UMA metric registration for an event market.
///
/// @notice Fix C (UMA metric-registration pipeline). `eventId` IS the UMA `metricId`; a market
///         cannot settle — and, post Fix D, cannot even be CREATED — until its metric is registered
///         on the UMAAdapter via the two-step governance timelock (propose -> wait -> activate).
///
/// @dev    Mirrors the EnableEventOperator propose()/activate() split so the shell runbook can wait
///         the adapter's `timelockDelay` (1h floor) between the two legs. `verify()` is a read-only
///         confirmation.
///
///         Phases:
///           propose()  — UMAAdapter.proposeRegisterMetric(eventId, bond, liveness, identifier, currency)
///           ...wait UMAAdapter.timelockDelay (adapter floor 1h)...
///           activate() — UMAAdapter.activateRegisterMetric(eventId); asserts metricOf().registered
///           verify()   — read-only: requires registered == true; prints bond/liveness/id/currency
///
/// @dev    Required env:
///           UMA_ADAPTER    — UMAAdapter proxy address
///           EVENT_ID       — bytes32 (== UMA metricId)
///           BOND           — bond in `currency` native units (>= MIN_BOND = 1e6)
///           LIVENESS       — dispute window seconds (>= MIN_LIVENESS = 60, <= 7 days)
///           UMA_IDENTIFIER — bytes32 UMA price identifier (e.g. bytes32("ASSERT_TRUTH"))
///           BOND_CURRENCY  — bond currency (usdc)
///           DEPLOYER_PK / PRIVATE_KEY — governance key (must be the UMAAdapter `governance`)
contract RegisterEventMetric is Script {
    function _adapter() internal view returns (UMAAdapter) {
        return UMAAdapter(vm.envAddress("UMA_ADAPTER"));
    }

    function _eventId() internal view returns (bytes32) {
        return vm.envBytes32("EVENT_ID");
    }

    function _beginBroadcast() internal {
        uint256 key = vm.envOr("DEPLOYER_PK", uint256(0));
        if (key == 0) key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) vm.startBroadcast();
        else vm.startBroadcast(key);
    }

    /// @notice Default entrypoint: PHASE 1 — propose the registration (safe first action).
    function run() external {
        propose();
    }

    /// @notice PHASE 1 — propose the metric registration (timelocked).
    function propose() public {
        UMAAdapter adapter = _adapter();
        bytes32 eventId = _eventId();
        uint256 bond = vm.envUint("BOND");
        uint64 liveness = uint64(vm.envUint("LIVENESS"));
        bytes32 identifier = vm.envBytes32("UMA_IDENTIFIER");
        address currency = vm.envAddress("BOND_CURRENCY");

        console2.log("=== RegisterEventMetric: PROPOSE ===");
        console2.log("adapter :", address(adapter));
        console2.logBytes32(eventId);
        console2.log("bond    :", bond);
        console2.log("liveness:", uint256(liveness));
        console2.log("currency:", currency);

        _beginBroadcast();
        if (adapter.metricOf(eventId).registered) {
            console2.log("[uma] metric already registered - skip");
        } else if (adapter.pendingMetricOf(eventId).exists) {
            console2.log("[uma] registration already pending - skip");
        } else {
            adapter.proposeRegisterMetric(eventId, bond, liveness, identifier, currency);
            uint64 activatesAt = adapter.pendingMetricOf(eventId).activatesAt;
            console2.log("[uma] proposed; activatesAt:", uint256(activatesAt));
        }
        vm.stopBroadcast();

        console2.log("--------------------------------------");
        console2.log("Wait UMAAdapter.timelockDelay (adapter floor 1h):", uint256(adapter.timelockDelay()));
        console2.log("Then run --sig 'activate()'.");
    }

    /// @notice PHASE 2 — activate the registration once the timelock has elapsed; asserts success.
    function activate() public {
        UMAAdapter adapter = _adapter();
        bytes32 eventId = _eventId();

        console2.log("=== RegisterEventMetric: ACTIVATE ===");

        _beginBroadcast();
        if (adapter.metricOf(eventId).registered) {
            console2.log("[uma] already registered - skip");
        } else {
            uint64 readyAt = adapter.pendingMetricOf(eventId).activatesAt;
            if (!adapter.pendingMetricOf(eventId).exists) {
                console2.log("[uma] no pending registration - run propose() first");
            } else if (block.timestamp < readyAt) {
                console2.log("[uma] timelock not elapsed; readyAt:", uint256(readyAt));
                console2.log("[uma] now:", block.timestamp);
            } else {
                adapter.activateRegisterMetric(eventId);
                console2.log("[uma] ACTIVATED");
            }
        }
        vm.stopBroadcast();

        // Hard assert: the metric MUST be registered after this phase.
        require(adapter.metricOf(eventId).registered, "RegisterEventMetric: metric NOT registered after activate");
        console2.log("[uma] metricOf(eventId).registered == true (confirmed)");
    }

    /// @notice PHASE 3 — read-only verification. Reverts if the metric is not registered.
    function verify() public view {
        UMAAdapter adapter = _adapter();
        bytes32 eventId = _eventId();
        UMAAdapter.UMAMetric memory m = adapter.metricOf(eventId);
        require(m.registered, "RegisterEventMetric: metric NOT registered");
        console2.log("=== RegisterEventMetric: VERIFY (registered) ===");
        console2.logBytes32(eventId);
        console2.log("bond      :", m.bond);
        console2.log("liveness  :", uint256(m.livenessSeconds));
        console2.log("currency  :", m.currency);
        console2.logBytes32(m.identifier);
    }
}
