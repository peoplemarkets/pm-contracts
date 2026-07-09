// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EventMarket} from "../src/events/EventMarket.sol";
import {IEventMarket} from "../src/events/IEventMarket.sol";
import {UMAAdapter} from "../src/oracle/UMAAdapter.sol";

/// @title  AssertEventResolution — bonded-asserter runbook for UMA-resolved event markets.
///
/// @notice Fix C (bonded-asserter path). The platform self-bonds a resolution for a UMA-source event
///         market: approve the bond, propose the assertion (posting the bond), wait the liveness
///         window, settle the assertion, then finalize the market via `EventMarket.settleResolution`.
///
/// @dev    `proposeAssertion` pulls the bond from the asserter (this script's key). UMA refunds the
///         bond on a truthful (undisputed) assertion and slashes it on a lost dispute. Only run this
///         with an outcome you can defend.
///
///         Phases:
///           approve()  — usdc.approve(umaAdapter, bond)
///           propose()  — umaAdapter.proposeAssertion(eventId, uint256(outcome), claim);
///                        prints assertionId + expiresAt (now + liveness)
///           ...wait the metric's liveness window...
///           settle()   — umaAdapter.settleAssertion(assertionId);
///                        EventMarket(market).settleResolution()
///
/// @dev    Required env:
///           UMA_ADAPTER    — UMAAdapter proxy address
///           EVENT_ID       — bytes32 (== UMA metricId)
///           OUTCOME        — 1 = YES, 2 = NO, 3 = VOID (IEventMarket.Outcome value)
///           MARKET_ADDRESS — the EventMarket clone to finalize in settle()
///           BOND           — bond in currency native units (for the approve leg)
///           BOND_CURRENCY  — bond currency (usdc)
///           ASSERTION_ID   — (settle() only) the assertionId printed by propose()
///           ASSERTER_PK    — the self-bonding asserter key (pulls the bond)
contract AssertEventResolution is Script {
    function _adapter() internal view returns (UMAAdapter) {
        return UMAAdapter(vm.envAddress("UMA_ADAPTER"));
    }

    function _eventId() internal view returns (bytes32) {
        return vm.envBytes32("EVENT_ID");
    }

    function _beginBroadcast() internal {
        uint256 key = vm.envOr("ASSERTER_PK", uint256(0));
        if (key == 0) key = vm.envOr("DEPLOYER_PK", uint256(0));
        if (key == 0) key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) vm.startBroadcast();
        else vm.startBroadcast(key);
    }

    /// @notice Default entrypoint: PHASE 1 — approve the bond.
    function run() external {
        approve();
    }

    /// @notice PHASE 1 — approve the UMAAdapter to pull `bond` of the bond currency.
    function approve() public {
        UMAAdapter adapter = _adapter();
        IERC20 currency = IERC20(vm.envAddress("BOND_CURRENCY"));
        uint256 bond = vm.envUint("BOND");

        console2.log("=== AssertEventResolution: APPROVE ===");
        console2.log("adapter :", address(adapter));
        console2.log("currency:", address(currency));
        console2.log("bond    :", bond);

        _beginBroadcast();
        currency.approve(address(adapter), bond);
        vm.stopBroadcast();

        console2.log("[bond] approved. Next: --sig 'propose()'.");
    }

    /// @notice PHASE 2 — propose the assertion (posts the bond). Prints assertionId + expiresAt.
    function propose() public {
        UMAAdapter adapter = _adapter();
        bytes32 eventId = _eventId();
        uint256 outcome = vm.envUint("OUTCOME");
        require(outcome >= 1 && outcome <= 3, "OUTCOME must be 1=YES / 2=NO / 3=VOID");

        string memory claim = string(
            abi.encodePacked(
                "Assert event ",
                vm.toString(eventId),
                " resolved to ",
                outcome == 1 ? "YES" : outcome == 2 ? "NO" : "VOID"
            )
        );

        console2.log("=== AssertEventResolution: PROPOSE ===");
        console2.logBytes32(eventId);
        console2.log("outcome (1=YES 2=NO 3=VOID):", outcome);

        _beginBroadcast();
        bytes32 assertionId = adapter.proposeAssertion(eventId, outcome, bytes(claim));
        vm.stopBroadcast();

        uint64 liveness = adapter.metricOf(eventId).livenessSeconds;
        console2.log("[uma] assertionId:");
        console2.logBytes32(assertionId);
        console2.log("[uma] expiresAt (now + liveness):", block.timestamp + uint256(liveness));
        console2.log("--------------------------------------");
        console2.log("Export ASSERTION_ID, wait liveness seconds:", uint256(liveness));
        console2.log("Then run --sig 'settle()'. proposeAssertion pulled the bond from the asserter;");
        console2.log("UMA refunds on truthful (undisputed), slashes on lost dispute.");
    }

    /// @notice PHASE 3 — settle the assertion on UMA, then finalize the market.
    function settle() public {
        UMAAdapter adapter = _adapter();
        bytes32 assertionId = vm.envBytes32("ASSERTION_ID");
        address market = vm.envAddress("MARKET_ADDRESS");

        console2.log("=== AssertEventResolution: SETTLE ===");
        console2.logBytes32(assertionId);
        console2.log("market:", market);

        _beginBroadcast();
        adapter.settleAssertion(assertionId);
        EventMarket(market).settleResolution();
        vm.stopBroadcast();

        console2.log("[market] settled. outcome:", uint256(EventMarket(market).outcome()));
        console2.log("[market] status:", uint256(EventMarket(market).status()));
    }
}
