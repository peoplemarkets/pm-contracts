// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {LPVault} from "../src/core/LPVault.sol";
import {PauseGuardian} from "../src/core/PauseGuardian.sol";
import {PerpEngine} from "../src/core/PerpEngine.sol";
import {ISubjectRegistry} from "../src/registry/ISubjectRegistry.sol";
import {SubjectRegistry} from "../src/registry/SubjectRegistry.sol";

import {PauseGuardianStorage} from "../src/libraries/StorageLib.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title PauseGuardianTest — full unit-coverage of the on-chain breaker detector.
/// @notice Uses a real PerpEngine instance as the mark source and a real SubjectRegistry as the
///         pause-state sink. The guardian is granted both PAUSE_GUARDIAN and SUBJECT_ADMIN roles
///         on the registry (see contract docs — `setFrozen` is `onlyAdmin`).
contract PauseGuardianTest is Test {
    PauseGuardian internal guardian;
    PerpEngine internal engine;
    LPVault internal vault;
    SubjectRegistry internal registry;
    MockUSDC internal usdc;

    address internal governance = makeAddr("governance");
    address internal vaultOperator = makeAddr("vaultOperator");
    address internal regAdmin = makeAddr("regAdmin");
    address internal regGuardian = makeAddr("regGuardian"); // human guardian, kept for unpause paths
    address internal kycWriter = makeAddr("kycWriter");
    address internal markWriter = makeAddr("markWriter");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant SUBJECT_ID = keccak256("drake");
    bytes32 internal constant CATEGORY_ID = keccak256("musician");

    uint32 internal constant TIMELOCK_DELAY = 2 days;
    uint256 internal constant ONE_18 = 1e18;
    uint256 internal constant INITIAL_MARK = 100 * ONE_18; // $100

    // ------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------

    function setUp() public {
        // Baseline timestamp far enough into the future that we don't underflow on warps.
        vm.warp(2_000_000_000);

        usdc = new MockUSDC();

        // 1. SubjectRegistry.
        {
            SubjectRegistry impl = new SubjectRegistry();
            address[] memory admins = new address[](1);
            admins[0] = regAdmin;
            address[] memory guardians = new address[](1);
            guardians[0] = regGuardian;
            address[] memory writers = new address[](1);
            writers[0] = kycWriter;
            bytes memory initData =
                abi.encodeCall(SubjectRegistry.initialize, (governance, TIMELOCK_DELAY, admins, guardians, writers));
            registry = SubjectRegistry(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 2. LPVault (PerpEngine depends on it to construct).
        {
            LPVault impl = new LPVault();
            bytes memory initData = abi.encodeCall(
                LPVault.initialize,
                (IERC20(address(usdc)), governance, vaultOperator, TIMELOCK_DELAY, "People Markets LP USDC", "pmUSDC")
            );
            vault = LPVault(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 3. PerpEngine.
        {
            PerpEngine impl = new PerpEngine();
            bytes memory initData =
                abi.encodeCall(PerpEngine.initialize, (governance, TIMELOCK_DELAY, address(registry), address(vault)));
            engine = PerpEngine(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 4. PauseGuardian itself.
        {
            PauseGuardian impl = new PauseGuardian();
            bytes memory initData = abi.encodeCall(
                PauseGuardian.initialize, (governance, address(engine), address(registry), TIMELOCK_DELAY)
            );
            guardian = PauseGuardian(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 5. Wire LPVault.setPerpEngine (timelocked).
        vm.prank(governance);
        vault.proposeSetPerpEngine(address(engine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateSetPerpEngine();

        // 6. Configure the PerpEngine: lift the mark-delta cap to its maximum so the test suite can
        // push large moves in a single tx. Production keepers push smaller increments.
        vm.startPrank(governance);
        engine.setMarkMaxDeltaBps(5_000);
        engine.proposeAddMarkWriter(markWriter);
        vm.stopPrank();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateAddMarkWriter(markWriter);

        // 7. Grant the guardian BOTH PAUSE_GUARDIAN and SUBJECT_ADMIN on the registry (timelocked).
        vm.startPrank(governance);
        registry.proposeRoleChange(address(guardian), ISubjectRegistry.Role.PAUSE_GUARDIAN, true);
        registry.proposeRoleChange(address(guardian), ISubjectRegistry.Role.SUBJECT_ADMIN, true);
        vm.stopPrank();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        registry.activateRoleChange(address(guardian), ISubjectRegistry.Role.PAUSE_GUARDIAN);
        registry.activateRoleChange(address(guardian), ISubjectRegistry.Role.SUBJECT_ADMIN);

        // 8. List the subject and push an initial mark.
        vm.prank(regAdmin);
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);
        _pushMark(INITIAL_MARK);
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _pushMark(uint256 newMark) internal {
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, newMark);
    }

    function _observe() internal {
        vm.prank(keeper);
        guardian.observe(SUBJECT_ID);
    }

    /// @dev Push a mark from a particular position and then observe. Mark is assumed to fit in the
    ///      PerpEngine's per-update delta cap (we configured it to 50% in setUp).
    function _pushAndObserve(uint256 newMark) internal {
        _pushMark(newMark);
        _observe();
    }

    /// @dev Push N small marks at `intervalSeconds` apart with mark unchanged, to seed the ring
    ///      buffer with historic data points before the breaker test proper. `block.timestamp` is
    ///      read aggressively by via_ir within a single Solidity function; the caller is expected
    ///      to manage time outside this helper and just call `_pushMark` / `_observe` directly
    ///      where loops are needed.
    function _seedStableHistory(uint256 mark, uint256 count, uint256 intervalSeconds) internal {
        uint256 now_ = block.timestamp;
        for (uint256 i = 0; i < count; ++i) {
            now_ += intervalSeconds;
            vm.warp(now_);
            _pushMark(mark);
            _observe();
        }
    }

    // ------------------------------------------------------------------------------------------
    // initialize
    // ------------------------------------------------------------------------------------------

    function test_Initialize_StoresParams() public view {
        assertEq(guardian.governance(), governance);
        assertEq(guardian.perpEngine(), address(engine));
        assertEq(guardian.subjectRegistry(), address(registry));
        assertEq(guardian.timelockDelay(), TIMELOCK_DELAY);

        (uint16 a5, uint16 cd30, uint16 fz60) = guardian.thresholds();
        assertEq(a5, 500);
        assertEq(cd30, 1_000);
        assertEq(fz60, 2_000);

        (uint32 w5, uint32 w30, uint32 w60) = guardian.windows();
        assertEq(w5, 30);
        assertEq(w30, 30 minutes);
        assertEq(w60, 1 hours);
    }

    function test_Initialize_RevertOnZeroGovernance() public {
        PauseGuardian impl = new PauseGuardian();
        bytes memory initData = abi.encodeCall(
            PauseGuardian.initialize, (address(0), address(engine), address(registry), TIMELOCK_DELAY)
        );
        vm.expectRevert(PauseGuardian.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroPerpEngine() public {
        PauseGuardian impl = new PauseGuardian();
        bytes memory initData = abi.encodeCall(
            PauseGuardian.initialize, (governance, address(0), address(registry), TIMELOCK_DELAY)
        );
        vm.expectRevert(PauseGuardian.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroRegistry() public {
        PauseGuardian impl = new PauseGuardian();
        bytes memory initData =
            abi.encodeCall(PauseGuardian.initialize, (governance, address(engine), address(0), TIMELOCK_DELAY));
        vm.expectRevert(PauseGuardian.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooShort() public {
        PauseGuardian impl = new PauseGuardian();
        bytes memory initData = abi.encodeCall(
            PauseGuardian.initialize, (governance, address(engine), address(registry), uint32(1 minutes))
        );
        vm.expectRevert(PauseGuardian.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooLong() public {
        PauseGuardian impl = new PauseGuardian();
        bytes memory initData = abi.encodeCall(
            PauseGuardian.initialize, (governance, address(engine), address(registry), uint32(60 days))
        );
        vm.expectRevert(PauseGuardian.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    // ------------------------------------------------------------------------------------------
    // observe — happy path & rate-limit
    // ------------------------------------------------------------------------------------------

    function test_Observe_RecordsFirstObservation() public {
        // No observation yet — mark already pushed in setUp.
        assertEq(guardian.observationCount(SUBJECT_ID), 0);
        _observe();
        assertEq(guardian.observationCount(SUBJECT_ID), 1);
        (uint192 mark, uint64 ts) = guardian.lastObservation(SUBJECT_ID);
        assertEq(uint256(mark), INITIAL_MARK);
        assertEq(uint256(ts), block.timestamp);
    }

    function test_Observe_RevertWhenMarkNeverPushed() public {
        bytes32 unknown = keccak256("unknown");
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.MarkNotSet.selector, unknown));
        guardian.observe(unknown);
    }

    function test_Observe_RateLimit_RevertsBeforeFiveSeconds() public {
        uint64 firstObsTs = uint64(block.timestamp);
        _observe();
        // Re-push at +4s (still inside the 5s rate-limit window) and try to observe again.
        vm.warp(firstObsTs + 4);
        _pushMark(INITIAL_MARK);
        vm.expectRevert(
            abi.encodeWithSelector(
                PauseGuardian.IntervalNotElapsed.selector, SUBJECT_ID, firstObsTs, firstObsTs + 5
            )
        );
        vm.prank(keeper);
        guardian.observe(SUBJECT_ID);
    }

    function test_Observe_RateLimit_PassesAtFiveSeconds() public {
        uint64 firstObsTs = uint64(block.timestamp);
        _observe();
        vm.warp(firstObsTs + 5);
        _pushMark(INITIAL_MARK + 1); // tiny change so the new push has a distinct timestamp
        _observe();
        assertEq(guardian.observationCount(SUBJECT_ID), 2);
        (uint192 lm, uint64 lts) = guardian.lastObservation(SUBJECT_ID);
        assertEq(uint256(lm), INITIAL_MARK + 1);
        assertEq(uint256(lts), firstObsTs + 5);
    }

    function test_Observe_DuplicateTimestampSkipsAppend() public {
        _observe();
        assertEq(guardian.observationCount(SUBJECT_ID), 1);
        // Don't push a new mark; advance time past the rate limit; observe again. The mark's
        // `updatedAt` is unchanged, so the guardian should skip without reverting.
        vm.warp(block.timestamp + 30);
        _observe();
        assertEq(guardian.observationCount(SUBJECT_ID), 1);
    }

    // ------------------------------------------------------------------------------------------
    // observe — no-trip cases
    // ------------------------------------------------------------------------------------------

    function test_Observe_NoBreaker_WhenStable() public {
        _observe();
        // Push 10 marks 30s apart, mark unchanged (0% move). Should never trip.
        // NOTE: `block.timestamp` is read aggressively by via_ir within a single Solidity function,
        // so we track time in a local `now_` cursor instead of relying on `block.timestamp + 30`
        // re-reading the warped value.
        uint256 now_ = block.timestamp;
        for (uint256 i = 0; i < 10; ++i) {
            now_ += 30;
            vm.warp(now_);
            _pushMark(INITIAL_MARK);
            _observe();
        }
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.ACTIVE));
    }

    function test_Observe_NoBreaker_BelowAllThresholds() public {
        _observe();
        // 4% move over 30s — below 5% auto threshold.
        vm.warp(block.timestamp + 25);
        _pushAndObserve(104 * ONE_18);
        assertEq(
            uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.ACTIVE)
        );
    }

    // ------------------------------------------------------------------------------------------
    // observe — AUTO_PAUSED (5% in 30s)
    // ------------------------------------------------------------------------------------------

    function test_Observe_TripsAutoPaused_OnFivePctMoveUp() public {
        _observe();
        // Move +5% in 20s.
        vm.warp(block.timestamp + 20);
        _pushAndObserve(105 * ONE_18);
        assertEq(
            uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.AUTO_PAUSED)
        );
    }

    function test_Observe_TripsAutoPaused_OnFivePctMoveDown() public {
        _observe();
        // Move −5% (95 from 100, abs(diff)/cur = 5/95 ≈ 526bps).
        vm.warp(block.timestamp + 20);
        _pushAndObserve(95 * ONE_18);
        assertEq(
            uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.AUTO_PAUSED)
        );
    }

    function test_Observe_DoesNotTripAutoPaused_BeyondWindow() public {
        // Seed an older observation, then advance past the 30s window before pushing the spike.
        _observe();
        vm.warp(block.timestamp + 120); // 2 min later — outside the 30s window
        _pushAndObserve(105 * ONE_18); // delta vs THIS push's history: only one new point so far
        assertEq(
            uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.ACTIVE)
        );
    }

    // ------------------------------------------------------------------------------------------
    // observe — COOLDOWN (10% in 30min)
    // ------------------------------------------------------------------------------------------

    function test_Observe_TripsCooldown_OnTenPctMoveInThirtyMinutes() public {
        _observe();
        // Walk a slow ramp to avoid the 5% AUTO trip on any single observation, but accumulate
        // 10% over a 30-min window. We push successive marks each 1-min apart with small steps.
        // 11 steps × 1.05× would compound past the per-step 5% cap; do 0.5% per minute (well
        // under 5%) for 20 minutes → +10% total, finishing at 110.
        uint256 cur = INITIAL_MARK;
        uint256 now_ = block.timestamp;
        for (uint256 i = 0; i < 20; ++i) {
            now_ += 60;
            vm.warp(now_);
            cur = (cur * 1_005) / 1_000; // +0.5% each minute
            _pushMark(cur);
            _observe();
        }
        // After 20 steps at +0.5% per minute (over 20 min, inside both the 30-min and 60-min
        // windows), the cumulative move is ~10.5% — should breach the 10% COOLDOWN threshold but
        // not the 20% FROZEN threshold.
        ISubjectRegistry.SubjectStatus status = registry.statusOf(SUBJECT_ID);
        assertEq(uint8(status), uint8(ISubjectRegistry.SubjectStatus.COOLDOWN));
    }

    // ------------------------------------------------------------------------------------------
    // observe — FROZEN (20% in 60min)
    // ------------------------------------------------------------------------------------------

    function test_Observe_TripsFrozen_OnTwentyPctMoveInSixtyMinutes() public {
        // Anchor an observation at the initial mark, jump 60 minutes forward, then push a single
        // −20% mark and observe. The 30s and 30min rolling windows see only the latest mark (no
        // recent movement on record); the 60-min window sees the original anchor and triggers
        // FROZEN. This sidesteps the issue that a slow ramp would trip COOLDOWN long before the
        // 60-min cumulative crosses 20%.
        _observe();
        uint64 t0 = uint64(block.timestamp);
        vm.warp(uint256(t0) + 60 minutes);
        _pushMark(80 * ONE_18); // -20%
        _observe();
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.FROZEN));
    }

    // ------------------------------------------------------------------------------------------
    // Multiple simultaneous breaches → worst tier wins
    // ------------------------------------------------------------------------------------------

    function test_Observe_WorstTierWins_FrozenBeatsCooldownAndAuto() public {
        // Construct a single observation that simultaneously breaches all three windows so the
        // worst-tier (FROZEN) wins. Anchor at t0 with mark=100, take a holding observation at
        // t0+29:30 (also mark=100), then crash to 75 (-25%) at t0+30m. At the final observe:
        //  - 30s window: covers the +29:30 holding obs at mark=100, diff 25% → AUTO breach.
        //  - 30m window: covers both prior obs at 100, diff 25% → COOLDOWN breach.
        //  - 60m window: covers both prior obs at 100, diff 25% → FROZEN breach.
        // All three breach; worst-tier-wins picks FROZEN.
        _observe();
        uint64 t0 = uint64(block.timestamp);
        vm.warp(uint256(t0) + 29 minutes + 30 seconds);
        _pushMark(INITIAL_MARK); // hold mark; markUpdatedAt advances
        _observe();
        vm.warp(uint256(t0) + 30 minutes);
        _pushMark(75 * ONE_18); // -25%
        _observe();
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.FROZEN));
    }

    function test_Observe_WorstTierWins_SinglePushOverAllThresholds() public {
        // Need to thread the needle on PerpEngine's 50% per-push delta cap. Push a single +25%
        // move which simultaneously breaches 5% (30s), 10% (30min), and 20% (60min) on the very
        // first observation.
        _observe();
        vm.warp(block.timestamp + 10);
        _pushMark(125 * ONE_18); // +25% in 10s
        // Expect FROZEN event before the call.
        vm.expectEmit(true, false, false, true, address(guardian));
        emit PauseGuardian.BreakerTriggered(SUBJECT_ID, 3, 2500, 2000);
        _observe();
        assertEq(
            uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.FROZEN)
        );
    }

    // ------------------------------------------------------------------------------------------
    // Idempotency
    // ------------------------------------------------------------------------------------------

    function test_Observe_Idempotent_NoOpWhenAlreadyAutoPaused() public {
        // Trip AUTO first.
        _observe();
        vm.warp(block.timestamp + 20);
        _pushAndObserve(105 * ONE_18);
        assertEq(
            uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.AUTO_PAUSED)
        );
        // Now push another spike; status should not change (we are not ACTIVE anymore).
        vm.warp(block.timestamp + 10);
        _pushAndObserve(120 * ONE_18); // would otherwise trip FROZEN
        assertEq(
            uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.AUTO_PAUSED)
        );
    }

    function test_Observe_Idempotent_NoOpWhenSubjectFrozen() public {
        // Trip FROZEN first.
        _observe();
        vm.warp(block.timestamp + 10);
        _pushAndObserve(125 * ONE_18);
        assertEq(
            uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.FROZEN)
        );
        // Another spike — no change.
        vm.warp(block.timestamp + 30);
        _pushAndObserve(150 * ONE_18);
        assertEq(
            uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.FROZEN)
        );
    }

    function test_Observe_Idempotent_NoOpWhenSubjectDelisted() public {
        vm.prank(regAdmin);
        registry.involuntaryDelist(SUBJECT_ID);
        assertEq(
            uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.DELISTED)
        );
        // observe still appends the observation (does not revert) but does NOT trip a breaker on
        // a non-ACTIVE subject.
        vm.warp(block.timestamp + 10);
        _pushAndObserve(125 * ONE_18);
        assertEq(
            uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.DELISTED)
        );
    }

    // ------------------------------------------------------------------------------------------
    // Ring buffer
    // ------------------------------------------------------------------------------------------

    function test_Observe_RingBufferSaturatesAtRingSize() public {
        // RING_SIZE is 128 in storage. Push more than that with a 30s gap each so we don't trip a
        // breaker; verify that the length saturates and the oldest entries get overwritten.
        _observe();
        uint256 now_ = block.timestamp;
        for (uint256 i = 0; i < 200; ++i) {
            now_ += 30;
            vm.warp(now_);
            _pushMark(INITIAL_MARK);
            _observe();
        }
        assertEq(guardian.observationCount(SUBJECT_ID), PauseGuardianStorage.RING_SIZE);
    }

    function test_Observe_ObservationAt_RevertsOutOfRange() public {
        _observe();
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.ObservationOutOfRange.selector, 1, 1));
        guardian.observationAt(SUBJECT_ID, 1);
    }

    function test_Observe_ObservationAt_ReturnsExpectedHistory() public {
        // via_ir may delay `block.timestamp` reads in the test body to a different program point
        // than the source order suggests. To pin the timestamps exactly, capture obs0's timestamp
        // through an external view (guardian.lastObservation) which forces a read at that moment.
        _observe();
        (, uint64 ts0Expected) = guardian.lastObservation(SUBJECT_ID);

        vm.warp(uint256(ts0Expected) + 10);
        _pushAndObserve(101 * ONE_18);
        (, uint64 ts1Expected) = guardian.lastObservation(SUBJECT_ID);

        vm.warp(uint256(ts1Expected) + 10);
        _pushAndObserve(102 * ONE_18);
        (, uint64 ts2Expected) = guardian.lastObservation(SUBJECT_ID);

        // 0 = newest, 1 = second-newest, …
        (uint192 m0, uint64 ts0) = guardian.observationAt(SUBJECT_ID, 0);
        (uint192 m1, uint64 ts1) = guardian.observationAt(SUBJECT_ID, 1);
        (uint192 m2, uint64 ts2) = guardian.observationAt(SUBJECT_ID, 2);
        assertEq(uint256(m0), 102 * ONE_18);
        assertEq(uint256(m1), 101 * ONE_18);
        assertEq(uint256(m2), INITIAL_MARK);
        assertEq(uint256(ts0), uint256(ts2Expected));
        assertEq(uint256(ts1), uint256(ts1Expected));
        assertEq(uint256(ts2), uint256(ts0Expected));
        // Sanity: timestamps are 10s apart.
        assertEq(uint256(ts1Expected), uint256(ts0Expected) + 10);
        assertEq(uint256(ts2Expected), uint256(ts1Expected) + 10);
    }

    function test_LastObservation_ReturnsZeroBeforeAnyObserve() public view {
        (uint192 m, uint64 ts) = guardian.lastObservation(SUBJECT_ID);
        assertEq(uint256(m), 0);
        assertEq(uint256(ts), 0);
    }

    // ------------------------------------------------------------------------------------------
    // Threshold timelock
    // ------------------------------------------------------------------------------------------

    function test_Thresholds_ProposeAndActivate() public {
        vm.prank(governance);
        guardian.proposeSetThresholds(600, 1_200, 2_500, 60, 45 minutes, 90 minutes);

        PauseGuardianStorage.PendingThresholds memory p = guardian.pendingThresholds();
        assertTrue(p.exists);
        assertEq(p.auto5MinBps, 600);
        assertEq(p.cooldown30MinBps, 1_200);
        assertEq(p.frozen60MinBps, 2_500);

        // Before timelock elapses.
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.TimelockNotElapsed.selector, p.activatesAt));
        guardian.activateSetThresholds();

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        guardian.activateSetThresholds();

        (uint16 a5, uint16 cd30, uint16 fz60) = guardian.thresholds();
        assertEq(a5, 600);
        assertEq(cd30, 1_200);
        assertEq(fz60, 2_500);
        (uint32 w5, uint32 w30, uint32 w60) = guardian.windows();
        assertEq(w5, 60);
        assertEq(w30, 45 minutes);
        assertEq(w60, 90 minutes);

        // Pending cleared.
        PauseGuardianStorage.PendingThresholds memory p2 = guardian.pendingThresholds();
        assertFalse(p2.exists);
    }

    function test_Thresholds_Propose_RevertsFromStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.Unauthorized.selector, stranger));
        guardian.proposeSetThresholds(600, 1_200, 2_500, 60, 45 minutes, 90 minutes);
    }

    function test_Thresholds_Propose_RevertsWhenPendingExists() public {
        vm.startPrank(governance);
        guardian.proposeSetThresholds(600, 1_200, 2_500, 60, 45 minutes, 90 minutes);
        vm.expectRevert(PauseGuardian.PendingThresholdsExist.selector);
        guardian.proposeSetThresholds(700, 1_300, 2_700, 60, 45 minutes, 90 minutes);
        vm.stopPrank();
    }

    function test_Thresholds_Propose_RevertsOnBpsBelowFloor() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.ThresholdOutOfRange.selector, uint16(5)));
        guardian.proposeSetThresholds(5, 1_200, 2_500, 60, 45 minutes, 90 minutes);
    }

    function test_Thresholds_Propose_RevertsOnBpsAboveCeiling() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.ThresholdOutOfRange.selector, uint16(6_000)));
        guardian.proposeSetThresholds(500, 1_200, 6_000, 60, 45 minutes, 90 minutes);
    }

    function test_Thresholds_Propose_RevertsWhenCooldownLeqAuto() public {
        vm.prank(governance);
        // cd30 == auto5 → revert
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.ThresholdOutOfRange.selector, uint16(500)));
        guardian.proposeSetThresholds(500, 500, 2_500, 60, 45 minutes, 90 minutes);
    }

    function test_Thresholds_Propose_RevertsWhenFrozenLeqCooldown() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.ThresholdOutOfRange.selector, uint16(1_000)));
        guardian.proposeSetThresholds(500, 1_000, 1_000, 60, 45 minutes, 90 minutes);
    }

    function test_Thresholds_Propose_RevertsOnWindowBelowFloor() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.WindowOutOfRange.selector, uint32(3)));
        guardian.proposeSetThresholds(500, 1_000, 2_000, 3, 45 minutes, 90 minutes);
    }

    function test_Thresholds_Propose_RevertsOnWindowAboveCeiling() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.WindowOutOfRange.selector, uint32(2 days)));
        guardian.proposeSetThresholds(500, 1_000, 2_000, 30, 45 minutes, 2 days);
    }

    function test_Thresholds_Propose_RevertsWhenCdWindowLeqAuto() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.WindowOutOfRange.selector, uint32(30)));
        guardian.proposeSetThresholds(500, 1_000, 2_000, 30, 30, 1 hours);
    }

    function test_Thresholds_Propose_RevertsWhenFzWindowLeqCd() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.WindowOutOfRange.selector, uint32(30 minutes)));
        guardian.proposeSetThresholds(500, 1_000, 2_000, 30, 30 minutes, 30 minutes);
    }

    function test_Thresholds_Activate_RevertsWhenNoPending() public {
        vm.expectRevert(PauseGuardian.NoPendingThresholds.selector);
        guardian.activateSetThresholds();
    }

    function test_Thresholds_Cancel_Succeeds() public {
        vm.startPrank(governance);
        guardian.proposeSetThresholds(600, 1_200, 2_500, 60, 45 minutes, 90 minutes);
        guardian.cancelSetThresholds();
        vm.stopPrank();
        PauseGuardianStorage.PendingThresholds memory p = guardian.pendingThresholds();
        assertFalse(p.exists);
    }

    function test_Thresholds_Cancel_RevertsWhenNoPending() public {
        vm.prank(governance);
        vm.expectRevert(PauseGuardian.NoPendingThresholds.selector);
        guardian.cancelSetThresholds();
    }

    function test_Thresholds_Cancel_RevertsFromStranger() public {
        vm.prank(governance);
        guardian.proposeSetThresholds(600, 1_200, 2_500, 60, 45 minutes, 90 minutes);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.Unauthorized.selector, stranger));
        guardian.cancelSetThresholds();
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer
    // ------------------------------------------------------------------------------------------

    function test_GovTransfer_ProposeActivate() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        guardian.proposeGovernanceTransfer(newGov);
        (address pending, uint64 readyAt) = guardian.pendingGovernance();
        assertEq(pending, newGov);
        assertEq(uint256(readyAt), block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.TimelockNotElapsed.selector, readyAt));
        guardian.activateGovernanceTransfer();

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        guardian.activateGovernanceTransfer();
        assertEq(guardian.governance(), newGov);
    }

    function test_GovTransfer_Propose_RevertsOnZero() public {
        vm.prank(governance);
        vm.expectRevert(PauseGuardian.InvalidConfig.selector);
        guardian.proposeGovernanceTransfer(address(0));
    }

    function test_GovTransfer_Propose_RevertsWhenAlreadyPending() public {
        vm.startPrank(governance);
        guardian.proposeGovernanceTransfer(makeAddr("g1"));
        vm.expectRevert(PauseGuardian.PendingGovernanceExists.selector);
        guardian.proposeGovernanceTransfer(makeAddr("g2"));
        vm.stopPrank();
    }

    function test_GovTransfer_Propose_RevertsFromStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.Unauthorized.selector, stranger));
        guardian.proposeGovernanceTransfer(makeAddr("g1"));
    }

    function test_GovTransfer_Activate_RevertsWhenNoPending() public {
        vm.expectRevert(PauseGuardian.NoPendingGovernance.selector);
        guardian.activateGovernanceTransfer();
    }

    function test_GovTransfer_Cancel_Succeeds() public {
        vm.startPrank(governance);
        guardian.proposeGovernanceTransfer(makeAddr("g1"));
        guardian.cancelGovernanceTransfer();
        vm.stopPrank();
        (address pending,) = guardian.pendingGovernance();
        assertEq(pending, address(0));
    }

    function test_GovTransfer_Cancel_RevertsWhenNoPending() public {
        vm.prank(governance);
        vm.expectRevert(PauseGuardian.NoPendingGovernance.selector);
        guardian.cancelGovernanceTransfer();
    }

    function test_GovTransfer_Cancel_RevertsFromStranger() public {
        vm.prank(governance);
        guardian.proposeGovernanceTransfer(makeAddr("g1"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.Unauthorized.selector, stranger));
        guardian.cancelGovernanceTransfer();
    }

    // ------------------------------------------------------------------------------------------
    // Upgrade authorization
    // ------------------------------------------------------------------------------------------

    function test_Upgrade_RevertsFromNonGovernance() public {
        PauseGuardian newImpl = new PauseGuardian();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PauseGuardian.Unauthorized.selector, stranger));
        guardian.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_SucceedsFromGovernance() public {
        PauseGuardian newImpl = new PauseGuardian();
        vm.prank(governance);
        guardian.upgradeToAndCall(address(newImpl), "");
        // Still works after upgrade.
        assertEq(guardian.governance(), governance);
    }
}
