// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test} from "forge-std/Test.sol";

import {OracleStorage} from "../src/libraries/StorageLib.sol";
import {IOracleRouter} from "../src/oracle/IOracleRouter.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {MockAdapter} from "./mocks/MockAdapter.sol";

contract OracleRouterTest is Test {
    OracleRouter internal router;

    address internal governance = makeAddr("governance");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");
    uint32 internal constant TIMELOCK_DELAY = 2 days;

    MockAdapter internal primary;
    MockAdapter internal fallbackAdapter;

    bytes32 internal constant METRIC_ID = keccak256("metric.spotify.monthlies.drake");

    // ------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------

    function setUp() public {
        OracleRouter impl = new OracleRouter();
        bytes memory initData = abi.encodeCall(OracleRouter.initialize, (governance, operator, TIMELOCK_DELAY));
        router = OracleRouter(address(new ERC1967Proxy(address(impl), initData)));

        primary = new MockAdapter();
        fallbackAdapter = new MockAdapter();
    }

    function _baseConfig() internal view returns (IOracleRouter.MetricConfig memory) {
        return IOracleRouter.MetricConfig({
            sourceType: IOracleRouter.SourceType.SIGNED,
            adapter: address(primary),
            fallbackAdapter: address(fallbackAdapter),
            staleAfter: 1 hours,
            maxDeltaBps: 300, // 3%
            degraded: false
        });
    }

    function _registerMetric() internal returns (IOracleRouter.MetricConfig memory cfg) {
        cfg = _baseConfig();
        vm.prank(governance);
        router.proposeRegister(METRIC_ID, cfg);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        router.activateRegister(METRIC_ID);
    }

    // ------------------------------------------------------------------------------------------
    // initialize
    // ------------------------------------------------------------------------------------------

    function test_Initialize_StoresParams() public view {
        assertEq(router.governance(), governance);
        assertEq(router.operator(), operator);
        assertEq(router.timelockDelay(), TIMELOCK_DELAY);
    }

    function test_Initialize_RevertOnZeroGovernance() public {
        OracleRouter impl = new OracleRouter();
        bytes memory initData = abi.encodeCall(OracleRouter.initialize, (address(0), operator, TIMELOCK_DELAY));
        vm.expectRevert(IOracleRouter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroOperator() public {
        OracleRouter impl = new OracleRouter();
        bytes memory initData = abi.encodeCall(OracleRouter.initialize, (governance, address(0), TIMELOCK_DELAY));
        vm.expectRevert(IOracleRouter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooShort() public {
        OracleRouter impl = new OracleRouter();
        bytes memory initData = abi.encodeCall(OracleRouter.initialize, (governance, operator, uint32(1 minutes)));
        vm.expectRevert(IOracleRouter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooLong() public {
        OracleRouter impl = new OracleRouter();
        bytes memory initData = abi.encodeCall(OracleRouter.initialize, (governance, operator, uint32(60 days)));
        vm.expectRevert(IOracleRouter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_DoubleInitReverts() public {
        vm.expectRevert();
        router.initialize(governance, operator, TIMELOCK_DELAY);
    }

    // ------------------------------------------------------------------------------------------
    // proposeRegister
    // ------------------------------------------------------------------------------------------

    function test_ProposeRegister_HappyPath() public {
        IOracleRouter.MetricConfig memory cfg = _baseConfig();
        vm.expectEmit(true, false, false, true, address(router));
        emit IOracleRouter.MetricProposed(METRIC_ID, cfg, uint64(block.timestamp + TIMELOCK_DELAY));
        vm.prank(governance);
        router.proposeRegister(METRIC_ID, cfg);

        OracleStorage.PendingChange memory p = router.pendingOf(METRIC_ID);
        assertTrue(p.exists);
        assertEq(p.activatesAt, uint64(block.timestamp + TIMELOCK_DELAY));
    }

    function test_ProposeRegister_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.Unauthorized.selector, stranger));
        router.proposeRegister(METRIC_ID, _baseConfig());
    }

    function test_ProposeRegister_RevertOnDuplicatePending() public {
        vm.startPrank(governance);
        router.proposeRegister(METRIC_ID, _baseConfig());
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.MetricAlreadyRegistered.selector, METRIC_ID));
        router.proposeRegister(METRIC_ID, _baseConfig());
        vm.stopPrank();
    }

    function test_ProposeRegister_RevertOnUnsetSourceType() public {
        IOracleRouter.MetricConfig memory cfg = _baseConfig();
        cfg.sourceType = IOracleRouter.SourceType.UNSET;
        vm.prank(governance);
        vm.expectRevert(IOracleRouter.InvalidConfig.selector);
        router.proposeRegister(METRIC_ID, cfg);
    }

    function test_ProposeRegister_RevertOnZeroAdapter() public {
        IOracleRouter.MetricConfig memory cfg = _baseConfig();
        cfg.adapter = address(0);
        vm.prank(governance);
        vm.expectRevert(IOracleRouter.InvalidConfig.selector);
        router.proposeRegister(METRIC_ID, cfg);
    }

    function test_ProposeRegister_RevertOnStaleAfterTooSmall() public {
        IOracleRouter.MetricConfig memory cfg = _baseConfig();
        cfg.staleAfter = 0;
        vm.prank(governance);
        vm.expectRevert(IOracleRouter.InvalidConfig.selector);
        router.proposeRegister(METRIC_ID, cfg);
    }

    function test_ProposeRegister_RevertOnStaleAfterTooLarge() public {
        IOracleRouter.MetricConfig memory cfg = _baseConfig();
        cfg.staleAfter = 60 days;
        vm.prank(governance);
        vm.expectRevert(IOracleRouter.InvalidConfig.selector);
        router.proposeRegister(METRIC_ID, cfg);
    }

    function test_ProposeRegister_RevertOnZeroMaxDelta() public {
        IOracleRouter.MetricConfig memory cfg = _baseConfig();
        cfg.maxDeltaBps = 0;
        vm.prank(governance);
        vm.expectRevert(IOracleRouter.InvalidConfig.selector);
        router.proposeRegister(METRIC_ID, cfg);
    }

    function test_ProposeRegister_RevertOnMaxDeltaAboveCeiling() public {
        IOracleRouter.MetricConfig memory cfg = _baseConfig();
        cfg.maxDeltaBps = 10_001;
        vm.prank(governance);
        vm.expectRevert(IOracleRouter.InvalidConfig.selector);
        router.proposeRegister(METRIC_ID, cfg);
    }

    // ------------------------------------------------------------------------------------------
    // activateRegister
    // ------------------------------------------------------------------------------------------

    function test_ActivateRegister_HappyPath() public {
        IOracleRouter.MetricConfig memory cfg = _baseConfig();
        vm.prank(governance);
        router.proposeRegister(METRIC_ID, cfg);
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectEmit(true, false, false, true, address(router));
        emit IOracleRouter.MetricActivated(METRIC_ID, cfg);
        router.activateRegister(METRIC_ID);

        IOracleRouter.MetricConfig memory active = router.configOf(METRIC_ID);
        assertEq(uint8(active.sourceType), uint8(cfg.sourceType));
        assertEq(active.adapter, cfg.adapter);
        assertFalse(router.pendingOf(METRIC_ID).exists);
    }

    function test_ActivateRegister_RevertOnNoPending() public {
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.NoPendingProposal.selector, METRIC_ID));
        router.activateRegister(METRIC_ID);
    }

    function test_ActivateRegister_RevertOnTimelockNotElapsed() public {
        vm.prank(governance);
        router.proposeRegister(METRIC_ID, _baseConfig());
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.TimelockNotElapsed.selector, METRIC_ID, readyAt));
        router.activateRegister(METRIC_ID);
    }

    function test_ActivateRegister_PermissionlessAfterTimelock() public {
        vm.prank(governance);
        router.proposeRegister(METRIC_ID, _baseConfig());
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(stranger); // anyone may activate
        router.activateRegister(METRIC_ID);
        assertTrue(router.configOf(METRIC_ID).sourceType != IOracleRouter.SourceType.UNSET);
    }

    // ------------------------------------------------------------------------------------------
    // cancelProposal
    // ------------------------------------------------------------------------------------------

    function test_CancelProposal_HappyPath() public {
        vm.prank(governance);
        router.proposeRegister(METRIC_ID, _baseConfig());
        vm.expectEmit(true, false, false, true, address(router));
        emit IOracleRouter.ProposalCancelled(METRIC_ID);
        vm.prank(governance);
        router.cancelProposal(METRIC_ID);
        assertFalse(router.pendingOf(METRIC_ID).exists);
    }

    function test_CancelProposal_RevertOnNonGovernance() public {
        vm.prank(governance);
        router.proposeRegister(METRIC_ID, _baseConfig());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.Unauthorized.selector, stranger));
        router.cancelProposal(METRIC_ID);
    }

    function test_CancelProposal_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.NoPendingProposal.selector, METRIC_ID));
        router.cancelProposal(METRIC_ID);
    }

    // ------------------------------------------------------------------------------------------
    // setDegraded
    // ------------------------------------------------------------------------------------------

    function test_SetDegraded_HappyPath() public {
        _registerMetric();
        bytes32 reasonHash = keccak256("oracle source unreachable for 3x cadence");
        vm.expectEmit(true, false, false, true, address(router));
        emit IOracleRouter.MetricDegraded(METRIC_ID, true, reasonHash);
        vm.prank(operator);
        router.setDegraded(METRIC_ID, true, reasonHash);
        assertTrue(router.configOf(METRIC_ID).degraded);

        // toggle off
        vm.prank(operator);
        router.setDegraded(METRIC_ID, false, bytes32(0));
        assertFalse(router.configOf(METRIC_ID).degraded);
    }

    function test_SetDegraded_RevertOnNonOperator() public {
        _registerMetric();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.Unauthorized.selector, stranger));
        router.setDegraded(METRIC_ID, true, bytes32(0));
    }

    function test_SetDegraded_RevertOnUnregisteredMetric() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.MetricNotRegistered.selector, METRIC_ID));
        router.setDegraded(METRIC_ID, true, bytes32(0));
    }

    // ------------------------------------------------------------------------------------------
    // proposeSetFallback / activateSetFallback
    // ------------------------------------------------------------------------------------------

    function test_SetFallback_HappyPath() public {
        _registerMetric();
        MockAdapter newFallback = new MockAdapter();
        vm.prank(governance);
        router.proposeSetFallback(METRIC_ID, address(newFallback));
        (address pending, uint64 readyAt) = router.pendingFallbackOf(METRIC_ID);
        assertEq(pending, address(newFallback));
        assertEq(readyAt, uint64(block.timestamp + TIMELOCK_DELAY));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, false, false, true, address(router));
        emit IOracleRouter.FallbackActivated(METRIC_ID, address(newFallback));
        router.activateSetFallback(METRIC_ID);
        assertEq(router.configOf(METRIC_ID).fallbackAdapter, address(newFallback));
    }

    function test_SetFallback_AllowsZeroAddress() public {
        _registerMetric();
        vm.prank(governance);
        router.proposeSetFallback(METRIC_ID, address(0));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        router.activateSetFallback(METRIC_ID);
        assertEq(router.configOf(METRIC_ID).fallbackAdapter, address(0));
    }

    function test_ProposeSetFallback_RevertOnNonGovernance() public {
        _registerMetric();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.Unauthorized.selector, stranger));
        router.proposeSetFallback(METRIC_ID, address(0xdead));
    }

    function test_ProposeSetFallback_RevertOnUnregisteredMetric() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.MetricNotRegistered.selector, METRIC_ID));
        router.proposeSetFallback(METRIC_ID, address(0xdead));
    }

    function test_ActivateSetFallback_RevertOnNoPending() public {
        _registerMetric();
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.NoPendingProposal.selector, METRIC_ID));
        router.activateSetFallback(METRIC_ID);
    }

    function test_ActivateSetFallback_RevertOnTimelockNotElapsed() public {
        _registerMetric();
        vm.prank(governance);
        router.proposeSetFallback(METRIC_ID, address(0xdead));
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.TimelockNotElapsed.selector, METRIC_ID, readyAt));
        router.activateSetFallback(METRIC_ID);
    }

    // ------------------------------------------------------------------------------------------
    // read
    // ------------------------------------------------------------------------------------------

    function test_Read_HappyPath() public {
        _registerMetric();
        primary.set(METRIC_ID, 1234e18, uint64(block.timestamp));
        IOracleRouter.OracleReading memory r = router.read(METRIC_ID);
        assertEq(r.value, 1234e18);
        assertEq(r.updatedAt, uint64(block.timestamp));
        assertFalse(r.degraded);
    }

    function test_Read_RevertOnUnregistered() public {
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.MetricNotRegistered.selector, METRIC_ID));
        router.read(METRIC_ID);
    }

    function test_Read_RevertOnStale() public {
        _registerMetric();
        primary.set(METRIC_ID, 1234e18, uint64(block.timestamp));
        // staleAfter is 1 hour; warp past
        uint64 ts = uint64(block.timestamp);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.StaleReading.selector, METRIC_ID, ts, uint32(1 hours)));
        router.read(METRIC_ID);
    }

    function test_Read_DegradedRoutesToFallback() public {
        _registerMetric();
        primary.set(METRIC_ID, 100e18, uint64(block.timestamp));
        fallbackAdapter.set(METRIC_ID, 999e18, uint64(block.timestamp));
        vm.prank(operator);
        router.setDegraded(METRIC_ID, true, bytes32(0));

        IOracleRouter.OracleReading memory r = router.read(METRIC_ID);
        assertEq(r.value, 999e18); // fallback
        assertTrue(r.degraded);
    }

    function test_Read_DegradedNoFallbackReverts() public {
        // register without a fallback
        IOracleRouter.MetricConfig memory cfg = _baseConfig();
        cfg.fallbackAdapter = address(0);
        vm.prank(governance);
        router.proposeRegister(METRIC_ID, cfg);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        router.activateRegister(METRIC_ID);

        vm.prank(operator);
        router.setDegraded(METRIC_ID, true, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.DegradedAndNoFallback.selector, METRIC_ID));
        router.read(METRIC_ID);
    }

    // ------------------------------------------------------------------------------------------
    // UUPS upgrade authorization
    // ------------------------------------------------------------------------------------------

    function test_UpgradeAuthorization_RevertOnNonGovernance() public {
        OracleRouter newImpl = new OracleRouter();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.Unauthorized.selector, stranger));
        router.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeAuthorization_GovernanceCanUpgrade() public {
        OracleRouter newImpl = new OracleRouter();
        vm.prank(governance);
        router.upgradeToAndCall(address(newImpl), "");
        // sanity: post-upgrade reads still work
        assertEq(router.governance(), governance);
    }

    // ------------------------------------------------------------------------------------------
    // Replace (re-propose after activation, with timelock)
    // ------------------------------------------------------------------------------------------

    function test_Replace_PreservesTimelock() public {
        _registerMetric();
        // re-propose with a different fallback
        IOracleRouter.MetricConfig memory cfg2 = _baseConfig();
        cfg2.fallbackAdapter = address(0xBEEF);
        vm.prank(governance);
        router.proposeRegister(METRIC_ID, cfg2);
        // before timelock, original config still active
        assertEq(router.configOf(METRIC_ID).fallbackAdapter, address(fallbackAdapter));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        router.activateRegister(METRIC_ID);
        assertEq(router.configOf(METRIC_ID).fallbackAdapter, address(0xBEEF));
    }
}
