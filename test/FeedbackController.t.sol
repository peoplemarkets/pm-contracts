// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {IMarginEngine} from "../src/core/IMarginEngine.sol";
import {IPerpEngine} from "../src/core/IPerpEngine.sol";
import {LPVault} from "../src/core/LPVault.sol";
import {MarginEngine} from "../src/core/MarginEngine.sol";
import {PerpEngine} from "../src/core/PerpEngine.sol";
import {FeedbackController} from "../src/feedback/FeedbackController.sol";
import {IFeedbackController} from "../src/feedback/IFeedbackController.sol";
import {IOracleRouter} from "../src/oracle/IOracleRouter.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {ISubjectRegistry} from "../src/registry/ISubjectRegistry.sol";
import {SubjectRegistry} from "../src/registry/SubjectRegistry.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev FeedbackController end-to-end test suite. Wires the full Tier-1 stack (USDC +
///      SubjectRegistry + LPVault + PerpEngine + OracleRouter + FeedbackController) and
///      exercises:
///        - initialize: parameters, zero-address gates, timelock bounds, default coefficients
///        - applyResolution: happy path for each EventClass, score sign behaviour, capping,
///          late-move discount, paused subject reverts, only-resolution-writer gate
///        - Resolution-writer rotation: timelocked add (propose/activate/cancel), immediate remove
///        - Setters: coefficient / impulseCapBps / lateMoveParams / perpEngine / oracleRouter
///        - Governance transfer timelocked
///        - Multi-resolution sequence: each impulse compounds correctly
contract FeedbackControllerTest is Test {
    // ------------------------------------------------------------------------------------------
    // System under test + dependencies
    // ------------------------------------------------------------------------------------------

    FeedbackController internal feedback;
    PerpEngine internal engine;
    MarginEngine internal marginEngine;
    LPVault internal vault;
    SubjectRegistry internal registry;
    OracleRouter internal router;
    MockUSDC internal usdc;

    // ------------------------------------------------------------------------------------------
    // Actors
    // ------------------------------------------------------------------------------------------

    address internal governance = makeAddr("governance");
    address internal vaultOperator = makeAddr("vaultOperator");
    address internal routerOperator = makeAddr("routerOperator");
    address internal regAdmin = makeAddr("regAdmin");
    address internal regGuardian = makeAddr("regGuardian");
    address internal kycWriter = makeAddr("kycWriter");
    address internal markWriter = makeAddr("markWriter");
    address internal resolutionWriter = makeAddr("resolutionWriter");
    address internal newResolutionWriter = makeAddr("newResolutionWriter");
    address internal stranger = makeAddr("stranger");
    address internal newGovernance = makeAddr("newGovernance");
    address internal alice = makeAddr("alice");

    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    bytes32 internal constant SUBJECT_ID = keccak256("drake");
    bytes32 internal constant SUBJECT_ID2 = keccak256("taylor");
    bytes32 internal constant SUBJECT_UNREGISTERED = keccak256("ghost");
    bytes32 internal constant CATEGORY_ID = keccak256("musician");

    uint32 internal constant TIMELOCK_DELAY = 2 days;
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant USDC_1M = 1_000_000 * ONE_USDC;
    uint256 internal constant USDC_10M = 10 * USDC_1M;
    uint256 internal constant ONE_18 = 1e18;
    uint256 internal constant INITIAL_MARK = 100 * ONE_18; // $100

    int256 internal constant DEFAULT_COEFF_BREAKUP_DIVORCE = -8e16;
    int256 internal constant DEFAULT_COEFF_ARREST = -2e17;
    int256 internal constant DEFAULT_COEFF_DEATH = -1e18;
    int256 internal constant DEFAULT_COEFF_ALBUM_RELEASE = 5e16;
    int256 internal constant DEFAULT_COEFF_TOUR_ANNOUNCEMENT = 4e16;
    int256 internal constant DEFAULT_COEFF_AWARD_WIN = 1e17;
    int256 internal constant DEFAULT_COEFF_SCANDAL = -15e16;
    int256 internal constant DEFAULT_COEFF_BRAND_DEAL = 6e16;
    int256 internal constant DEFAULT_COEFF_LEGAL_FILING = -7e16;

    uint16 internal constant DEFAULT_IMPULSE_CAP_BPS = 1_500;
    uint64 internal constant DEFAULT_LATE_MOVE_DENOMINATOR = 3600;
    uint64 internal constant DEFAULT_LATE_MOVE_SLOPE = 1;
    uint16 internal constant DEFAULT_MAX_DISCOUNT_BPS = 5_000;

    // ------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------

    function setUp() public {
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

        // 2. LPVault.
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

        // 3b. MarginEngine — Wave 4 extraction.
        {
            MarginEngine impl = new MarginEngine();
            bytes memory initData =
                abi.encodeCall(MarginEngine.initialize, (governance, address(engine), TIMELOCK_DELAY));
            marginEngine = MarginEngine(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 4. OracleRouter.
        {
            OracleRouter impl = new OracleRouter();
            bytes memory initData =
                abi.encodeCall(OracleRouter.initialize, (governance, routerOperator, TIMELOCK_DELAY));
            router = OracleRouter(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 5. Wire LPVault.perpEngine.
        vm.prank(governance);
        vault.proposeSetPerpEngine(address(engine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateSetPerpEngine();

        // 5b. Wire PerpEngine.marginEngine (timelocked).
        vm.prank(governance);
        engine.proposeSetMarginEngine(address(marginEngine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetMarginEngine();

        // 6. Configure SubjectRegistry: subjects + KYC.
        vm.startPrank(regAdmin);
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);
        registry.listSubject(SUBJECT_ID2, CATEGORY_ID);
        vm.stopPrank();
        vm.startPrank(kycWriter);
        registry.setKycTier(alice, 3);
        vm.stopPrank();

        // 7. KYC caps on MarginEngine; mark writer + delta cap on PerpEngine. Lift the per-push
        //    delta cap to its max (50%) for the suite — most tests push small impulses that
        //    compound; we sometimes also push live marks to set up scenarios.
        vm.prank(governance);
        marginEngine.setKycCaps(3, 1_000_000 * ONE_USDC, 4_000_000 * ONE_USDC);
        vm.startPrank(governance);
        engine.setMarkMaxDeltaBps(5_000);
        engine.proposeAddMarkWriter(markWriter);
        vm.stopPrank();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateAddMarkWriter(markWriter);

        // 8. Push initial marks.
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, INITIAL_MARK);
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID2, INITIAL_MARK);

        // 9. Seed the LP vault so OI caps + cappedTvl are non-zero.
        usdc.mint(alice, USDC_10M);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);
        engine.pokeCappedTvl();

        // 10. Deploy FeedbackController.
        {
            FeedbackController impl = new FeedbackController();
            bytes memory initData = abi.encodeCall(
                FeedbackController.initialize, (governance, address(engine), address(router), TIMELOCK_DELAY)
            );
            feedback = FeedbackController(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 11. Wire PerpEngine.feedbackController = feedback (timelocked).
        vm.prank(governance);
        engine.proposeSetFeedbackController(address(feedback));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetFeedbackController();

        // 12. Add the resolution writer (timelocked).
        vm.prank(governance);
        feedback.proposeAddResolutionWriter(resolutionWriter);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        feedback.activateAddResolutionWriter(resolutionWriter);
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _baseInput(
        IFeedbackController.EventClass eventClass,
        int256 score
    )
        internal
        view
        returns (IFeedbackController.ResolutionInput memory)
    {
        return IFeedbackController.ResolutionInput({
            subjectId: SUBJECT_ID,
            eventClass: eventClass,
            outcomeScore_e18: score,
            eventTimestamp: uint64(block.timestamp)
        });
    }

    /// @dev Expected mark after one resolution from `oldMark` with `impulseBps`.
    function _markAfterImpulse(uint256 oldMark, int256 impulseBps) internal pure returns (uint256) {
        int256 multiplier = int256(10_000) + impulseBps;
        return uint256((int256(oldMark) * multiplier) / int256(10_000));
    }

    // ------------------------------------------------------------------------------------------
    // initialize
    // ------------------------------------------------------------------------------------------

    function test_Initialize_StoresParams() public view {
        assertEq(feedback.governance(), governance);
        assertEq(feedback.perpEngine(), address(engine));
        assertEq(feedback.oracleRouter(), address(router));
        assertEq(feedback.timelockDelay(), TIMELOCK_DELAY);
        assertEq(uint256(feedback.impulseCapBps()), uint256(DEFAULT_IMPULSE_CAP_BPS));
        assertEq(uint256(feedback.lateMoveDenominator()), uint256(DEFAULT_LATE_MOVE_DENOMINATOR));
        assertEq(uint256(feedback.lateMoveSlope()), uint256(DEFAULT_LATE_MOVE_SLOPE));
        assertEq(uint256(feedback.maxDiscountBps()), uint256(DEFAULT_MAX_DISCOUNT_BPS));
    }

    function test_Initialize_PopulatesDefaultCoefficients() public view {
        assertEq(feedback.coefficientOf(IFeedbackController.EventClass.BREAKUP_DIVORCE), DEFAULT_COEFF_BREAKUP_DIVORCE);
        assertEq(feedback.coefficientOf(IFeedbackController.EventClass.ARREST), DEFAULT_COEFF_ARREST);
        assertEq(feedback.coefficientOf(IFeedbackController.EventClass.DEATH), DEFAULT_COEFF_DEATH);
        assertEq(feedback.coefficientOf(IFeedbackController.EventClass.ALBUM_RELEASE), DEFAULT_COEFF_ALBUM_RELEASE);
        assertEq(
            feedback.coefficientOf(IFeedbackController.EventClass.TOUR_ANNOUNCEMENT), DEFAULT_COEFF_TOUR_ANNOUNCEMENT
        );
        assertEq(feedback.coefficientOf(IFeedbackController.EventClass.AWARD_WIN), DEFAULT_COEFF_AWARD_WIN);
        assertEq(feedback.coefficientOf(IFeedbackController.EventClass.SCANDAL), DEFAULT_COEFF_SCANDAL);
        assertEq(feedback.coefficientOf(IFeedbackController.EventClass.BRAND_DEAL), DEFAULT_COEFF_BRAND_DEAL);
        assertEq(feedback.coefficientOf(IFeedbackController.EventClass.LEGAL_FILING), DEFAULT_COEFF_LEGAL_FILING);
        assertEq(feedback.coefficientOf(IFeedbackController.EventClass.UNSET), int256(0));
    }

    function test_Initialize_RevertOnZeroGovernance() public {
        FeedbackController impl = new FeedbackController();
        bytes memory initData = abi.encodeCall(
            FeedbackController.initialize, (address(0), address(engine), address(router), TIMELOCK_DELAY)
        );
        vm.expectRevert(IFeedbackController.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroPerpEngine() public {
        FeedbackController impl = new FeedbackController();
        bytes memory initData =
            abi.encodeCall(FeedbackController.initialize, (governance, address(0), address(router), TIMELOCK_DELAY));
        vm.expectRevert(IFeedbackController.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroOracleRouter() public {
        FeedbackController impl = new FeedbackController();
        bytes memory initData =
            abi.encodeCall(FeedbackController.initialize, (governance, address(engine), address(0), TIMELOCK_DELAY));
        vm.expectRevert(IFeedbackController.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooShort() public {
        FeedbackController impl = new FeedbackController();
        bytes memory initData = abi.encodeCall(
            FeedbackController.initialize, (governance, address(engine), address(router), uint32(1 minutes))
        );
        vm.expectRevert(IFeedbackController.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooLong() public {
        FeedbackController impl = new FeedbackController();
        bytes memory initData = abi.encodeCall(
            FeedbackController.initialize, (governance, address(engine), address(router), uint32(60 days))
        );
        vm.expectRevert(IFeedbackController.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_DoubleInitReverts() public {
        vm.expectRevert();
        feedback.initialize(governance, address(engine), address(router), TIMELOCK_DELAY);
    }

    // ------------------------------------------------------------------------------------------
    // applyResolution — happy path per EventClass
    // ------------------------------------------------------------------------------------------

    function test_ApplyResolution_PositiveAlbumRelease() public {
        // coeff = 0.05e18, score = 1e18 → raw = 0.05 × 1 × 10000 = 500 bps = 5%
        IFeedbackController.ResolutionInput memory input =
            _baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, 1e18);
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        // Expected: 100 * (1 + 0.05) = 105
        assertEq(newMark, 105 * ONE_18);
    }

    function test_ApplyResolution_NegativeArrest() public {
        // coeff = -0.20e18, score = 1e18 → raw = -2000 bps = -20%, CAPPED at -1500 bps = -15%
        IFeedbackController.ResolutionInput memory input = _baseInput(IFeedbackController.EventClass.ARREST, 1e18);
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        // Expected: 100 * (1 - 0.15) = 85 (cap binds)
        assertEq(newMark, 85 * ONE_18);
    }

    function test_ApplyResolution_NegativeScoreInverts() public {
        // ALBUM_RELEASE coeff is positive (+0.05). With negative score the impulse goes negative.
        IFeedbackController.ResolutionInput memory input =
            _baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, -1e18);
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        // Expected: 100 * (1 - 0.05) = 95
        assertEq(newMark, 95 * ONE_18);
    }

    function test_ApplyResolution_BreakupDivorce_Positive() public {
        // BREAKUP_DIVORCE coeff = -0.08. Score +1e18 → impulse = -800 bps = -8%
        IFeedbackController.ResolutionInput memory input =
            _baseInput(IFeedbackController.EventClass.BREAKUP_DIVORCE, 1e18);
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        assertEq(newMark, 92 * ONE_18);
    }

    function test_ApplyResolution_Death() public {
        // DEATH coeff = -1.0. Score 1e18 → -10000 bps → CAPPED to -1500 bps = -15%
        IFeedbackController.ResolutionInput memory input = _baseInput(IFeedbackController.EventClass.DEATH, 1e18);
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        assertEq(newMark, 85 * ONE_18);
    }

    function test_ApplyResolution_TourAnnouncement() public {
        // TOUR_ANNOUNCEMENT coeff = +0.04. Score = 0.5e18 → raw = 0.04 × 0.5 × 10000 = 200 bps = 2%
        IFeedbackController.ResolutionInput memory input =
            _baseInput(IFeedbackController.EventClass.TOUR_ANNOUNCEMENT, 5e17);
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        assertEq(newMark, 102 * ONE_18);
    }

    function test_ApplyResolution_AwardWin() public {
        // AWARD_WIN coeff = +0.10. Score = 1e18 → raw = 1000 bps = 10%
        IFeedbackController.ResolutionInput memory input = _baseInput(IFeedbackController.EventClass.AWARD_WIN, 1e18);
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        assertEq(newMark, 110 * ONE_18);
    }

    function test_ApplyResolution_Scandal() public {
        // SCANDAL coeff = -0.15. Score = 1e18 → raw = -1500 bps exactly = -15% (at cap)
        IFeedbackController.ResolutionInput memory input = _baseInput(IFeedbackController.EventClass.SCANDAL, 1e18);
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        assertEq(newMark, 85 * ONE_18);
    }

    function test_ApplyResolution_BrandDeal() public {
        // BRAND_DEAL coeff = +0.06. Score = 1e18 → raw = 600 bps = 6%
        IFeedbackController.ResolutionInput memory input = _baseInput(IFeedbackController.EventClass.BRAND_DEAL, 1e18);
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        assertEq(newMark, 106 * ONE_18);
    }

    function test_ApplyResolution_LegalFiling() public {
        // LEGAL_FILING coeff = -0.07. Score = 1e18 → -700 bps = -7%
        IFeedbackController.ResolutionInput memory input = _baseInput(IFeedbackController.EventClass.LEGAL_FILING, 1e18);
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        assertEq(newMark, 93 * ONE_18);
    }

    function test_ApplyResolution_EmitsExpectedEvent() public {
        // ALBUM_RELEASE coeff = +0.05, score = 1e18 → raw = cap = 500 bps; lateBy=0 → final=500.
        IFeedbackController.ResolutionInput memory input =
            _baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, 1e18);
        vm.expectEmit(true, true, false, true, address(feedback));
        emit IFeedbackController.ResolutionApplied(
            SUBJECT_ID,
            IFeedbackController.EventClass.ALBUM_RELEASE,
            int256(1e18),
            uint64(block.timestamp),
            uint64(0),
            int256(500),
            int256(500),
            int256(500),
            resolutionWriter
        );
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
    }

    // ------------------------------------------------------------------------------------------
    // applyResolution — validation
    // ------------------------------------------------------------------------------------------

    function test_ApplyResolution_RevertOnUnsetEventClass() public {
        IFeedbackController.ResolutionInput memory input = IFeedbackController.ResolutionInput({
            subjectId: SUBJECT_ID,
            eventClass: IFeedbackController.EventClass.UNSET,
            outcomeScore_e18: 1e18,
            eventTimestamp: uint64(block.timestamp)
        });
        vm.prank(resolutionWriter);
        vm.expectRevert(IFeedbackController.InvalidEventClass.selector);
        feedback.applyResolution(input);
    }

    function test_ApplyResolution_RevertOnScoreTooNegative() public {
        IFeedbackController.ResolutionInput memory input =
            _baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, -int256(1e18) - 1);
        vm.prank(resolutionWriter);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.InvalidOutcomeScore.selector, int256(-1e18 - 1)));
        feedback.applyResolution(input);
    }

    function test_ApplyResolution_RevertOnScoreTooPositive() public {
        IFeedbackController.ResolutionInput memory input =
            _baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, int256(1e18) + 1);
        vm.prank(resolutionWriter);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.InvalidOutcomeScore.selector, int256(1e18 + 1)));
        feedback.applyResolution(input);
    }

    function test_ApplyResolution_AcceptsBoundaryScores() public {
        // Exactly +1e18.
        IFeedbackController.ResolutionInput memory inputPos =
            _baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, int256(1e18));
        vm.prank(resolutionWriter);
        feedback.applyResolution(inputPos);
        // Exactly -1e18 (now subject 2 to avoid compounding).
        IFeedbackController.ResolutionInput memory inputNeg = IFeedbackController.ResolutionInput({
            subjectId: SUBJECT_ID2,
            eventClass: IFeedbackController.EventClass.ALBUM_RELEASE,
            outcomeScore_e18: -int256(1e18),
            eventTimestamp: uint64(block.timestamp)
        });
        vm.prank(resolutionWriter);
        feedback.applyResolution(inputNeg);
    }

    function test_ApplyResolution_RevertOnPausedSubject() public {
        // PauseGuardian sets AUTO_PAUSED (= 2). requireTradeable reverts with
        // InvalidStatusTransition(AUTO_PAUSED, ACTIVE) = (2, 1).
        vm.prank(regGuardian);
        registry.setAutoPaused(SUBJECT_ID, 0);
        IFeedbackController.ResolutionInput memory input =
            _baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, 1e18);
        vm.prank(resolutionWriter);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.AUTO_PAUSED,
                ISubjectRegistry.SubjectStatus.ACTIVE
            )
        );
        feedback.applyResolution(input);
    }

    function test_ApplyResolution_RevertOnDelistedSubject() public {
        // Move the subject to DELISTED via involuntary delist.
        vm.prank(regAdmin);
        registry.involuntaryDelist(SUBJECT_ID);
        IFeedbackController.ResolutionInput memory input =
            _baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, 1e18);
        vm.prank(resolutionWriter);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.DELISTED,
                ISubjectRegistry.SubjectStatus.ACTIVE
            )
        );
        feedback.applyResolution(input);
    }

    function test_ApplyResolution_RevertOnNonWriter() public {
        IFeedbackController.ResolutionInput memory input =
            _baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, 1e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.OnlyResolutionWriter.selector, stranger));
        feedback.applyResolution(input);
    }

    function test_ApplyResolution_RevertOnUninitializedMark() public {
        // The fix: ensure mark on SUBJECT_ID is uninitialized (use a never-pushed subject). We
        // need it tradeable but with no mark — list a fresh subject.
        bytes32 fresh = keccak256("fresh");
        vm.prank(regAdmin);
        registry.listSubject(fresh, CATEGORY_ID);
        IFeedbackController.ResolutionInput memory input = IFeedbackController.ResolutionInput({
            subjectId: fresh,
            eventClass: IFeedbackController.EventClass.ALBUM_RELEASE,
            outcomeScore_e18: 1e18,
            eventTimestamp: uint64(block.timestamp)
        });
        vm.prank(resolutionWriter);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.MarkNotInitialized.selector, fresh));
        feedback.applyResolution(input);
    }

    // ------------------------------------------------------------------------------------------
    // applyResolution — capping
    // ------------------------------------------------------------------------------------------

    function test_ApplyResolution_CapsPositiveImpulse() public {
        // Crank the coefficient up to +1e18 (max). Score = 1e18 → raw = 10000 bps → cap = 1500.
        vm.prank(governance);
        feedback.setCoefficient(IFeedbackController.EventClass.AWARD_WIN, int256(1e18));
        IFeedbackController.ResolutionInput memory input = _baseInput(IFeedbackController.EventClass.AWARD_WIN, 1e18);
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        assertEq(newMark, 115 * ONE_18); // 100 × 1.15
    }

    function test_ApplyResolution_CapsNegativeImpulse() public {
        // Coefficient at -1e18, score = +1e18 → raw = -10000 bps → cap = -1500.
        vm.prank(governance);
        feedback.setCoefficient(IFeedbackController.EventClass.SCANDAL, -int256(1e18));
        IFeedbackController.ResolutionInput memory input = _baseInput(IFeedbackController.EventClass.SCANDAL, 1e18);
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        assertEq(newMark, 85 * ONE_18);
    }

    // ------------------------------------------------------------------------------------------
    // Late-move discount
    // ------------------------------------------------------------------------------------------

    function test_ApplyResolution_LateBy0_NoDiscount() public {
        IFeedbackController.ResolutionInput memory input =
            _baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, 1e18);
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        // raw 500 bps, no discount → +5%
        assertEq(newMark, 105 * ONE_18);
    }

    function test_ApplyResolution_LateByHalfDenom_HalfDiscount() public {
        // lateBy = 1800s (half the 3600s denominator) → discountBps = 1800 × 1 × 10000 / 3600 = 5000
        // 5000 > maxDiscountBps (5000) → clamped to 5000. final = raw × 5000/10000 = raw/2.
        // raw = +500 bps → final = +250 bps.
        uint64 eventTs = uint64(block.timestamp - 1800);
        IFeedbackController.ResolutionInput memory input = IFeedbackController.ResolutionInput({
            subjectId: SUBJECT_ID,
            eventClass: IFeedbackController.EventClass.ALBUM_RELEASE,
            outcomeScore_e18: 1e18,
            eventTimestamp: eventTs
        });
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        // final = +250 bps → mark × 1.025 = 102.5
        assertEq(newMark, 1025e17);
    }

    function test_ApplyResolution_LateByQuarterDenom_QuarterDiscount() public {
        // lateBy = 900s, 900 × 10000 / 3600 = 2500 bps discount (below 5000 cap).
        // final = raw × 7500/10000 = raw × 0.75.
        // raw = +500 bps → final = +375 bps.
        uint64 eventTs = uint64(block.timestamp - 900);
        IFeedbackController.ResolutionInput memory input = IFeedbackController.ResolutionInput({
            subjectId: SUBJECT_ID,
            eventClass: IFeedbackController.EventClass.ALBUM_RELEASE,
            outcomeScore_e18: 1e18,
            eventTimestamp: eventTs
        });
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        // final = +375 bps → 100 × 1.0375 = 103.75
        assertEq(newMark, 10375e16);
    }

    function test_ApplyResolution_LateBy_ClampsAtMaxDiscount() public {
        // lateBy = 10 hours → raw discount = 10×3600 × 10000 / 3600 = 100000, clamped to 5000.
        // final = raw × 0.5.
        uint64 eventTs = uint64(block.timestamp - 36_000); // 10h ago

        IFeedbackController.ResolutionInput memory input = IFeedbackController.ResolutionInput({
            subjectId: SUBJECT_ID,
            eventClass: IFeedbackController.EventClass.ALBUM_RELEASE,
            outcomeScore_e18: 1e18,
            eventTimestamp: eventTs
        });
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        // raw = 500 bps, discount clamps to 5000 → final = 250 bps → mark × 1.025
        assertEq(newMark, 1025e17);
    }

    function test_ApplyResolution_LateMove_DiscountZeroMaxAllowsNoDiscount() public {
        // If maxDiscountBps = 0, no late-move discount is ever applied.
        vm.prank(governance);
        feedback.setLateMoveParams(DEFAULT_LATE_MOVE_DENOMINATOR, DEFAULT_LATE_MOVE_SLOPE, 0);
        uint64 eventTs = uint64(block.timestamp - 1800);
        IFeedbackController.ResolutionInput memory input = IFeedbackController.ResolutionInput({
            subjectId: SUBJECT_ID,
            eventClass: IFeedbackController.EventClass.ALBUM_RELEASE,
            outcomeScore_e18: 1e18,
            eventTimestamp: eventTs
        });
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        // Even though lateBy=1800, maxDiscount=0 ⇒ full 500 bps applies.
        assertEq(newMark, 105 * ONE_18);
    }

    function test_ApplyResolution_EventTimestampInFuture_NoDiscount() public {
        // If eventTimestamp > block.timestamp, lateBy = 0 → no discount.
        IFeedbackController.ResolutionInput memory input = IFeedbackController.ResolutionInput({
            subjectId: SUBJECT_ID,
            eventClass: IFeedbackController.EventClass.ALBUM_RELEASE,
            outcomeScore_e18: 1e18,
            eventTimestamp: uint64(block.timestamp + 1 hours)
        });
        vm.prank(resolutionWriter);
        feedback.applyResolution(input);
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        assertEq(newMark, 105 * ONE_18);
    }

    // ------------------------------------------------------------------------------------------
    // Resolution-writer rotation
    // ------------------------------------------------------------------------------------------

    function test_ProposeAddResolutionWriter_HappyPath() public {
        vm.expectEmit(true, false, false, true, address(feedback));
        emit IFeedbackController.ResolutionWriterProposed(newResolutionWriter, uint64(block.timestamp + TIMELOCK_DELAY));
        vm.prank(governance);
        feedback.proposeAddResolutionWriter(newResolutionWriter);
        assertEq(
            uint256(feedback.pendingResolutionWriterActivatesAt(newResolutionWriter)), block.timestamp + TIMELOCK_DELAY
        );
    }

    function test_ProposeAddResolutionWriter_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.InvalidConfig.selector);
        feedback.proposeAddResolutionWriter(address(0));
    }

    function test_ProposeAddResolutionWriter_RevertOnAlreadyWriter() public {
        // resolutionWriter is already active.
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.InvalidConfig.selector);
        feedback.proposeAddResolutionWriter(resolutionWriter);
    }

    function test_ProposeAddResolutionWriter_RevertOnPending() public {
        vm.prank(governance);
        feedback.proposeAddResolutionWriter(newResolutionWriter);
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.PendingResolutionWriterExists.selector);
        feedback.proposeAddResolutionWriter(newResolutionWriter);
    }

    function test_ProposeAddResolutionWriter_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.Unauthorized.selector, stranger));
        feedback.proposeAddResolutionWriter(newResolutionWriter);
    }

    function test_ActivateAddResolutionWriter_HappyPath() public {
        vm.prank(governance);
        feedback.proposeAddResolutionWriter(newResolutionWriter);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, false, false, false, address(feedback));
        emit IFeedbackController.ResolutionWriterActivated(newResolutionWriter);
        feedback.activateAddResolutionWriter(newResolutionWriter);
        assertTrue(feedback.isResolutionWriter(newResolutionWriter));
    }

    function test_ActivateAddResolutionWriter_RevertOnNoPending() public {
        vm.expectRevert(IFeedbackController.NoPendingResolutionWriter.selector);
        feedback.activateAddResolutionWriter(newResolutionWriter);
    }

    function test_ActivateAddResolutionWriter_RevertOnTimelockNotElapsed() public {
        vm.prank(governance);
        feedback.proposeAddResolutionWriter(newResolutionWriter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFeedbackController.TimelockNotElapsed.selector, uint64(block.timestamp + TIMELOCK_DELAY)
            )
        );
        feedback.activateAddResolutionWriter(newResolutionWriter);
    }

    function test_CancelAddResolutionWriter_HappyPath() public {
        vm.prank(governance);
        feedback.proposeAddResolutionWriter(newResolutionWriter);
        vm.expectEmit(true, false, false, false, address(feedback));
        emit IFeedbackController.ResolutionWriterCancelled(newResolutionWriter);
        vm.prank(governance);
        feedback.cancelAddResolutionWriter(newResolutionWriter);
        assertEq(uint256(feedback.pendingResolutionWriterActivatesAt(newResolutionWriter)), 0);
    }

    function test_CancelAddResolutionWriter_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.NoPendingResolutionWriter.selector);
        feedback.cancelAddResolutionWriter(newResolutionWriter);
    }

    function test_RemoveResolutionWriter_HappyPath() public {
        vm.expectEmit(true, false, false, false, address(feedback));
        emit IFeedbackController.ResolutionWriterRemoved(resolutionWriter);
        vm.prank(governance);
        feedback.removeResolutionWriter(resolutionWriter);
        assertFalse(feedback.isResolutionWriter(resolutionWriter));
    }

    function test_RemoveResolutionWriter_RevertOnNotSet() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.ResolutionWriterNotSet.selector, stranger));
        feedback.removeResolutionWriter(stranger);
    }

    function test_RemoveResolutionWriter_BlocksFutureCalls() public {
        vm.prank(governance);
        feedback.removeResolutionWriter(resolutionWriter);
        IFeedbackController.ResolutionInput memory input =
            _baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, 1e18);
        vm.prank(resolutionWriter);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.OnlyResolutionWriter.selector, resolutionWriter));
        feedback.applyResolution(input);
    }

    // ------------------------------------------------------------------------------------------
    // setCoefficient
    // ------------------------------------------------------------------------------------------

    function test_SetCoefficient_HappyPath() public {
        int256 newCoeff = int256(2e17); // +0.20
        vm.expectEmit(true, false, false, true, address(feedback));
        emit IFeedbackController.CoefficientSet(
            IFeedbackController.EventClass.AWARD_WIN, DEFAULT_COEFF_AWARD_WIN, newCoeff
        );
        vm.prank(governance);
        feedback.setCoefficient(IFeedbackController.EventClass.AWARD_WIN, newCoeff);
        assertEq(feedback.coefficientOf(IFeedbackController.EventClass.AWARD_WIN), newCoeff);
    }

    function test_SetCoefficient_RevertOnUnset() public {
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.InvalidEventClass.selector);
        feedback.setCoefficient(IFeedbackController.EventClass.UNSET, int256(1e17));
    }

    function test_SetCoefficient_RevertOnTooNegative() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.CoefficientOutOfRange.selector, int256(-1e18 - 1)));
        feedback.setCoefficient(IFeedbackController.EventClass.AWARD_WIN, -int256(1e18) - 1);
    }

    function test_SetCoefficient_RevertOnTooPositive() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.CoefficientOutOfRange.selector, int256(1e18 + 1)));
        feedback.setCoefficient(IFeedbackController.EventClass.AWARD_WIN, int256(1e18) + 1);
    }

    function test_SetCoefficient_AcceptsBoundaries() public {
        vm.startPrank(governance);
        feedback.setCoefficient(IFeedbackController.EventClass.AWARD_WIN, int256(1e18));
        assertEq(feedback.coefficientOf(IFeedbackController.EventClass.AWARD_WIN), int256(1e18));
        feedback.setCoefficient(IFeedbackController.EventClass.AWARD_WIN, -int256(1e18));
        assertEq(feedback.coefficientOf(IFeedbackController.EventClass.AWARD_WIN), -int256(1e18));
        vm.stopPrank();
    }

    function test_SetCoefficient_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.Unauthorized.selector, stranger));
        feedback.setCoefficient(IFeedbackController.EventClass.AWARD_WIN, int256(1e17));
    }

    // ------------------------------------------------------------------------------------------
    // setImpulseCapBps
    // ------------------------------------------------------------------------------------------

    function test_SetImpulseCapBps_HappyPath() public {
        vm.expectEmit(false, false, false, true, address(feedback));
        emit IFeedbackController.ImpulseCapBpsSet(DEFAULT_IMPULSE_CAP_BPS, 3000);
        vm.prank(governance);
        feedback.setImpulseCapBps(3000);
        assertEq(uint256(feedback.impulseCapBps()), 3000);
    }

    function test_SetImpulseCapBps_RevertOnTooLow() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.ImpulseCapOutOfRange.selector, uint16(99)));
        feedback.setImpulseCapBps(99);
    }

    function test_SetImpulseCapBps_RevertOnTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.ImpulseCapOutOfRange.selector, uint16(5001)));
        feedback.setImpulseCapBps(5001);
    }

    function test_SetImpulseCapBps_AcceptsBoundaries() public {
        vm.startPrank(governance);
        feedback.setImpulseCapBps(100);
        assertEq(uint256(feedback.impulseCapBps()), 100);
        feedback.setImpulseCapBps(5000);
        assertEq(uint256(feedback.impulseCapBps()), 5000);
        vm.stopPrank();
    }

    function test_SetImpulseCapBps_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.Unauthorized.selector, stranger));
        feedback.setImpulseCapBps(2000);
    }

    // ------------------------------------------------------------------------------------------
    // setLateMoveParams
    // ------------------------------------------------------------------------------------------

    function test_SetLateMoveParams_HappyPath() public {
        vm.expectEmit(false, false, false, true, address(feedback));
        emit IFeedbackController.LateMoveParamsSet(uint64(7200), uint64(2), uint16(2500));
        vm.prank(governance);
        feedback.setLateMoveParams(7200, 2, 2500);
        assertEq(uint256(feedback.lateMoveDenominator()), 7200);
        assertEq(uint256(feedback.lateMoveSlope()), 2);
        assertEq(uint256(feedback.maxDiscountBps()), 2500);
    }

    function test_SetLateMoveParams_RevertOnDenominatorTooLow() public {
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.LateMoveParamsOutOfRange.selector);
        feedback.setLateMoveParams(59, 1, 5000);
    }

    function test_SetLateMoveParams_RevertOnDenominatorTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.LateMoveParamsOutOfRange.selector);
        feedback.setLateMoveParams(86_401, 1, 5000);
    }

    function test_SetLateMoveParams_RevertOnSlopeZero() public {
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.LateMoveParamsOutOfRange.selector);
        feedback.setLateMoveParams(3600, 0, 5000);
    }

    function test_SetLateMoveParams_RevertOnSlopeTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.LateMoveParamsOutOfRange.selector);
        feedback.setLateMoveParams(3600, 101, 5000);
    }

    function test_SetLateMoveParams_RevertOnMaxDiscountTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.LateMoveParamsOutOfRange.selector);
        feedback.setLateMoveParams(3600, 1, 10_001);
    }

    function test_SetLateMoveParams_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.Unauthorized.selector, stranger));
        feedback.setLateMoveParams(3600, 1, 5000);
    }

    // ------------------------------------------------------------------------------------------
    // proposeSetPerpEngine / activateSetPerpEngine / cancelSetPerpEngine — Wave 7 audit Fix #4
    // ------------------------------------------------------------------------------------------

    function test_ProposeSetPerpEngine_HappyPath() public {
        address newEngine = makeAddr("newEngine");
        uint64 expectedAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, false, false, true, address(feedback));
        emit IFeedbackController.PerpEngineProposed(newEngine, expectedAt);
        vm.prank(governance);
        feedback.proposeSetPerpEngine(newEngine);
        (address pending, uint64 readyAt) = feedback.pendingPerpEngine();
        assertEq(pending, newEngine);
        assertEq(readyAt, expectedAt);
        // perpEngine is unchanged until activate.
        assertEq(feedback.perpEngine(), address(engine));
    }

    function test_ProposeSetPerpEngine_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.InvalidConfig.selector);
        feedback.proposeSetPerpEngine(address(0));
    }

    function test_ProposeSetPerpEngine_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.Unauthorized.selector, stranger));
        feedback.proposeSetPerpEngine(makeAddr("foo"));
    }

    function test_ProposeSetPerpEngine_RevertOnPendingExists() public {
        vm.prank(governance);
        feedback.proposeSetPerpEngine(makeAddr("foo"));
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.PendingPerpEngineExists.selector);
        feedback.proposeSetPerpEngine(makeAddr("bar"));
    }

    function test_ActivateSetPerpEngine_HappyPath() public {
        address newEngine = makeAddr("newEngine");
        vm.prank(governance);
        feedback.proposeSetPerpEngine(newEngine);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        address oldEngine = feedback.perpEngine();
        vm.expectEmit(true, true, false, true, address(feedback));
        emit IFeedbackController.PerpEngineActivated(oldEngine, newEngine);
        feedback.activateSetPerpEngine();
        assertEq(feedback.perpEngine(), newEngine);
        (address pending, uint64 readyAt) = feedback.pendingPerpEngine();
        assertEq(pending, address(0));
        assertEq(readyAt, 0);
    }

    function test_ActivateSetPerpEngine_RevertBeforeTimelock() public {
        vm.prank(governance);
        feedback.proposeSetPerpEngine(makeAddr("foo"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IFeedbackController.TimelockNotElapsed.selector, uint64(block.timestamp + TIMELOCK_DELAY)
            )
        );
        feedback.activateSetPerpEngine();
    }

    function test_ActivateSetPerpEngine_RevertWhenNoPending() public {
        vm.expectRevert(IFeedbackController.NoPendingPerpEngine.selector);
        feedback.activateSetPerpEngine();
    }

    function test_CancelSetPerpEngine_HappyPath() public {
        address newEngine = makeAddr("newEngine");
        vm.prank(governance);
        feedback.proposeSetPerpEngine(newEngine);
        vm.expectEmit(true, false, false, true, address(feedback));
        emit IFeedbackController.PerpEngineCancelled(newEngine);
        vm.prank(governance);
        feedback.cancelSetPerpEngine();
        (address pending, uint64 readyAt) = feedback.pendingPerpEngine();
        assertEq(pending, address(0));
        assertEq(readyAt, 0);
    }

    function test_CancelSetPerpEngine_RevertOnNonGovernance() public {
        vm.prank(governance);
        feedback.proposeSetPerpEngine(makeAddr("foo"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.Unauthorized.selector, stranger));
        feedback.cancelSetPerpEngine();
    }

    function test_CancelSetPerpEngine_RevertWhenNoPending() public {
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.NoPendingPerpEngine.selector);
        feedback.cancelSetPerpEngine();
    }

    // ------------------------------------------------------------------------------------------
    // proposeSetOracleRouter / activateSetOracleRouter / cancelSetOracleRouter
    // ------------------------------------------------------------------------------------------

    function test_ProposeSetOracleRouter_HappyPath() public {
        address newRouter = makeAddr("newRouter");
        uint64 expectedAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, false, false, true, address(feedback));
        emit IFeedbackController.OracleRouterProposed(newRouter, expectedAt);
        vm.prank(governance);
        feedback.proposeSetOracleRouter(newRouter);
        (address pending, uint64 readyAt) = feedback.pendingOracleRouter();
        assertEq(pending, newRouter);
        assertEq(readyAt, expectedAt);
        assertEq(feedback.oracleRouter(), address(router));
    }

    function test_ProposeSetOracleRouter_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.InvalidConfig.selector);
        feedback.proposeSetOracleRouter(address(0));
    }

    function test_ProposeSetOracleRouter_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.Unauthorized.selector, stranger));
        feedback.proposeSetOracleRouter(makeAddr("foo"));
    }

    function test_ProposeSetOracleRouter_RevertOnPendingExists() public {
        vm.prank(governance);
        feedback.proposeSetOracleRouter(makeAddr("foo"));
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.PendingOracleRouterExists.selector);
        feedback.proposeSetOracleRouter(makeAddr("bar"));
    }

    function test_ActivateSetOracleRouter_HappyPath() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(governance);
        feedback.proposeSetOracleRouter(newRouter);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        address oldRouter = feedback.oracleRouter();
        vm.expectEmit(true, true, false, true, address(feedback));
        emit IFeedbackController.OracleRouterActivated(oldRouter, newRouter);
        feedback.activateSetOracleRouter();
        assertEq(feedback.oracleRouter(), newRouter);
    }

    function test_ActivateSetOracleRouter_RevertBeforeTimelock() public {
        vm.prank(governance);
        feedback.proposeSetOracleRouter(makeAddr("foo"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IFeedbackController.TimelockNotElapsed.selector, uint64(block.timestamp + TIMELOCK_DELAY)
            )
        );
        feedback.activateSetOracleRouter();
    }

    function test_ActivateSetOracleRouter_RevertWhenNoPending() public {
        vm.expectRevert(IFeedbackController.NoPendingOracleRouter.selector);
        feedback.activateSetOracleRouter();
    }

    function test_CancelSetOracleRouter_HappyPath() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(governance);
        feedback.proposeSetOracleRouter(newRouter);
        vm.expectEmit(true, false, false, true, address(feedback));
        emit IFeedbackController.OracleRouterCancelled(newRouter);
        vm.prank(governance);
        feedback.cancelSetOracleRouter();
        (address pending, uint64 readyAt) = feedback.pendingOracleRouter();
        assertEq(pending, address(0));
        assertEq(readyAt, 0);
    }

    function test_CancelSetOracleRouter_RevertOnNonGovernance() public {
        vm.prank(governance);
        feedback.proposeSetOracleRouter(makeAddr("foo"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.Unauthorized.selector, stranger));
        feedback.cancelSetOracleRouter();
    }

    function test_CancelSetOracleRouter_RevertWhenNoPending() public {
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.NoPendingOracleRouter.selector);
        feedback.cancelSetOracleRouter();
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer
    // ------------------------------------------------------------------------------------------

    function test_ProposeGovernanceTransfer_HappyPath() public {
        vm.expectEmit(true, false, false, true, address(feedback));
        emit IFeedbackController.GovernanceTransferProposed(newGovernance, uint64(block.timestamp + TIMELOCK_DELAY));
        vm.prank(governance);
        feedback.proposeGovernanceTransfer(newGovernance);
        (address pending, uint64 readyAt) = feedback.pendingGovernance();
        assertEq(pending, newGovernance);
        assertEq(uint256(readyAt), block.timestamp + TIMELOCK_DELAY);
    }

    function test_ProposeGovernanceTransfer_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.InvalidConfig.selector);
        feedback.proposeGovernanceTransfer(address(0));
    }

    function test_ProposeGovernanceTransfer_RevertOnExisting() public {
        vm.prank(governance);
        feedback.proposeGovernanceTransfer(newGovernance);
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.PendingGovernanceTransferExists.selector);
        feedback.proposeGovernanceTransfer(newGovernance);
    }

    function test_ActivateGovernanceTransfer_HappyPath() public {
        vm.prank(governance);
        feedback.proposeGovernanceTransfer(newGovernance);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, true, false, false, address(feedback));
        emit IFeedbackController.GovernanceTransferActivated(governance, newGovernance);
        feedback.activateGovernanceTransfer();
        assertEq(feedback.governance(), newGovernance);
    }

    function test_ActivateGovernanceTransfer_RevertOnNoPending() public {
        vm.expectRevert(IFeedbackController.NoPendingGovernanceTransfer.selector);
        feedback.activateGovernanceTransfer();
    }

    function test_ActivateGovernanceTransfer_RevertOnTimelockNotElapsed() public {
        vm.prank(governance);
        feedback.proposeGovernanceTransfer(newGovernance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFeedbackController.TimelockNotElapsed.selector, uint64(block.timestamp + TIMELOCK_DELAY)
            )
        );
        feedback.activateGovernanceTransfer();
    }

    function test_CancelGovernanceTransfer_HappyPath() public {
        vm.prank(governance);
        feedback.proposeGovernanceTransfer(newGovernance);
        vm.expectEmit(true, false, false, false, address(feedback));
        emit IFeedbackController.GovernanceTransferCancelled(newGovernance);
        vm.prank(governance);
        feedback.cancelGovernanceTransfer();
        (address pending,) = feedback.pendingGovernance();
        assertEq(pending, address(0));
    }

    function test_CancelGovernanceTransfer_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(IFeedbackController.NoPendingGovernanceTransfer.selector);
        feedback.cancelGovernanceTransfer();
    }

    // ------------------------------------------------------------------------------------------
    // Multi-resolution compounding
    // ------------------------------------------------------------------------------------------

    function test_ApplyResolution_MultiSequence_Compounds() public {
        // Apply three positive impulses in sequence. Each multiplies mark by (1 + impulse).
        // Use ALBUM_RELEASE (+0.05 × 1e18 = 500 bps cap-free) three times.
        IFeedbackController.ResolutionInput memory input =
            _baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, 1e18);
        vm.startPrank(resolutionWriter);
        feedback.applyResolution(input); // 100 → 105
        feedback.applyResolution(input); // 105 → 110.25
        feedback.applyResolution(input); // 110.25 → 115.7625
        vm.stopPrank();
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        // 100 × 1.05^3 = 115.7625e18
        assertEq(newMark, 115_762_500_000_000_000_000);
    }

    function test_ApplyResolution_MixedSequence_PosNeg() public {
        // +5% then -5% → 100 × 1.05 × 0.95 = 99.75
        vm.startPrank(resolutionWriter);
        feedback.applyResolution(_baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, 1e18));
        feedback.applyResolution(_baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, -int256(1e18)));
        vm.stopPrank();
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        assertEq(newMark, 99_750_000_000_000_000_000);
    }

    function test_ApplyResolution_TwoSubjectsIndependent() public {
        // SUBJECT_ID gets +5%, SUBJECT_ID2 untouched.
        vm.prank(resolutionWriter);
        feedback.applyResolution(_baseInput(IFeedbackController.EventClass.ALBUM_RELEASE, 1e18));
        (uint256 markA,) = engine.markOf(SUBJECT_ID);
        (uint256 markB,) = engine.markOf(SUBJECT_ID2);
        assertEq(markA, 105 * ONE_18);
        assertEq(markB, INITIAL_MARK);
    }

    // ------------------------------------------------------------------------------------------
    // Views consistency
    // ------------------------------------------------------------------------------------------

    function test_IsResolutionWriter_BeforeAndAfterRotation() public {
        assertTrue(feedback.isResolutionWriter(resolutionWriter));
        assertFalse(feedback.isResolutionWriter(newResolutionWriter));
        vm.prank(governance);
        feedback.proposeAddResolutionWriter(newResolutionWriter);
        assertFalse(feedback.isResolutionWriter(newResolutionWriter));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        feedback.activateAddResolutionWriter(newResolutionWriter);
        assertTrue(feedback.isResolutionWriter(newResolutionWriter));
    }

    // ------------------------------------------------------------------------------------------
    // UUPS upgrade authorization
    // ------------------------------------------------------------------------------------------

    function test_UpgradeAuthorization_GovernanceCanUpgrade() public {
        FeedbackController newImpl = new FeedbackController();
        vm.prank(governance);
        UUPSUpgradeableLike(address(feedback)).upgradeToAndCall(address(newImpl), "");
        // Sanity: storage still intact.
        assertEq(feedback.governance(), governance);
    }

    function test_UpgradeAuthorization_RevertOnNonGovernance() public {
        FeedbackController newImpl = new FeedbackController();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IFeedbackController.Unauthorized.selector, stranger));
        UUPSUpgradeableLike(address(feedback)).upgradeToAndCall(address(newImpl), "");
    }
}

interface UUPSUpgradeableLike {
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
}
