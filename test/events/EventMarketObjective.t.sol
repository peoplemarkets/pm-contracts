// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ILPVault} from "../../src/core/ILPVault.sol";
import {EventMarket} from "../../src/events/EventMarket.sol";
import {EventMarketFactory} from "../../src/events/EventMarketFactory.sol";
import {IEventMarket} from "../../src/events/IEventMarket.sol";
import {LMSRMath} from "../../src/events/LMSRMath.sol";
import {IFeedbackController} from "../../src/feedback/IFeedbackController.sol";
import {IOracleRouter} from "../../src/oracle/IOracleRouter.sol";
import {UMAAdapter} from "../../src/oracle/UMAAdapter.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockFeedbackController, MockLPVault, MockOracleRouter, MockUMAAdapter} from "./mocks/MockEventDeps.sol";

/// @title  Fix B — objective OracleRouter resolution + Fix D readiness gate.
/// @notice Covers: objective YES/NO settlement via comparator; stale / unregistered / degraded feed
///         REFUSES to settle (funds stay solvent); settleNotBefore guard; the UMA-default path is
///         unchanged; `proposeResolution` is UMA-only; and `createMarket*` reverts `MetricNotReady`
///         on an unregistered metric (both sources).
contract EventMarketObjectiveTest is Test {
    EventMarketFactory internal factory;
    MockUSDC internal usdc;
    MockLPVault internal lpVault;
    MockFeedbackController internal feedback;
    MockUMAAdapter internal uma;
    MockOracleRouter internal oracle;

    address internal governance = makeAddr("governance");
    address internal alice = makeAddr("alice");

    uint32 internal constant TIMELOCK = 1 days;
    uint256 internal constant LMSR_B = 10_000e6;
    uint64 internal constant DEADLINE = 2_000_000_000;

    bytes32 internal constant SUBJECT_ID = keccak256("subject.mrbeast");
    bytes32 internal constant EVENT_ID = keccak256("event.mrbeast.100m.subs");
    bytes32 internal constant METRIC_ID = keccak256("metric.youtube.subs.mrbeast");

    function setUp() public {
        vm.warp(1_900_000_000);

        usdc = new MockUSDC();
        lpVault = new MockLPVault(IERC20(address(usdc)));
        feedback = new MockFeedbackController();
        uma = new MockUMAAdapter();
        oracle = new MockOracleRouter();

        usdc.mint(address(lpVault), 10_000_000e6);

        EventMarket marketImpl = new EventMarket();
        EventMarketFactory factoryImpl = new EventMarketFactory();
        bytes memory init = abi.encodeCall(
            EventMarketFactory.initialize,
            (
                governance,
                TIMELOCK,
                ILPVault(address(lpVault)),
                IFeedbackController(address(feedback)),
                UMAAdapter(address(uma)),
                IERC20(address(usdc)),
                address(marketImpl)
            )
        );
        factory = EventMarketFactory(address(new ERC1967Proxy(address(factoryImpl), init)));

        usdc.mint(alice, 1_000_000e6);
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _objectiveConfig(
        IEventMarket.Comparator cmp,
        uint256 threshold,
        uint64 settleNotBefore
    )
        internal
        view
        returns (IEventMarket.ResolutionConfig memory rc)
    {
        rc = IEventMarket.ResolutionConfig({
            source: IEventMarket.ResolutionSource.ORACLE_ROUTER,
            metricId: METRIC_ID,
            threshold: threshold,
            comparator: cmp,
            settleNotBefore: settleNotBefore,
            oracleRouter: address(oracle)
        });
    }

    function _createObjective(IEventMarket.ResolutionConfig memory rc) internal returns (EventMarket m) {
        vm.prank(governance);
        address addr = factory.createMarketWithResolution(
            SUBJECT_ID,
            EVENT_ID,
            uint8(IFeedbackController.EventClass.MILESTONE_HIT),
            "100M subs?",
            DEADLINE,
            0,
            LMSR_B,
            rc
        );
        m = EventMarket(addr);
    }

    /// @dev Register the objective metric on the router so the readiness gate passes.
    function _registerMetric(uint256 value, uint64 updatedAt, uint32 staleAfter) internal {
        oracle.registerMetric(METRIC_ID, value, updatedAt, staleAfter);
    }

    // ------------------------------------------------------------------------------------------
    // Objective settlement — YES / NO via comparator
    // ------------------------------------------------------------------------------------------

    function test_objective_settlesYes_whenThresholdMet() public {
        _registerMetric(100_000_000, uint64(block.timestamp), 1 days);
        IEventMarket.ResolutionConfig memory rc = _objectiveConfig(IEventMarket.Comparator.GTE, 100_000_000, DEADLINE);
        EventMarket m = _createObjective(rc);

        // Value 100M >= threshold 100M => YES.
        vm.warp(DEADLINE + 1);
        oracle.setValue(METRIC_ID, 100_000_000, uint64(DEADLINE + 1));
        m.settleResolution();
        assertEq(uint256(m.outcome()), uint256(IEventMarket.Outcome.YES), "GTE met => YES");
        assertEq(uint256(m.status()), uint256(IEventMarket.Status.RESOLVED), "resolved");
    }

    function test_objective_settlesNo_whenThresholdNotMet() public {
        _registerMetric(50_000_000, uint64(block.timestamp), 1 days);
        IEventMarket.ResolutionConfig memory rc = _objectiveConfig(IEventMarket.Comparator.GTE, 100_000_000, DEADLINE);
        EventMarket m = _createObjective(rc);

        vm.warp(DEADLINE + 1);
        oracle.setValue(METRIC_ID, 99_999_999, uint64(DEADLINE + 1)); // just under
        m.settleResolution();
        assertEq(uint256(m.outcome()), uint256(IEventMarket.Outcome.NO), "GTE not met => NO");
    }

    function test_objective_comparators() public {
        // LTE: value <= threshold.
        _registerMetric(10, uint64(block.timestamp), 1 days);
        IEventMarket.ResolutionConfig memory rc = _objectiveConfig(IEventMarket.Comparator.LTE, 10, DEADLINE);
        EventMarket m = _createObjective(rc);
        vm.warp(DEADLINE + 1);
        oracle.setValue(METRIC_ID, 10, uint64(DEADLINE + 1));
        m.settleResolution();
        assertEq(uint256(m.outcome()), uint256(IEventMarket.Outcome.YES), "LTE 10<=10 => YES");
    }

    function test_objective_EQ_discreteMetric() public {
        _registerMetric(1, uint64(block.timestamp), 1 days);
        IEventMarket.ResolutionConfig memory rc = _objectiveConfig(IEventMarket.Comparator.EQ, 1, DEADLINE);
        EventMarket m = _createObjective(rc);
        vm.warp(DEADLINE + 1);
        oracle.setValue(METRIC_ID, 1, uint64(DEADLINE + 1)); // #1 chart position
        m.settleResolution();
        assertEq(uint256(m.outcome()), uint256(IEventMarket.Outcome.YES), "EQ 1==1 => YES");
    }

    // ------------------------------------------------------------------------------------------
    // Objective settlement REFUSES to run on an unready feed (funds stay solvent)
    // ------------------------------------------------------------------------------------------

    function test_objective_staleFeedReverts() public {
        // staleAfter 1h; value produced now; we warp far past deadline so the reading is stale.
        _registerMetric(100_000_000, uint64(block.timestamp), 1 hours);
        IEventMarket.ResolutionConfig memory rc = _objectiveConfig(IEventMarket.Comparator.GTE, 100_000_000, DEADLINE);
        EventMarket m = _createObjective(rc);

        vm.warp(DEADLINE + 1); // updatedAt is ~1.9e9, now is 2e9 => far beyond 1h staleAfter
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleRouter.StaleReading.selector, METRIC_ID, uint64(1_900_000_000), uint32(1 hours)
            )
        );
        m.settleResolution();
        // Market remains unsettled + solvent: seed escrow still present.
        assertEq(uint256(m.status()), uint256(IEventMarket.Status.OPEN), "still open after stale revert");
        assertEq(usdc.balanceOf(address(m)), LMSRMath.cost(0, 0, LMSR_B), "seed escrow intact");
    }

    function test_objective_degradedFeedReverts() public {
        _registerMetric(100_000_000, uint64(block.timestamp), 1 days);
        IEventMarket.ResolutionConfig memory rc = _objectiveConfig(IEventMarket.Comparator.GTE, 100_000_000, DEADLINE);
        EventMarket m = _createObjective(rc);

        vm.warp(DEADLINE + 1);
        oracle.setValue(METRIC_ID, 100_000_000, uint64(DEADLINE + 1));

        // Degraded WITH a fallback: router.read returns a degraded reading; the market must still
        // fail closed (objective binary must run on a healthy primary).
        oracle.setDegraded(METRIC_ID, true, true);
        vm.expectRevert("EventMarket: degraded feed");
        m.settleResolution();

        // Degraded WITHOUT a fallback: router.read itself reverts.
        oracle.setDegraded(METRIC_ID, true, false);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.DegradedAndNoFallback.selector, METRIC_ID));
        m.settleResolution();

        assertEq(uint256(m.status()), uint256(IEventMarket.Status.OPEN), "never settled on degraded");
    }

    function test_objective_settleNotBeforeGuard() public {
        _registerMetric(100_000_000, uint64(block.timestamp), 1 days);
        // settleNotBefore == DEADLINE.
        IEventMarket.ResolutionConfig memory rc = _objectiveConfig(IEventMarket.Comparator.GTE, 100_000_000, DEADLINE);
        EventMarket m = _createObjective(rc);

        // Before the settleNotBefore instant, even a fresh in-threshold reading cannot settle.
        oracle.setValue(METRIC_ID, 100_000_000, uint64(block.timestamp));
        vm.expectRevert("EventMarket: before settleNotBefore");
        m.settleResolution();

        // At/after it, settlement proceeds.
        vm.warp(DEADLINE);
        oracle.setValue(METRIC_ID, 100_000_000, uint64(DEADLINE));
        m.settleResolution();
        assertEq(uint256(m.outcome()), uint256(IEventMarket.Outcome.YES));
    }

    function test_objective_proposeResolutionReverts() public {
        _registerMetric(1, uint64(block.timestamp), 1 days);
        IEventMarket.ResolutionConfig memory rc = _objectiveConfig(IEventMarket.Comparator.GTE, 1, DEADLINE);
        EventMarket m = _createObjective(rc);
        vm.expectRevert(IEventMarket.WrongResolutionSource.selector);
        m.proposeResolution(IEventMarket.Outcome.YES);
    }

    function test_objective_configStored() public {
        _registerMetric(1, uint64(block.timestamp), 1 days);
        IEventMarket.ResolutionConfig memory rc = _objectiveConfig(IEventMarket.Comparator.LT, 42, DEADLINE);
        EventMarket m = _createObjective(rc);
        IEventMarket.ResolutionConfig memory got = m.resolutionConfig();
        assertEq(uint256(got.source), uint256(IEventMarket.ResolutionSource.ORACLE_ROUTER), "source");
        assertEq(got.metricId, METRIC_ID, "metricId");
        assertEq(got.threshold, 42, "threshold");
        assertEq(uint256(got.comparator), uint256(IEventMarket.Comparator.LT), "comparator");
        assertEq(got.oracleRouter, address(oracle), "router");
    }

    // ------------------------------------------------------------------------------------------
    // UMA-default path unchanged
    // ------------------------------------------------------------------------------------------

    function test_umaDefault_pathUnchanged() public {
        // 7-arg createMarket => source == UMA (zero-value config). Settles via UMAAdapter exactly
        // as before; resolutionConfig reads back as the UMA default.
        uma.setRegistered(EVENT_ID, true);
        vm.prank(governance);
        address addr = factory.createMarket(SUBJECT_ID, EVENT_ID, uint8(1), "UMA?", DEADLINE, 0, LMSR_B);
        EventMarket m = EventMarket(addr);

        IEventMarket.ResolutionConfig memory got = m.resolutionConfig();
        assertEq(uint256(got.source), uint256(IEventMarket.ResolutionSource.UMA), "default source is UMA");

        uma.setLatestValue(uint256(IEventMarket.Outcome.NO), uint64(block.timestamp));
        m.settleResolution();
        assertEq(uint256(m.outcome()), uint256(IEventMarket.Outcome.NO), "UMA NO settle");
    }

    function test_umaDefault_viaWithResolutionOverload() public {
        // The overload with an explicit UMA config must behave identically to the 7-arg path.
        uma.setRegistered(EVENT_ID, true);
        IEventMarket.ResolutionConfig memory rc; // zero-value == UMA
        vm.prank(governance);
        address addr = factory.createMarketWithResolution(
            SUBJECT_ID, EVENT_ID, uint8(1), "UMA overload?", DEADLINE, 0, LMSR_B, rc
        );
        EventMarket m = EventMarket(addr);

        uma.setLatestValue(uint256(IEventMarket.Outcome.YES), uint64(block.timestamp));
        m.settleResolution();
        assertEq(uint256(m.outcome()), uint256(IEventMarket.Outcome.YES), "UMA YES via overload");
    }

    // ------------------------------------------------------------------------------------------
    // Fix D — readiness gate reverts on an unregistered metric (BOTH sources)
    // ------------------------------------------------------------------------------------------

    function test_readinessGate_uma_unregisteredReverts() public {
        uma.setRegistered(EVENT_ID, false); // metric NOT registered
        vm.expectRevert(abi.encodeWithSelector(EventMarketFactory.MetricNotReady.selector, EVENT_ID));
        vm.prank(governance);
        factory.createMarket(SUBJECT_ID, EVENT_ID, uint8(1), "UMA?", DEADLINE, 0, LMSR_B);
    }

    function test_readinessGate_oracle_unregisteredReverts() public {
        // Router metric NOT registered (configOf().sourceType == UNSET).
        IEventMarket.ResolutionConfig memory rc = _objectiveConfig(IEventMarket.Comparator.GTE, 1, DEADLINE);
        vm.expectRevert(abi.encodeWithSelector(EventMarketFactory.MetricNotReady.selector, METRIC_ID));
        vm.prank(governance);
        factory.createMarketWithResolution(SUBJECT_ID, EVENT_ID, uint8(1), "obj?", DEADLINE, 0, LMSR_B, rc);
    }

    function test_readinessGate_oracle_settleNotBeforeAfterDeadlineReverts() public {
        _registerMetric(1, uint64(block.timestamp), 1 days);
        // settleNotBefore > resolutionDeadline is incoherent — creation reverts.
        IEventMarket.ResolutionConfig memory rc = _objectiveConfig(IEventMarket.Comparator.GTE, 1, DEADLINE + 1);
        vm.expectRevert("EventMarketFactory: settleNotBefore > deadline");
        vm.prank(governance);
        factory.createMarketWithResolution(SUBJECT_ID, EVENT_ID, uint8(1), "obj?", DEADLINE, 0, LMSR_B, rc);
    }

    function test_readinessGate_uma_registeredCreatesOk() public {
        uma.setRegistered(EVENT_ID, true);
        vm.prank(governance);
        address addr = factory.createMarket(SUBJECT_ID, EVENT_ID, uint8(1), "UMA?", DEADLINE, 0, LMSR_B);
        assertTrue(factory.isMarket(addr), "created once registered");
    }

    // ------------------------------------------------------------------------------------------
    // Storage-layout guard — `_resolution` MUST be appended after `noBalance` (append-only).
    // ------------------------------------------------------------------------------------------

    /// @dev The appended ResolutionConfig occupies slots 15..18 (source+comparator packed, metricId,
    ///      threshold, settleNotBefore+oracleRouter). Legacy fixed slots 0..14 (usdc..noBalance) are
    ///      unchanged. We assert the objective config lands in slot 15+ by reading raw storage on a
    ///      fresh objective clone — a regression that inserted state mid-layout would break this.
    function test_storageLayout_resolutionAppendedAtSlot15() public {
        _registerMetric(1, uint64(block.timestamp), 1 days);
        IEventMarket.ResolutionConfig memory rc = _objectiveConfig(IEventMarket.Comparator.GT, 777, DEADLINE);
        EventMarket m = _createObjective(rc);

        // Slot 15 packs `source` (uint8 @ offset 0) + `comparator` (uint8 @ offset ... in the struct).
        // We assert the whole struct is reachable from slot 15 by checking the metricId lands in slot 16.
        bytes32 slot16 = vm.load(address(m), bytes32(uint256(16)));
        assertEq(slot16, METRIC_ID, "metricId at slot 16 (struct appended at 15)");

        // threshold at slot 17.
        uint256 slot17 = uint256(vm.load(address(m), bytes32(uint256(17))));
        assertEq(slot17, 777, "threshold at slot 17");

        // Legacy slot 0 (usdc) is unchanged.
        address usdcSlot = address(uint160(uint256(vm.load(address(m), bytes32(uint256(0))))));
        assertEq(usdcSlot, address(usdc), "usdc still at slot 0");
    }
}
