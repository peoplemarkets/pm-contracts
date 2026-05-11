// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test} from "forge-std/Test.sol";

import {IOracleRouter} from "../src/oracle/IOracleRouter.sol";
import {IOptimisticOracleV3, UMAAdapter} from "../src/oracle/UMAAdapter.sol";

import {MockOptimisticOracleV3} from "./mocks/MockOptimisticOracleV3.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title UMAAdapter test suite
/// @notice Exercises the full assertion lifecycle, per-metric governance timelock, bond / liveness
///         bounds, and the dispute → DVM resolution branch via a mock OOv3.
contract UMAAdapterTest is Test {
    UMAAdapter internal adapter;
    MockOptimisticOracleV3 internal oo;
    MockUSDC internal usdc;

    address internal governance = makeAddr("governance");
    address internal stranger = makeAddr("stranger");
    address internal asserter = makeAddr("asserter");

    uint32 internal constant TIMELOCK_DELAY = 2 days;
    uint64 internal constant LIVENESS = 1 hours;
    uint256 internal constant BOND = 100e6; // 100 USDC

    bytes32 internal constant METRIC_ID = keccak256("uma.metric.event.drake-wins");
    bytes32 internal constant METRIC_ID_2 = keccak256("uma.metric.event.other");
    bytes32 internal constant IDENTIFIER = bytes32("ASSERT_TRUTH");

    // ------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------

    function setUp() public {
        oo = new MockOptimisticOracleV3();
        usdc = new MockUSDC();

        UMAAdapter impl = new UMAAdapter();
        bytes memory initData =
            abi.encodeCall(UMAAdapter.initialize, (IOptimisticOracleV3(address(oo)), governance, TIMELOCK_DELAY));
        adapter = UMAAdapter(address(new ERC1967Proxy(address(impl), initData)));

        // Fund the asserter and give the adapter their approval.
        usdc.mint(asserter, 10_000e6);
        vm.prank(asserter);
        usdc.approve(address(adapter), type(uint256).max);

        // Anchor block.timestamp so liveness math is meaningful.
        vm.warp(1_900_000_000);
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _register(bytes32 id) internal {
        vm.prank(governance);
        adapter.proposeRegisterMetric(id, BOND, LIVENESS, IDENTIFIER, address(usdc));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        adapter.activateRegisterMetric(id);
    }

    // ------------------------------------------------------------------------------------------
    // Initialize
    // ------------------------------------------------------------------------------------------

    function test_initialize_setsAll() public view {
        assertEq(adapter.governance(), governance);
        assertEq(adapter.oracle(), address(oo));
        assertEq(uint256(adapter.timelockDelay()), TIMELOCK_DELAY);
    }

    function test_initialize_revertsOnZeroOracle() public {
        UMAAdapter impl = new UMAAdapter();
        bytes memory initData =
            abi.encodeCall(UMAAdapter.initialize, (IOptimisticOracleV3(address(0)), governance, TIMELOCK_DELAY));
        vm.expectRevert(UMAAdapter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_revertsOnZeroGovernance() public {
        UMAAdapter impl = new UMAAdapter();
        bytes memory initData =
            abi.encodeCall(UMAAdapter.initialize, (IOptimisticOracleV3(address(oo)), address(0), TIMELOCK_DELAY));
        vm.expectRevert(UMAAdapter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_revertsOnTimelockTooLow() public {
        UMAAdapter impl = new UMAAdapter();
        bytes memory initData =
            abi.encodeCall(UMAAdapter.initialize, (IOptimisticOracleV3(address(oo)), governance, uint32(1 hours - 1)));
        vm.expectRevert(UMAAdapter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_revertsOnTimelockTooHigh() public {
        UMAAdapter impl = new UMAAdapter();
        bytes memory initData =
            abi.encodeCall(UMAAdapter.initialize, (IOptimisticOracleV3(address(oo)), governance, uint32(30 days + 1)));
        vm.expectRevert(UMAAdapter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_disabledOnImplementation() public {
        UMAAdapter impl = new UMAAdapter();
        vm.expectRevert();
        impl.initialize(IOptimisticOracleV3(address(oo)), governance, TIMELOCK_DELAY);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: register metric
    // ------------------------------------------------------------------------------------------

    function test_proposeRegister_storesPending() public {
        vm.prank(governance);
        adapter.proposeRegisterMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));

        UMAAdapter.PendingMetric memory p = adapter.pendingMetricOf(METRIC_ID);
        assertTrue(p.exists);
        assertFalse(p.isUpdate);
        assertEq(p.config.bond, BOND);
        assertEq(uint256(p.config.livenessSeconds), LIVENESS);
        assertEq(p.config.identifier, IDENTIFIER);
        assertEq(p.config.currency, address(usdc));
        assertEq(uint256(p.activatesAt), block.timestamp + TIMELOCK_DELAY);
    }

    function test_proposeRegister_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.Unauthorized.selector, stranger));
        adapter.proposeRegisterMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));
    }

    function test_proposeRegister_revertsIfAlreadyRegistered() public {
        _register(METRIC_ID);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.MetricAlreadyRegistered.selector, METRIC_ID));
        adapter.proposeRegisterMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));
    }

    function test_proposeRegister_revertsIfPendingExists() public {
        vm.prank(governance);
        adapter.proposeRegisterMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.PendingProposalExists.selector, METRIC_ID));
        adapter.proposeRegisterMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));
    }

    function test_proposeRegister_revertsOnZeroCurrency() public {
        vm.prank(governance);
        vm.expectRevert(UMAAdapter.InvalidConfig.selector);
        adapter.proposeRegisterMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(0));
    }

    function test_proposeRegister_bondBoundary_min() public {
        uint256 minBond = adapter.MIN_BOND();
        vm.prank(governance);
        adapter.proposeRegisterMetric(METRIC_ID, minBond, LIVENESS, IDENTIFIER, address(usdc));
    }

    function test_proposeRegister_bondBoundary_belowMin() public {
        uint256 tooLow = adapter.MIN_BOND() - 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.BondOutOfRange.selector, tooLow));
        adapter.proposeRegisterMetric(METRIC_ID, tooLow, LIVENESS, IDENTIFIER, address(usdc));
    }

    function test_proposeRegister_bondBoundary_max() public {
        uint256 maxBond = adapter.MAX_BOND();
        vm.prank(governance);
        adapter.proposeRegisterMetric(METRIC_ID, maxBond, LIVENESS, IDENTIFIER, address(usdc));
    }

    function test_proposeRegister_bondBoundary_aboveMax() public {
        uint256 tooHigh = adapter.MAX_BOND() + 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.BondOutOfRange.selector, tooHigh));
        adapter.proposeRegisterMetric(METRIC_ID, tooHigh, LIVENESS, IDENTIFIER, address(usdc));
    }

    function test_proposeRegister_livenessBoundary_min() public {
        uint64 minLiveness = adapter.MIN_LIVENESS();
        vm.prank(governance);
        adapter.proposeRegisterMetric(METRIC_ID, BOND, minLiveness, IDENTIFIER, address(usdc));
    }

    function test_proposeRegister_livenessBoundary_belowMin() public {
        uint64 tooLow = adapter.MIN_LIVENESS() - 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.LivenessOutOfRange.selector, tooLow));
        adapter.proposeRegisterMetric(METRIC_ID, BOND, tooLow, IDENTIFIER, address(usdc));
    }

    function test_proposeRegister_livenessBoundary_max() public {
        uint64 maxLiveness = adapter.MAX_LIVENESS();
        vm.prank(governance);
        adapter.proposeRegisterMetric(METRIC_ID, BOND, maxLiveness, IDENTIFIER, address(usdc));
    }

    function test_proposeRegister_livenessBoundary_aboveMax() public {
        uint64 tooHigh = adapter.MAX_LIVENESS() + 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.LivenessOutOfRange.selector, tooHigh));
        adapter.proposeRegisterMetric(METRIC_ID, BOND, tooHigh, IDENTIFIER, address(usdc));
    }

    // ------------------------------------------------------------------------------------------
    // activateRegisterMetric / cancelRegisterMetric
    // ------------------------------------------------------------------------------------------

    function test_activateRegister_setsLive() public {
        vm.prank(governance);
        adapter.proposeRegisterMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        adapter.activateRegisterMetric(METRIC_ID);

        UMAAdapter.UMAMetric memory m = adapter.metricOf(METRIC_ID);
        assertTrue(m.registered);
        assertEq(m.bond, BOND);
    }

    function test_activateRegister_revertsIfNoPending() public {
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.NoPendingProposal.selector, METRIC_ID));
        adapter.activateRegisterMetric(METRIC_ID);
    }

    function test_activateRegister_revertsIfTimelockNotElapsed() public {
        vm.prank(governance);
        adapter.proposeRegisterMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.TimelockNotElapsed.selector, readyAt));
        adapter.activateRegisterMetric(METRIC_ID);
    }

    function test_activateRegister_revertsIfPendingIsUpdate() public {
        _register(METRIC_ID);
        vm.prank(governance);
        adapter.proposeUpdateMetric(METRIC_ID, BOND * 2, LIVENESS, IDENTIFIER, address(usdc));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(UMAAdapter.WrongPendingKind.selector);
        adapter.activateRegisterMetric(METRIC_ID);
    }

    function test_cancelRegister_clearsPending() public {
        vm.prank(governance);
        adapter.proposeRegisterMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));
        vm.prank(governance);
        adapter.cancelRegisterMetric(METRIC_ID);
        assertFalse(adapter.pendingMetricOf(METRIC_ID).exists);
    }

    function test_cancelRegister_revertsForStranger() public {
        vm.prank(governance);
        adapter.proposeRegisterMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.Unauthorized.selector, stranger));
        adapter.cancelRegisterMetric(METRIC_ID);
    }

    function test_cancelRegister_revertsIfNoPending() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.NoPendingProposal.selector, METRIC_ID));
        adapter.cancelRegisterMetric(METRIC_ID);
    }

    function test_cancelRegister_revertsIfPendingIsUpdate() public {
        _register(METRIC_ID);
        vm.prank(governance);
        adapter.proposeUpdateMetric(METRIC_ID, BOND * 2, LIVENESS, IDENTIFIER, address(usdc));
        vm.prank(governance);
        vm.expectRevert(UMAAdapter.WrongPendingKind.selector);
        adapter.cancelRegisterMetric(METRIC_ID);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: update metric
    // ------------------------------------------------------------------------------------------

    function test_proposeUpdate_revertsIfNotRegistered() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.MetricNotRegistered.selector, METRIC_ID));
        adapter.proposeUpdateMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));
    }

    function test_proposeUpdate_revertsForStranger() public {
        _register(METRIC_ID);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.Unauthorized.selector, stranger));
        adapter.proposeUpdateMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));
    }

    function test_proposeUpdate_revertsIfPendingExists() public {
        _register(METRIC_ID);
        vm.prank(governance);
        adapter.proposeUpdateMetric(METRIC_ID, BOND * 2, LIVENESS, IDENTIFIER, address(usdc));
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.PendingProposalExists.selector, METRIC_ID));
        adapter.proposeUpdateMetric(METRIC_ID, BOND * 3, LIVENESS, IDENTIFIER, address(usdc));
    }

    function test_proposeUpdate_revertsOnBadBond() public {
        _register(METRIC_ID);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.BondOutOfRange.selector, uint256(0)));
        adapter.proposeUpdateMetric(METRIC_ID, 0, LIVENESS, IDENTIFIER, address(usdc));
    }

    function test_proposeUpdate_revertsOnBadLiveness() public {
        _register(METRIC_ID);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.LivenessOutOfRange.selector, uint64(0)));
        adapter.proposeUpdateMetric(METRIC_ID, BOND, 0, IDENTIFIER, address(usdc));
    }

    function test_proposeUpdate_revertsOnZeroCurrency() public {
        _register(METRIC_ID);
        vm.prank(governance);
        vm.expectRevert(UMAAdapter.InvalidConfig.selector);
        adapter.proposeUpdateMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(0));
    }

    function test_activateUpdate_appliesNewConfig() public {
        _register(METRIC_ID);
        vm.prank(governance);
        adapter.proposeUpdateMetric(METRIC_ID, BOND * 2, LIVENESS * 2, IDENTIFIER, address(usdc));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        adapter.activateUpdateMetric(METRIC_ID);

        UMAAdapter.UMAMetric memory m = adapter.metricOf(METRIC_ID);
        assertEq(m.bond, BOND * 2);
        assertEq(uint256(m.livenessSeconds), LIVENESS * 2);
    }

    function test_activateUpdate_revertsIfNoPending() public {
        _register(METRIC_ID);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.NoPendingProposal.selector, METRIC_ID));
        adapter.activateUpdateMetric(METRIC_ID);
    }

    function test_activateUpdate_revertsIfTimelockNotElapsed() public {
        _register(METRIC_ID);
        vm.prank(governance);
        adapter.proposeUpdateMetric(METRIC_ID, BOND * 2, LIVENESS, IDENTIFIER, address(usdc));
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.TimelockNotElapsed.selector, readyAt));
        adapter.activateUpdateMetric(METRIC_ID);
    }

    function test_activateUpdate_revertsIfPendingIsRegister() public {
        vm.prank(governance);
        adapter.proposeRegisterMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(UMAAdapter.WrongPendingKind.selector);
        adapter.activateUpdateMetric(METRIC_ID);
    }

    function test_cancelUpdate_clearsPending() public {
        _register(METRIC_ID);
        vm.prank(governance);
        adapter.proposeUpdateMetric(METRIC_ID, BOND * 2, LIVENESS, IDENTIFIER, address(usdc));
        vm.prank(governance);
        adapter.cancelUpdateMetric(METRIC_ID);
        assertFalse(adapter.pendingMetricOf(METRIC_ID).exists);
    }

    function test_cancelUpdate_revertsForStranger() public {
        _register(METRIC_ID);
        vm.prank(governance);
        adapter.proposeUpdateMetric(METRIC_ID, BOND * 2, LIVENESS, IDENTIFIER, address(usdc));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.Unauthorized.selector, stranger));
        adapter.cancelUpdateMetric(METRIC_ID);
    }

    function test_cancelUpdate_revertsIfNoPending() public {
        _register(METRIC_ID);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.NoPendingProposal.selector, METRIC_ID));
        adapter.cancelUpdateMetric(METRIC_ID);
    }

    function test_cancelUpdate_revertsIfPendingIsRegister() public {
        vm.prank(governance);
        adapter.proposeRegisterMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));
        vm.prank(governance);
        vm.expectRevert(UMAAdapter.WrongPendingKind.selector);
        adapter.cancelUpdateMetric(METRIC_ID);
    }

    // ------------------------------------------------------------------------------------------
    // Assertion: happy path (undisputed → auto-truthful after liveness)
    // ------------------------------------------------------------------------------------------

    function test_proposeAssertion_pullsBondAndStoresRecord() public {
        _register(METRIC_ID);

        uint256 asserterPre = usdc.balanceOf(asserter);
        uint256 ooPre = usdc.balanceOf(address(oo));

        vm.prank(asserter);
        bytes32 assertionId = adapter.proposeAssertion(METRIC_ID, 12345, bytes("metricId=...value=12345"));
        assertTrue(assertionId != bytes32(0));

        assertEq(usdc.balanceOf(asserter), asserterPre - BOND);
        assertEq(usdc.balanceOf(address(oo)), ooPre + BOND);

        UMAAdapter.AssertionRecord memory rec = adapter.assertionOf(assertionId);
        assertEq(rec.metricId, METRIC_ID);
        assertEq(rec.claimedValue, 12345);
        assertEq(rec.asserter, asserter);
        assertFalse(rec.settled);
    }

    function test_proposeAssertion_revertsIfNotRegistered() public {
        vm.prank(asserter);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.MetricNotRegistered.selector, METRIC_ID));
        adapter.proposeAssertion(METRIC_ID, 1, bytes(""));
    }

    function test_settleAssertion_happyPath() public {
        _register(METRIC_ID);
        vm.prank(asserter);
        bytes32 assertionId = adapter.proposeAssertion(METRIC_ID, 9876, bytes(""));
        // Pull `assertedAt` from the contract (rather than `block.timestamp` on the test side) so
        // we are bullet-proof against IR-optimizer reordering of the cheatcode-adjacent timestamp
        // read. The contract recorded the timestamp inside the proposeAssertion call.
        uint64 assertedAt = adapter.assertionOf(assertionId).assertedAt;

        // before liveness: settle reverts via the try/catch translation
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.AssertionNotSettled.selector, assertionId));
        adapter.settleAssertion(assertionId);

        // after liveness: anyone can settle
        vm.warp(block.timestamp + LIVENESS + 1);
        vm.prank(stranger);
        adapter.settleAssertion(assertionId);

        (uint256 v, uint64 ts) = adapter.latestValue(METRIC_ID);
        assertEq(v, 9876);
        assertEq(uint256(ts), assertedAt);

        UMAAdapter.AssertionRecord memory rec = adapter.assertionOf(assertionId);
        assertTrue(rec.settled);
    }

    function test_settleAssertion_revertsIfNotFound() public {
        bytes32 fake = keccak256("nope");
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.AssertionNotFound.selector, fake));
        adapter.settleAssertion(fake);
    }

    function test_settleAssertion_revertsIfAlreadySettled() public {
        _register(METRIC_ID);
        vm.prank(asserter);
        bytes32 assertionId = adapter.proposeAssertion(METRIC_ID, 1, bytes(""));
        vm.warp(block.timestamp + LIVENESS + 1);
        adapter.settleAssertion(assertionId);

        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.AssertionAlreadySettled.selector, assertionId));
        adapter.settleAssertion(assertionId);
    }

    // ------------------------------------------------------------------------------------------
    // Assertion: dispute path
    // ------------------------------------------------------------------------------------------

    function test_settleAssertion_disputed_dvmTruthful_recordsValue() public {
        _register(METRIC_ID);
        vm.prank(asserter);
        bytes32 assertionId = adapter.proposeAssertion(METRIC_ID, 4242, bytes(""));
        uint64 assertedAt = adapter.assertionOf(assertionId).assertedAt;

        // Dispute filed before liveness elapses.
        oo.disputeAssertion(assertionId);
        // DVM resolves "truthful" — asserter wins, claimed value stands.
        oo.resolveDispute(assertionId, true);

        // Settle — does NOT require liveness on the disputed path.
        adapter.settleAssertion(assertionId);

        (uint256 v, uint64 ts) = adapter.latestValue(METRIC_ID);
        assertEq(v, 4242);
        assertEq(uint256(ts), assertedAt);
    }

    function test_settleAssertion_disputed_dvmRejects_doesNotRecord() public {
        _register(METRIC_ID);
        vm.prank(asserter);
        bytes32 assertionId = adapter.proposeAssertion(METRIC_ID, 9999, bytes(""));

        oo.disputeAssertion(assertionId);
        oo.resolveDispute(assertionId, false);

        adapter.settleAssertion(assertionId);

        (uint256 v, uint64 ts) = adapter.latestValue(METRIC_ID);
        assertEq(v, 0);
        assertEq(uint256(ts), 0);
    }

    function test_settleAssertion_disputed_revertsIfDvmNotResolved() public {
        _register(METRIC_ID);
        vm.prank(asserter);
        bytes32 assertionId = adapter.proposeAssertion(METRIC_ID, 1, bytes(""));
        oo.disputeAssertion(assertionId);

        // OO reverts because DVM has not resolved; UMAAdapter translates this to AssertionNotSettled.
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.AssertionNotSettled.selector, assertionId));
        adapter.settleAssertion(assertionId);
    }

    function test_settleAssertion_backdatedDoesNotOverwriteNewer() public {
        _register(METRIC_ID);

        // First assertion at t0 with value 100.
        vm.prank(asserter);
        bytes32 idA = adapter.proposeAssertion(METRIC_ID, 100, bytes(""));

        // Advance, second assertion at t1 with value 200.
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(asserter);
        bytes32 idB = adapter.proposeAssertion(METRIC_ID, 200, bytes(""));

        // Past liveness for both.
        vm.warp(block.timestamp + LIVENESS + 1);

        // Settle the *newer* assertion first — value should be 200.
        adapter.settleAssertion(idB);
        (uint256 v1, uint64 ts1) = adapter.latestValue(METRIC_ID);
        assertEq(v1, 200);

        // Now settle the older assertion — it must NOT clobber the newer value.
        adapter.settleAssertion(idA);
        (uint256 v2, uint64 ts2) = adapter.latestValue(METRIC_ID);
        assertEq(v2, 200);
        assertEq(uint256(ts2), uint256(ts1));
    }

    // ------------------------------------------------------------------------------------------
    // OOv3 misbehavior paths (defense-in-depth)
    // ------------------------------------------------------------------------------------------

    function test_proposeAssertion_revertsIfOOReturnsZeroId() public {
        _register(METRIC_ID);
        oo.setForcedNextId(bytes32(0));
        vm.prank(asserter);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.AssertionNotFound.selector, bytes32(0)));
        adapter.proposeAssertion(METRIC_ID, 1, bytes(""));
    }

    function test_proposeAssertion_revertsIfOOReturnsCollidingId() public {
        _register(METRIC_ID);
        vm.prank(asserter);
        bytes32 id = adapter.proposeAssertion(METRIC_ID, 1, bytes(""));

        // Force the mock to reuse the same id for the next call.
        oo.setForcedNextId(id);
        vm.prank(asserter);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.AssertionNotFound.selector, id));
        adapter.proposeAssertion(METRIC_ID, 2, bytes(""));
    }

    // ------------------------------------------------------------------------------------------
    // Reads
    // ------------------------------------------------------------------------------------------

    function test_readMetric_revertsIfNotRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.MetricNotRegistered.selector, METRIC_ID));
        adapter.readMetric(METRIC_ID);
    }

    function test_readMetric_returnsZeroBeforeFirstSettlement() public {
        _register(METRIC_ID);
        IOracleRouter.OracleReading memory r = adapter.readMetric(METRIC_ID);
        assertEq(r.value, 0);
        assertEq(uint256(r.updatedAt), 0);
        assertFalse(r.degraded);
    }

    function test_readMetric_returnsSettledValue() public {
        _register(METRIC_ID);
        vm.prank(asserter);
        bytes32 id = adapter.proposeAssertion(METRIC_ID, 777, bytes(""));
        uint64 assertedAt = adapter.assertionOf(id).assertedAt;
        vm.warp(block.timestamp + LIVENESS + 1);
        adapter.settleAssertion(id);

        IOracleRouter.OracleReading memory r = adapter.readMetric(METRIC_ID);
        assertEq(r.value, 777);
        assertEq(uint256(r.updatedAt), assertedAt);
        assertFalse(r.degraded);
    }

    function test_latestValue_initiallyZero() public {
        _register(METRIC_ID);
        (uint256 v, uint64 ts) = adapter.latestValue(METRIC_ID);
        assertEq(v, 0);
        assertEq(uint256(ts), 0);
    }

    function test_assertionOf_returnsEmptyForUnknownId() public view {
        UMAAdapter.AssertionRecord memory rec = adapter.assertionOf(keccak256("nope"));
        assertEq(rec.asserter, address(0));
    }

    function test_pendingMetricOf_returnsEmptyForUnknown() public view {
        UMAAdapter.PendingMetric memory p = adapter.pendingMetricOf(METRIC_ID);
        assertFalse(p.exists);
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    function test_proposeGovernanceTransfer_setsPending() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(newGov);
        (address pending, uint64 readyAt) = adapter.pendingGovernanceTransfer();
        assertEq(pending, newGov);
        assertEq(uint256(readyAt), block.timestamp + TIMELOCK_DELAY);
    }

    function test_proposeGovernanceTransfer_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.Unauthorized.selector, stranger));
        adapter.proposeGovernanceTransfer(makeAddr("newGov"));
    }

    function test_proposeGovernanceTransfer_revertsOnZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(UMAAdapter.InvalidConfig.selector);
        adapter.proposeGovernanceTransfer(address(0));
    }

    function test_proposeGovernanceTransfer_revertsIfPendingExists() public {
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(makeAddr("a"));
        vm.prank(governance);
        vm.expectRevert(UMAAdapter.PendingGovernanceTransferExists.selector);
        adapter.proposeGovernanceTransfer(makeAddr("b"));
    }

    function test_activateGovernanceTransfer_rotates() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(newGov);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        adapter.activateGovernanceTransfer();

        assertEq(adapter.governance(), newGov);
        (address pending, uint64 readyAt) = adapter.pendingGovernanceTransfer();
        assertEq(pending, address(0));
        assertEq(uint256(readyAt), 0);

        // Old governance can no longer act.
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.Unauthorized.selector, governance));
        adapter.proposeRegisterMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));

        // New governance can.
        vm.prank(newGov);
        adapter.proposeRegisterMetric(METRIC_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));
    }

    function test_activateGovernanceTransfer_revertsIfNoPending() public {
        vm.expectRevert(UMAAdapter.NoPendingGovernanceTransfer.selector);
        adapter.activateGovernanceTransfer();
    }

    function test_activateGovernanceTransfer_revertsIfTimelockNotElapsed() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(newGov);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.TimelockNotElapsed.selector, readyAt));
        adapter.activateGovernanceTransfer();
    }

    function test_cancelGovernanceTransfer_clearsPending() public {
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(makeAddr("a"));
        vm.prank(governance);
        adapter.cancelGovernanceTransfer();
        (address pending, uint64 readyAt) = adapter.pendingGovernanceTransfer();
        assertEq(pending, address(0));
        assertEq(uint256(readyAt), 0);
    }

    function test_cancelGovernanceTransfer_revertsForStranger() public {
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(makeAddr("a"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.Unauthorized.selector, stranger));
        adapter.cancelGovernanceTransfer();
    }

    function test_cancelGovernanceTransfer_revertsIfNoPending() public {
        vm.prank(governance);
        vm.expectRevert(UMAAdapter.NoPendingGovernanceTransfer.selector);
        adapter.cancelGovernanceTransfer();
    }

    // ------------------------------------------------------------------------------------------
    // Upgrade authorization
    // ------------------------------------------------------------------------------------------

    function test_upgradeTo_revertsForStranger() public {
        UMAAdapter newImpl = new UMAAdapter();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UMAAdapter.Unauthorized.selector, stranger));
        adapter.upgradeToAndCall(address(newImpl), bytes(""));
    }

    function test_upgradeTo_succeedsForGovernance() public {
        UMAAdapter newImpl = new UMAAdapter();
        vm.prank(governance);
        adapter.upgradeToAndCall(address(newImpl), bytes(""));

        // Storage persists across the upgrade.
        assertEq(adapter.governance(), governance);
    }

    // ------------------------------------------------------------------------------------------
    // Multi-metric isolation
    // ------------------------------------------------------------------------------------------

    function test_metrics_areIsolated() public {
        _register(METRIC_ID);
        _register(METRIC_ID_2);

        vm.prank(asserter);
        bytes32 idA = adapter.proposeAssertion(METRIC_ID, 111, bytes(""));
        vm.prank(asserter);
        bytes32 idB = adapter.proposeAssertion(METRIC_ID_2, 222, bytes(""));

        vm.warp(block.timestamp + LIVENESS + 1);
        adapter.settleAssertion(idA);
        adapter.settleAssertion(idB);

        (uint256 v1,) = adapter.latestValue(METRIC_ID);
        (uint256 v2,) = adapter.latestValue(METRIC_ID_2);
        assertEq(v1, 111);
        assertEq(v2, 222);
    }
}
