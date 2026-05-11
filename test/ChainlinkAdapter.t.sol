// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test} from "forge-std/Test.sol";

import {ChainlinkAdapter} from "../src/oracle/ChainlinkAdapter.sol";
import {IOracleRouter} from "../src/oracle/IOracleRouter.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";

import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

contract ChainlinkAdapterTest is Test {
    OracleRouter internal router;
    ChainlinkAdapter internal adapter;
    MockAggregatorV3 internal feed8;
    MockAggregatorV3 internal feed6;
    MockAggregatorV3 internal feed18;

    address internal governance = makeAddr("governance");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");
    uint32 internal constant TIMELOCK_DELAY = 2 days;
    uint32 internal constant MAX_STALENESS = 3600;

    bytes32 internal constant METRIC_8 = keccak256("metric.eth.usd");
    bytes32 internal constant METRIC_6 = keccak256("metric.tlx.usd");
    bytes32 internal constant METRIC_18 = keccak256("metric.idx.composite");

    // ------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------

    function setUp() public {
        // Warp to a sane wall-clock time so updatedAt validations don't underflow.
        vm.warp(2_000_000_000);

        // Router behind a UUPS proxy.
        OracleRouter routerImpl = new OracleRouter();
        bytes memory routerInit = abi.encodeCall(OracleRouter.initialize, (governance, operator, TIMELOCK_DELAY));
        router = OracleRouter(address(new ERC1967Proxy(address(routerImpl), routerInit)));

        // ChainlinkAdapter behind a UUPS proxy.
        ChainlinkAdapter adapterImpl = new ChainlinkAdapter();
        bytes memory adapterInit =
            abi.encodeCall(ChainlinkAdapter.initialize, (IOracleRouter(address(router)), governance, TIMELOCK_DELAY));
        adapter = ChainlinkAdapter(address(new ERC1967Proxy(address(adapterImpl), adapterInit)));

        feed8 = new MockAggregatorV3(8);
        feed6 = new MockAggregatorV3(6);
        feed18 = new MockAggregatorV3(18);
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _registerFeed(bytes32 metricId, address aggregator, uint32 staleness) internal {
        vm.prank(governance);
        adapter.proposeRegisterFeed(metricId, aggregator, staleness);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        adapter.activateRegisterFeed(metricId);
    }

    // ------------------------------------------------------------------------------------------
    // initialize
    // ------------------------------------------------------------------------------------------

    function test_Initialize_StoresParams() public view {
        assertEq(address(adapter.router()), address(router));
        assertEq(adapter.governance(), governance);
        assertEq(adapter.timelockDelay(), TIMELOCK_DELAY);
        assertEq(adapter.pendingGovernance(), address(0));
        assertEq(adapter.pendingGovernanceActivatesAt(), 0);
    }

    function test_Initialize_RevertOnZeroRouter() public {
        ChainlinkAdapter impl = new ChainlinkAdapter();
        bytes memory init =
            abi.encodeCall(ChainlinkAdapter.initialize, (IOracleRouter(address(0)), governance, TIMELOCK_DELAY));
        vm.expectRevert(ChainlinkAdapter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_Initialize_RevertOnZeroGovernance() public {
        ChainlinkAdapter impl = new ChainlinkAdapter();
        bytes memory init =
            abi.encodeCall(ChainlinkAdapter.initialize, (IOracleRouter(address(router)), address(0), TIMELOCK_DELAY));
        vm.expectRevert(ChainlinkAdapter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_Initialize_RevertOnTimelockTooShort() public {
        ChainlinkAdapter impl = new ChainlinkAdapter();
        bytes memory init =
            abi.encodeCall(ChainlinkAdapter.initialize, (IOracleRouter(address(router)), governance, 1 minutes));
        vm.expectRevert(ChainlinkAdapter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_Initialize_RevertOnTimelockTooLong() public {
        ChainlinkAdapter impl = new ChainlinkAdapter();
        bytes memory init =
            abi.encodeCall(ChainlinkAdapter.initialize, (IOracleRouter(address(router)), governance, 60 days));
        vm.expectRevert(ChainlinkAdapter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_Initialize_DisablesOnImplementation() public {
        ChainlinkAdapter impl = new ChainlinkAdapter();
        // Direct call on the implementation must revert (initializers disabled).
        vm.expectRevert();
        impl.initialize(IOracleRouter(address(router)), governance, TIMELOCK_DELAY);
    }

    // ------------------------------------------------------------------------------------------
    // proposeRegisterFeed
    // ------------------------------------------------------------------------------------------

    function test_ProposeRegister_HappyPath() public {
        uint64 activatesAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit ChainlinkAdapter.FeedRegisterProposed(METRIC_8, address(feed8), 8, MAX_STALENESS, activatesAt);
        vm.prank(governance);
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), MAX_STALENESS);

        ChainlinkAdapter.PendingFeed memory p = adapter.pendingRegisterOf(METRIC_8);
        assertEq(p.aggregator, address(feed8));
        assertEq(p.decimals, 8);
        assertEq(p.maxStaleness, MAX_STALENESS);
        assertEq(p.activatesAt, activatesAt);
        assertTrue(p.exists);
    }

    function test_ProposeRegister_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.Unauthorized.selector, stranger));
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), MAX_STALENESS);
    }

    function test_ProposeRegister_RevertOnZeroAggregator() public {
        vm.prank(governance);
        vm.expectRevert(ChainlinkAdapter.InvalidAggregator.selector);
        adapter.proposeRegisterFeed(METRIC_8, address(0), MAX_STALENESS);
    }

    function test_ProposeRegister_RevertOnStalenessTooShort() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.MaxStalenessOutOfRange.selector, uint32(59)));
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), 59);
    }

    function test_ProposeRegister_RevertOnStalenessTooLong() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.MaxStalenessOutOfRange.selector, uint32(86_401)));
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), 86_401);
    }

    function test_ProposeRegister_AcceptsStalenessBoundaries() public {
        // 60 — at the floor — should succeed
        vm.prank(governance);
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), 60);
        ChainlinkAdapter.PendingFeed memory p = adapter.pendingRegisterOf(METRIC_8);
        assertEq(p.maxStaleness, 60);
        // cancel and re-propose at the ceiling — should also succeed
        vm.prank(governance);
        adapter.cancelRegisterFeed(METRIC_8);
        vm.prank(governance);
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), 86_400);
        ChainlinkAdapter.PendingFeed memory p2 = adapter.pendingRegisterOf(METRIC_8);
        assertEq(p2.maxStaleness, 86_400);
    }

    function test_ProposeRegister_RevertOnAlreadyRegistered() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.FeedAlreadyRegistered.selector, METRIC_8));
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), MAX_STALENESS);
    }

    function test_ProposeRegister_RevertOnPendingExists() public {
        vm.startPrank(governance);
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), MAX_STALENESS);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.PendingProposalExists.selector, METRIC_8));
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), MAX_STALENESS);
        vm.stopPrank();
    }

    function test_ProposeRegister_RevertOnUnsupportedDecimals() public {
        MockAggregatorV3 bigDec = new MockAggregatorV3(19);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.UnsupportedDecimals.selector, uint8(19)));
        adapter.proposeRegisterFeed(METRIC_8, address(bigDec), MAX_STALENESS);
    }

    // ------------------------------------------------------------------------------------------
    // activateRegisterFeed
    // ------------------------------------------------------------------------------------------

    function test_ActivateRegister_HappyPath() public {
        vm.prank(governance);
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), MAX_STALENESS);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit ChainlinkAdapter.FeedRegisterActivated(METRIC_8, address(feed8), 8, MAX_STALENESS);
        // Permissionless after timelock
        vm.prank(stranger);
        adapter.activateRegisterFeed(METRIC_8);

        ChainlinkAdapter.ChainlinkFeed memory f = adapter.feedOf(METRIC_8);
        assertEq(f.aggregator, address(feed8));
        assertEq(f.decimals, 8);
        assertEq(f.maxStaleness, MAX_STALENESS);
        assertTrue(f.registered);

        // pending cleared
        ChainlinkAdapter.PendingFeed memory p = adapter.pendingRegisterOf(METRIC_8);
        assertFalse(p.exists);
    }

    function test_ActivateRegister_RevertOnNoPending() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.NoPendingProposal.selector, METRIC_8));
        adapter.activateRegisterFeed(METRIC_8);
    }

    function test_ActivateRegister_RevertBeforeTimelock() public {
        vm.prank(governance);
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), MAX_STALENESS);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.TimelockNotElapsed.selector, readyAt));
        adapter.activateRegisterFeed(METRIC_8);
    }

    // ------------------------------------------------------------------------------------------
    // cancelRegisterFeed
    // ------------------------------------------------------------------------------------------

    function test_CancelRegister_HappyPath() public {
        vm.prank(governance);
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), MAX_STALENESS);

        vm.expectEmit(true, false, false, false, address(adapter));
        emit ChainlinkAdapter.FeedRegisterCancelled(METRIC_8);
        vm.prank(governance);
        adapter.cancelRegisterFeed(METRIC_8);

        ChainlinkAdapter.PendingFeed memory p = adapter.pendingRegisterOf(METRIC_8);
        assertFalse(p.exists);

        // Re-propose works after cancel
        vm.prank(governance);
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), MAX_STALENESS);
    }

    function test_CancelRegister_RevertOnNonGovernance() public {
        vm.prank(governance);
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), MAX_STALENESS);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.Unauthorized.selector, stranger));
        adapter.cancelRegisterFeed(METRIC_8);
    }

    function test_CancelRegister_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.NoPendingProposal.selector, METRIC_8));
        adapter.cancelRegisterFeed(METRIC_8);
    }

    // ------------------------------------------------------------------------------------------
    // proposeUpdateFeed / activate / cancel
    // ------------------------------------------------------------------------------------------

    function test_ProposeUpdate_RevertOnNotRegistered() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.FeedNotRegistered.selector, METRIC_8));
        adapter.proposeUpdateFeed(METRIC_8, address(feed8), MAX_STALENESS);
    }

    function test_ProposeUpdate_RevertOnNonGovernance() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.Unauthorized.selector, stranger));
        adapter.proposeUpdateFeed(METRIC_8, address(feed6), MAX_STALENESS);
    }

    function test_ProposeUpdate_RevertOnZeroAggregator() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        vm.prank(governance);
        vm.expectRevert(ChainlinkAdapter.InvalidAggregator.selector);
        adapter.proposeUpdateFeed(METRIC_8, address(0), MAX_STALENESS);
    }

    function test_ProposeUpdate_RevertOnStalenessOutOfRange() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.MaxStalenessOutOfRange.selector, uint32(0)));
        adapter.proposeUpdateFeed(METRIC_8, address(feed8), 0);
    }

    function test_ProposeUpdate_RevertOnPendingExists() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        vm.startPrank(governance);
        adapter.proposeUpdateFeed(METRIC_8, address(feed6), MAX_STALENESS);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.PendingProposalExists.selector, METRIC_8));
        adapter.proposeUpdateFeed(METRIC_8, address(feed18), MAX_STALENESS);
        vm.stopPrank();
    }

    function test_ProposeUpdate_RevertOnUnsupportedDecimals() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        MockAggregatorV3 bigDec = new MockAggregatorV3(20);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.UnsupportedDecimals.selector, uint8(20)));
        adapter.proposeUpdateFeed(METRIC_8, address(bigDec), MAX_STALENESS);
    }

    function test_UpdateFeed_HappyPath() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);

        // Seed feeds so reads can be validated post-update
        feed8.setAnswer(1_000_00000000, uint64(block.timestamp)); // 1000.00 at 8 dec
        feed6.setAnswer(2_000_000000, uint64(block.timestamp)); // 2000.000000 at 6 dec

        // pre-update reads from feed8 → 1000e18
        (uint256 v0,) = adapter.latestValue(METRIC_8);
        assertEq(v0, 1000e18);

        uint64 activatesAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit ChainlinkAdapter.FeedUpdateProposed(METRIC_8, address(feed6), 6, MAX_STALENESS, activatesAt);
        vm.prank(governance);
        adapter.proposeUpdateFeed(METRIC_8, address(feed6), MAX_STALENESS);

        // Pre-activation: still reads from feed8
        (uint256 v1,) = adapter.latestValue(METRIC_8);
        assertEq(v1, 1000e18);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        feed6.setAnswer(2_000_000000, uint64(block.timestamp)); // refresh updatedAt post-warp
        vm.expectEmit(true, false, false, true, address(adapter));
        emit ChainlinkAdapter.FeedUpdateActivated(METRIC_8, address(feed6), 6, MAX_STALENESS);
        vm.prank(stranger);
        adapter.activateUpdateFeed(METRIC_8);

        // Post-activation: reads from feed6 → 2000e18 after 6→18 rescale
        (uint256 v2,) = adapter.latestValue(METRIC_8);
        assertEq(v2, 2000e18);

        ChainlinkAdapter.PendingFeed memory p = adapter.pendingUpdateOf(METRIC_8);
        assertFalse(p.exists);
    }

    function test_ActivateUpdate_RevertOnNoPending() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.NoPendingProposal.selector, METRIC_8));
        adapter.activateUpdateFeed(METRIC_8);
    }

    function test_ActivateUpdate_RevertBeforeTimelock() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        vm.prank(governance);
        adapter.proposeUpdateFeed(METRIC_8, address(feed6), MAX_STALENESS);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.TimelockNotElapsed.selector, readyAt));
        adapter.activateUpdateFeed(METRIC_8);
    }

    function test_CancelUpdate_HappyPath() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        vm.prank(governance);
        adapter.proposeUpdateFeed(METRIC_8, address(feed6), MAX_STALENESS);

        vm.expectEmit(true, false, false, false, address(adapter));
        emit ChainlinkAdapter.FeedUpdateCancelled(METRIC_8);
        vm.prank(governance);
        adapter.cancelUpdateFeed(METRIC_8);

        assertFalse(adapter.pendingUpdateOf(METRIC_8).exists);

        // re-propose works
        vm.prank(governance);
        adapter.proposeUpdateFeed(METRIC_8, address(feed18), MAX_STALENESS);
    }

    function test_CancelUpdate_RevertOnNonGovernance() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        vm.prank(governance);
        adapter.proposeUpdateFeed(METRIC_8, address(feed6), MAX_STALENESS);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.Unauthorized.selector, stranger));
        adapter.cancelUpdateFeed(METRIC_8);
    }

    function test_CancelUpdate_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.NoPendingProposal.selector, METRIC_8));
        adapter.cancelUpdateFeed(METRIC_8);
    }

    // ------------------------------------------------------------------------------------------
    // Read scaling: 8 / 6 / 18 decimals
    // ------------------------------------------------------------------------------------------

    function test_Read_Scales8DecimalFeedTo1e18() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        uint64 ts = uint64(block.timestamp);
        feed8.setAnswer(1_234_56789012, ts); // 1_234.56789012 at 8 dec → 1_234.56789012e18

        (uint256 value, uint64 valueTs) = adapter.latestValue(METRIC_8);
        assertEq(value, uint256(1_234_56789012) * 1e10);
        assertEq(valueTs, ts);
    }

    function test_Read_Scales6DecimalFeedTo1e18() public {
        _registerFeed(METRIC_6, address(feed6), MAX_STALENESS);
        uint64 ts = uint64(block.timestamp);
        feed6.setAnswer(42_123456, ts); // 42.123456 at 6 dec → 42.123456e18

        (uint256 value, uint64 valueTs) = adapter.latestValue(METRIC_6);
        assertEq(value, uint256(42_123456) * 1e12);
        assertEq(valueTs, ts);
    }

    function test_Read_Passes18DecimalFeedUnchanged() public {
        _registerFeed(METRIC_18, address(feed18), MAX_STALENESS);
        uint64 ts = uint64(block.timestamp);
        feed18.setAnswer(int256(5_555e18), ts);

        (uint256 value, uint64 valueTs) = adapter.latestValue(METRIC_18);
        assertEq(value, 5_555e18);
        assertEq(valueTs, ts);
    }

    function test_Read_ReadMetricMatchesLatestValue() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        uint64 ts = uint64(block.timestamp);
        feed8.setAnswer(99_99999999, ts);

        IOracleRouter.OracleReading memory r = adapter.readMetric(METRIC_8);
        (uint256 v, uint64 t) = adapter.latestValue(METRIC_8);
        assertEq(r.value, v);
        assertEq(r.updatedAt, t);
        assertFalse(r.degraded);
    }

    function test_Read_LatestTimestampReturnsUpdatedAt() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        uint64 ts = uint64(block.timestamp);
        feed8.setAnswer(100_00000000, ts);
        assertEq(adapter.latestTimestamp(METRIC_8), ts);
    }

    // ------------------------------------------------------------------------------------------
    // Read validation: stale / negative / incomplete / unregistered
    // ------------------------------------------------------------------------------------------

    function test_Read_RevertOnNotRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.FeedNotRegistered.selector, METRIC_8));
        adapter.latestValue(METRIC_8);
    }

    function test_Read_RevertOnStaleData() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        uint64 ts = uint64(block.timestamp);
        feed8.setAnswer(100_00000000, ts);
        // Push past the staleness window
        vm.warp(uint256(ts) + uint256(MAX_STALENESS) + 1);
        uint64 cutoff = ts + MAX_STALENESS;
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.StaleData.selector, METRIC_8, ts, cutoff));
        adapter.latestValue(METRIC_8);
    }

    function test_Read_AtStalenessBoundaryPasses() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        uint64 ts = uint64(block.timestamp);
        feed8.setAnswer(100_00000000, ts);
        // Exactly at the boundary: now == updatedAt + maxStaleness — should pass (strict >)
        vm.warp(uint256(ts) + uint256(MAX_STALENESS));
        (uint256 v,) = adapter.latestValue(METRIC_8);
        assertEq(v, 100e18);
    }

    function test_Read_RevertOnNegativeAnswer() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        feed8.setAnswer(-1, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.InvalidAnswer.selector, int256(-1)));
        adapter.latestValue(METRIC_8);
    }

    function test_Read_RevertOnZeroAnswer() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        feed8.setAnswer(0, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.InvalidAnswer.selector, int256(0)));
        adapter.latestValue(METRIC_8);
    }

    function test_Read_RevertOnZeroUpdatedAt() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        // updatedAt == 0 marks an incomplete round
        feed8.setRound({roundId_: 1, answer_: 100_00000000, startedAt_: 0, updatedAt_: 0, answeredInRound_: 1});
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.IncompleteRound.selector, uint80(1), uint80(1)));
        adapter.latestValue(METRIC_8);
    }

    function test_Read_RevertOnIncompleteRound() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        uint64 ts = uint64(block.timestamp);
        // answeredInRound < roundId — stale carry-forward
        feed8.setRound({roundId_: 5, answer_: 100_00000000, startedAt_: ts, updatedAt_: ts, answeredInRound_: 4});
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.IncompleteRound.selector, uint80(5), uint80(4)));
        adapter.latestValue(METRIC_8);
    }

    // ------------------------------------------------------------------------------------------
    // Router integration
    // ------------------------------------------------------------------------------------------

    function test_Router_ReadsThroughAdapter() public {
        _registerFeed(METRIC_8, address(feed8), MAX_STALENESS);
        feed8.setAnswer(100_00000000, uint64(block.timestamp));

        // Register the metric in the router
        IOracleRouter.MetricConfig memory cfg = IOracleRouter.MetricConfig({
            sourceType: IOracleRouter.SourceType.CHAINLINK,
            adapter: address(adapter),
            fallbackAdapter: address(0),
            staleAfter: 2 hours,
            maxDeltaBps: 1000,
            degraded: false,
            expectedCadenceSeconds: 300
        });
        vm.prank(governance);
        router.proposeRegister(METRIC_8, cfg);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        router.activateRegister(METRIC_8);

        // Refresh feed timestamp post-warp so router staleAfter is satisfied
        feed8.setAnswer(100_00000000, uint64(block.timestamp));

        IOracleRouter.OracleReading memory r = router.read(METRIC_8);
        assertEq(r.value, 100e18);
        assertEq(r.updatedAt, uint64(block.timestamp));
        assertFalse(r.degraded);
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer
    // ------------------------------------------------------------------------------------------

    function test_GovernanceTransfer_HappyPath() public {
        address newGov = makeAddr("newGov");
        uint64 activatesAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit ChainlinkAdapter.GovernanceTransferProposed(newGov, activatesAt);
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(newGov);

        assertEq(adapter.governance(), governance);
        assertEq(adapter.pendingGovernance(), newGov);
        assertEq(adapter.pendingGovernanceActivatesAt(), activatesAt);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, true, false, false, address(adapter));
        emit ChainlinkAdapter.GovernanceTransferActivated(governance, newGov);
        vm.prank(stranger); // permissionless after timelock
        adapter.activateGovernanceTransfer();

        assertEq(adapter.governance(), newGov);
        assertEq(adapter.pendingGovernance(), address(0));
        assertEq(adapter.pendingGovernanceActivatesAt(), 0);
    }

    function test_ProposeGovernanceTransfer_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.Unauthorized.selector, stranger));
        adapter.proposeGovernanceTransfer(makeAddr("newGov"));
    }

    function test_ProposeGovernanceTransfer_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(ChainlinkAdapter.InvalidConfig.selector);
        adapter.proposeGovernanceTransfer(address(0));
    }

    function test_ProposeGovernanceTransfer_RevertOnPendingExists() public {
        vm.startPrank(governance);
        adapter.proposeGovernanceTransfer(makeAddr("g1"));
        vm.expectRevert(ChainlinkAdapter.PendingGovernanceTransferExists.selector);
        adapter.proposeGovernanceTransfer(makeAddr("g2"));
        vm.stopPrank();
    }

    function test_ActivateGovernanceTransfer_RevertOnNoPending() public {
        vm.expectRevert(ChainlinkAdapter.NoPendingGovernanceTransfer.selector);
        adapter.activateGovernanceTransfer();
    }

    function test_ActivateGovernanceTransfer_RevertBeforeTimelock() public {
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(makeAddr("newGov"));
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.TimelockNotElapsed.selector, readyAt));
        adapter.activateGovernanceTransfer();
    }

    function test_CancelGovernanceTransfer_HappyPath() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(newGov);

        vm.expectEmit(true, false, false, false, address(adapter));
        emit ChainlinkAdapter.GovernanceTransferCancelled(newGov);
        vm.prank(governance);
        adapter.cancelGovernanceTransfer();

        assertEq(adapter.pendingGovernance(), address(0));
        assertEq(adapter.pendingGovernanceActivatesAt(), 0);
    }

    function test_CancelGovernanceTransfer_RevertOnNonGovernance() public {
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(makeAddr("newGov"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.Unauthorized.selector, stranger));
        adapter.cancelGovernanceTransfer();
    }

    function test_CancelGovernanceTransfer_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(ChainlinkAdapter.NoPendingGovernanceTransfer.selector);
        adapter.cancelGovernanceTransfer();
    }

    function test_GovernanceTransfer_NewGovernanceCanAct() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        adapter.proposeGovernanceTransfer(newGov);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        adapter.activateGovernanceTransfer();

        // old governance now powerless
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.Unauthorized.selector, governance));
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), MAX_STALENESS);

        // new governance can register
        vm.prank(newGov);
        adapter.proposeRegisterFeed(METRIC_8, address(feed8), MAX_STALENESS);
    }

    // ------------------------------------------------------------------------------------------
    // Upgrade authorization
    // ------------------------------------------------------------------------------------------

    function test_UpgradeTo_RevertOnNonGovernance() public {
        ChainlinkAdapter newImpl = new ChainlinkAdapter();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkAdapter.Unauthorized.selector, stranger));
        adapter.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeTo_GovernanceSucceeds() public {
        ChainlinkAdapter newImpl = new ChainlinkAdapter();
        vm.prank(governance);
        adapter.upgradeToAndCall(address(newImpl), "");
        // State preserved through upgrade
        assertEq(adapter.governance(), governance);
    }
}
