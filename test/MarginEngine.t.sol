// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {ILPVault} from "../src/core/ILPVault.sol";
import {IMarginEngine} from "../src/core/IMarginEngine.sol";
import {IPerpEngine} from "../src/core/IPerpEngine.sol";
import {LPVault} from "../src/core/LPVault.sol";
import {MarginEngine} from "../src/core/MarginEngine.sol";
import {PerpEngine} from "../src/core/PerpEngine.sol";

import {ISubjectRegistry} from "../src/registry/ISubjectRegistry.sol";
import {SubjectRegistry} from "../src/registry/SubjectRegistry.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title  MarginEngineTest — direct exercise of the extracted MarginEngine.
/// @notice Covers initialize, setters (with bounds + access control), enforceOpenCaps (happy +
///         each cap-revert path), checkInitialMargin (happy + IM-short + leverage), governance
///         transfer (timelocked), setPerpEngine rotation, view pass-throughs, and the
///         PerpEngine-only bookkeeping hooks. End-to-end open/close happy paths exercised by
///         PerpEngineTest are not repeated here.
contract MarginEngineTest is Test {
    PerpEngine internal engine;
    MarginEngine internal marginEngine;
    LPVault internal vault;
    SubjectRegistry internal registry;
    MockUSDC internal usdc;

    address internal governance = makeAddr("governance");
    address internal vaultOperator = makeAddr("vaultOperator");
    address internal regAdmin = makeAddr("regAdmin");
    address internal regGuardian = makeAddr("regGuardian");
    address internal kycWriter = makeAddr("kycWriter");
    address internal markWriter = makeAddr("markWriter");

    address internal alice = makeAddr("alice"); // LP
    address internal trader = makeAddr("trader");
    address internal trader2 = makeAddr("trader2");
    address internal stranger = makeAddr("stranger");
    address internal newGovernance = makeAddr("newGovernance");

    bytes32 internal constant SUBJECT_ID = keccak256("drake");
    bytes32 internal constant SUBJECT_ID2 = keccak256("taylor");
    bytes32 internal constant CATEGORY_ID = keccak256("musician");
    bytes32 internal constant CATEGORY_ID_ALT = keccak256("athlete");

    uint32 internal constant TIMELOCK_DELAY = 2 days;
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant USDC_1M = 1_000_000 * ONE_USDC;
    uint256 internal constant USDC_10M = 10 * USDC_1M;
    uint256 internal constant ONE_18 = 1e18;
    uint256 internal constant INITIAL_MARK = 100 * ONE_18;

    // ------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------

    function setUp() public {
        vm.warp(2_000_000_000);
        usdc = new MockUSDC();

        // SubjectRegistry
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
        // LPVault
        {
            LPVault impl = new LPVault();
            bytes memory initData = abi.encodeCall(
                LPVault.initialize,
                (IERC20(address(usdc)), governance, vaultOperator, TIMELOCK_DELAY, "People Markets LP USDC", "pmUSDC")
            );
            vault = LPVault(address(new ERC1967Proxy(address(impl), initData)));
        }
        // PerpEngine
        {
            PerpEngine impl = new PerpEngine();
            bytes memory initData =
                abi.encodeCall(PerpEngine.initialize, (governance, TIMELOCK_DELAY, address(registry), address(vault)));
            engine = PerpEngine(address(new ERC1967Proxy(address(impl), initData)));
        }
        // MarginEngine
        {
            MarginEngine impl = new MarginEngine();
            bytes memory initData =
                abi.encodeCall(MarginEngine.initialize, (governance, address(engine), TIMELOCK_DELAY));
            marginEngine = MarginEngine(address(new ERC1967Proxy(address(impl), initData)));
        }

        vm.prank(governance);
        vault.proposeSetPerpEngine(address(engine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateSetPerpEngine();

        vm.prank(governance);
        engine.proposeSetMarginEngine(address(marginEngine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetMarginEngine();

        vm.startPrank(regAdmin);
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);
        registry.listSubject(SUBJECT_ID2, CATEGORY_ID);
        vm.stopPrank();
        vm.startPrank(kycWriter);
        registry.setKycTier(trader, 2);
        registry.setKycTier(trader2, 1);
        vm.stopPrank();

        vm.startPrank(governance);
        marginEngine.setKycCaps(1, 50_000 * ONE_USDC, 200_000 * ONE_USDC);
        marginEngine.setKycCaps(2, 250_000 * ONE_USDC, 1_000_000 * ONE_USDC);
        marginEngine.setKycCaps(3, 1_000_000 * ONE_USDC, 4_000_000 * ONE_USDC);
        engine.setMarkMaxDeltaBps(5_000);
        engine.proposeAddMarkWriter(markWriter);
        vm.stopPrank();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateAddMarkWriter(markWriter);
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, INITIAL_MARK);
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID2, INITIAL_MARK);

        usdc.mint(alice, USDC_10M);
        usdc.mint(trader, USDC_1M);
        usdc.mint(trader2, USDC_1M);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader2);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);
        engine.pokeCappedTvl();
    }

    // ------------------------------------------------------------------------------------------
    // initialize
    // ------------------------------------------------------------------------------------------

    function test_Initialize_StoresParams() public view {
        assertEq(marginEngine.governance(), governance);
        assertEq(marginEngine.perpEngine(), address(engine));
        assertEq(marginEngine.timelockDelay(), TIMELOCK_DELAY);
        (uint16 im, uint16 mm, uint16 buf, uint16 lev, uint16 sub) = marginEngine.marginParams();
        assertEq(im, 2_000);
        assertEq(mm, 500);
        assertEq(buf, 250);
        assertEq(lev, 50_000);
        assertEq(sub, 500);
        assertEq(marginEngine.categoryNetOiCapBps(), 2_000);
        assertEq(marginEngine.crossMarginMultiplier(), 0.25e18);
    }

    function test_Initialize_RevertOnZeroGovernance() public {
        MarginEngine impl = new MarginEngine();
        bytes memory initData = abi.encodeCall(MarginEngine.initialize, (address(0), address(engine), TIMELOCK_DELAY));
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroPerpEngine() public {
        MarginEngine impl = new MarginEngine();
        bytes memory initData = abi.encodeCall(MarginEngine.initialize, (governance, address(0), TIMELOCK_DELAY));
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooShort() public {
        MarginEngine impl = new MarginEngine();
        bytes memory initData =
            abi.encodeCall(MarginEngine.initialize, (governance, address(engine), uint32(1 minutes)));
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooLong() public {
        MarginEngine impl = new MarginEngine();
        bytes memory initData = abi.encodeCall(MarginEngine.initialize, (governance, address(engine), uint32(31 days)));
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_DoubleInitReverts() public {
        vm.expectRevert();
        marginEngine.initialize(governance, address(engine), TIMELOCK_DELAY);
    }

    // ------------------------------------------------------------------------------------------
    // setMarginParams — bounds + access
    // ------------------------------------------------------------------------------------------

    function test_SetMarginParams_HappyPath() public {
        vm.expectEmit(false, false, false, true, address(marginEngine));
        emit IMarginEngine.MarginParamsSet(2_500, 600, 300, 40_000);
        vm.prank(governance);
        marginEngine.setMarginParams(2_500, 600, 300, 40_000);
        (uint16 im, uint16 mm, uint16 buf, uint16 lev,) = marginEngine.marginParams();
        assertEq(im, 2_500);
        assertEq(mm, 600);
        assertEq(buf, 300);
        assertEq(lev, 40_000);
    }

    function test_SetMarginParams_RevertOnImZero() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.InitialMarginBpsOutOfRange.selector, uint16(0)));
        marginEngine.setMarginParams(0, 500, 250, 50_000);
    }

    function test_SetMarginParams_RevertOnImTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.InitialMarginBpsOutOfRange.selector, uint16(10_001)));
        marginEngine.setMarginParams(10_001, 500, 250, 50_000);
    }

    function test_SetMarginParams_RevertOnMmZero() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.MaintenanceMarginBpsOutOfRange.selector, uint16(0)));
        marginEngine.setMarginParams(2_000, 0, 250, 50_000);
    }

    function test_SetMarginParams_RevertOnMmTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.MaintenanceMarginBpsOutOfRange.selector, uint16(5_001)));
        marginEngine.setMarginParams(2_000, 5_001, 250, 50_000);
    }

    function test_SetMarginParams_RevertOnBufTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.LiquidationBufferBpsOutOfRange.selector, uint16(2_001)));
        marginEngine.setMarginParams(2_000, 500, 2_001, 50_000);
    }

    function test_SetMarginParams_RevertOnLevZero() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.MaxLeverageBpsOutOfRange.selector, uint16(0)));
        marginEngine.setMarginParams(2_000, 500, 250, 0);
    }

    function test_SetMarginParams_RevertOnLevTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.MaxLeverageBpsOutOfRange.selector, uint16(60_001)));
        marginEngine.setMarginParams(2_000, 500, 250, 60_001);
    }

    function test_SetMarginParams_RevertOnMmGteIm() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.MmGteIm.selector, uint16(2_000), uint16(2_000)));
        marginEngine.setMarginParams(2_000, 2_000, 250, 50_000);
    }

    function test_SetMarginParams_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.Unauthorized.selector, stranger));
        marginEngine.setMarginParams(2_500, 600, 300, 40_000);
    }

    // ------------------------------------------------------------------------------------------
    // setKycCaps — bounds + access
    // ------------------------------------------------------------------------------------------

    function test_SetKycCaps_HappyPath() public {
        vm.expectEmit(true, false, false, true, address(marginEngine));
        emit IMarginEngine.KycCapsSet(1, 100_000 * ONE_USDC, 400_000 * ONE_USDC);
        vm.prank(governance);
        marginEngine.setKycCaps(1, 100_000 * ONE_USDC, 400_000 * ONE_USDC);
        (uint256 per, uint256 cmb) = marginEngine.tierCaps(1);
        assertEq(per, 100_000 * ONE_USDC);
        assertEq(cmb, 400_000 * ONE_USDC);
    }

    function test_SetKycCaps_RevertOnTierZero() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.InvalidKycTier.selector, uint8(0)));
        marginEngine.setKycCaps(0, 100, 200);
    }

    function test_SetKycCaps_RevertOnTierFour() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.InvalidKycTier.selector, uint8(4)));
        marginEngine.setKycCaps(4, 100, 200);
    }

    function test_SetKycCaps_RevertOnPerSubjectZero() public {
        vm.prank(governance);
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        marginEngine.setKycCaps(1, 0, 100);
    }

    function test_SetKycCaps_RevertOnCombinedZero() public {
        vm.prank(governance);
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        marginEngine.setKycCaps(1, 100, 0);
    }

    function test_SetKycCaps_RevertOnCombinedLessThanPerSubject() public {
        vm.prank(governance);
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        marginEngine.setKycCaps(1, 200, 100);
    }

    function test_SetKycCaps_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.Unauthorized.selector, stranger));
        marginEngine.setKycCaps(1, 100, 200);
    }

    // ------------------------------------------------------------------------------------------
    // setPerSubjectSideOiCapBps — bounds + access
    // ------------------------------------------------------------------------------------------

    function test_SetPerSubjectSideOiCapBps_HappyPath() public {
        vm.expectEmit(false, false, false, true, address(marginEngine));
        emit IMarginEngine.PerSubjectSideOiCapBpsSet(500, 1_000);
        vm.prank(governance);
        marginEngine.setPerSubjectSideOiCapBps(1_000);
        assertEq(marginEngine.perSubjectSideOiCapBps(), 1_000);
    }

    function test_SetPerSubjectSideOiCapBps_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.PerSubjectSideOiCapBpsOutOfRange.selector, uint16(0)));
        marginEngine.setPerSubjectSideOiCapBps(0);
    }

    function test_SetPerSubjectSideOiCapBps_RevertOnTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.PerSubjectSideOiCapBpsOutOfRange.selector, uint16(5_001)));
        marginEngine.setPerSubjectSideOiCapBps(5_001);
    }

    function test_SetPerSubjectSideOiCapBps_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.Unauthorized.selector, stranger));
        marginEngine.setPerSubjectSideOiCapBps(1_000);
    }

    // ------------------------------------------------------------------------------------------
    // setCategoryNetOiCapBps — bounds + access
    // ------------------------------------------------------------------------------------------

    function test_SetCategoryNetOiCapBps_HappyPath() public {
        vm.expectEmit(false, false, false, true, address(marginEngine));
        emit IMarginEngine.CategoryNetOiCapBpsSet(2_000, 3_000);
        vm.prank(governance);
        marginEngine.setCategoryNetOiCapBps(3_000);
        assertEq(marginEngine.categoryNetOiCapBps(), 3_000);
    }

    function test_SetCategoryNetOiCapBps_RevertOnTooLow() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.CategoryNetOiCapBpsOutOfRange.selector, uint16(499)));
        marginEngine.setCategoryNetOiCapBps(499);
    }

    function test_SetCategoryNetOiCapBps_RevertOnTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.CategoryNetOiCapBpsOutOfRange.selector, uint16(5_001)));
        marginEngine.setCategoryNetOiCapBps(5_001);
    }

    function test_SetCategoryNetOiCapBps_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.Unauthorized.selector, stranger));
        marginEngine.setCategoryNetOiCapBps(3_000);
    }

    // ------------------------------------------------------------------------------------------
    // enforceOpenCaps — happy + 4 revert paths
    // ------------------------------------------------------------------------------------------

    function test_EnforceOpenCaps_HappyPath() public view {
        // Within all four caps: $20K LONG on a fresh subject under T2's $250K per-subject cap,
        // category empty, side OI cap = 5% of $1M TVL = $50K → fits.
        marginEngine.enforceOpenCaps(
            trader, SUBJECT_ID, CATEGORY_ID, IMarginEngine.Side.LONG, 20_000 * ONE_USDC, 2, 0, 0, USDC_1M
        );
    }

    function test_EnforceOpenCaps_RevertOnPerSubjectOi() public {
        // 5% × $1M TVL = $50K cap. Try $50_001.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarginEngine.PerSubjectOiCapExceeded.selector,
                SUBJECT_ID,
                IMarginEngine.Side.LONG,
                uint256(50_001 * ONE_USDC),
                uint256(50_000 * ONE_USDC)
            )
        );
        marginEngine.enforceOpenCaps(
            trader, SUBJECT_ID, CATEGORY_ID, IMarginEngine.Side.LONG, 50_001 * ONE_USDC, 2, 0, 0, USDC_1M
        );
    }

    function test_EnforceOpenCaps_RevertOnCategoryOi() public {
        // Use a tiny vaultTvl so category cap (= 5% × small) is the binding constraint. The
        // per-subject side OI cap (default 5%) gives the same denominator, but we set the side
        // cap to 50% (max) so the category cap binds first.
        vm.startPrank(governance);
        marginEngine.setPerSubjectSideOiCapBps(5_000);
        marginEngine.setCategoryNetOiCapBps(500); // 5%
        vm.stopPrank();

        uint256 tinyTvl = 1_000 * ONE_USDC;
        uint256 categoryCap = (tinyTvl * 500) / 10_000; // = 50 * ONE_USDC
        uint256 sideCap = (tinyTvl * 5_000) / 10_000; // = 500 * ONE_USDC — per-subject side cap
        // Pick a size that fits inside the per-subject side cap but exceeds the category cap:
        // 60 * ONE_USDC > 50 (category) but < 500 (side).
        uint256 size = 60 * ONE_USDC;
        assertTrue(size < sideCap);
        assertTrue(size > categoryCap);
        vm.expectRevert(
            abi.encodeWithSelector(IMarginEngine.CategoryOiCapExceeded.selector, CATEGORY_ID, size, categoryCap)
        );
        marginEngine.enforceOpenCaps(trader, SUBJECT_ID, CATEGORY_ID, IMarginEngine.Side.LONG, size, 2, 0, 0, tinyTvl);
    }

    function test_EnforceOpenCaps_RevertOnPerTraderSubject() public {
        // T2 cap = $250K. Bump side OI cap + category cap to 50% so per-trader cap binds first.
        vm.startPrank(governance);
        marginEngine.setPerSubjectSideOiCapBps(5_000); // side OI cap → $500K @ $1M TVL
        marginEngine.setCategoryNetOiCapBps(5_000); // category cap → $500K @ $1M TVL
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IMarginEngine.PerSubjectTraderCapExceeded.selector,
                trader,
                SUBJECT_ID,
                uint256(250_001 * ONE_USDC),
                uint256(250_000 * ONE_USDC)
            )
        );
        marginEngine.enforceOpenCaps(
            trader, SUBJECT_ID, CATEGORY_ID, IMarginEngine.Side.LONG, 250_001 * ONE_USDC, 2, 0, 0, USDC_1M
        );
    }

    function test_EnforceOpenCaps_RevertOnCombinedExposure() public {
        // Plant exposure directly via the recordOpenDelta hook (caller = engine address). With
        // T2 combined cap = $1M and prior exposure of $500K, a $501K open lifts combined to
        // $1.001M and trips the combined-exposure revert. Pump caps wide so combined-exposure
        // is the binding constraint.
        vm.startPrank(governance);
        marginEngine.setKycCaps(2, 1_000_000 * ONE_USDC, 1_000_000 * ONE_USDC);
        marginEngine.setPerSubjectSideOiCapBps(5_000);
        marginEngine.setCategoryNetOiCapBps(5_000);
        vm.stopPrank();

        // Use an alternative category so the per-category accumulator does not bind.
        vm.prank(address(engine));
        marginEngine.recordOpenDelta(trader, CATEGORY_ID_ALT, IMarginEngine.Side.LONG, 500_000 * ONE_USDC, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMarginEngine.CombinedExposureCapExceeded.selector,
                trader,
                uint256(1_001_000 * ONE_USDC),
                uint256(1_000_000 * ONE_USDC)
            )
        );
        marginEngine.enforceOpenCaps(
            trader, SUBJECT_ID2, CATEGORY_ID, IMarginEngine.Side.LONG, 501_000 * ONE_USDC, 2, 0, 0, USDC_1M * 100
        );
    }

    function test_EnforceOpenCaps_ShortSideCapsIndependently() public view {
        // Shorts feed the short OI bucket, not long. With longOI = cap, a short open still fits.
        // longOI = 50K (= cap), but side is SHORT → checks shortOI bucket.
        marginEngine.enforceOpenCaps(
            trader,
            SUBJECT_ID,
            CATEGORY_ID,
            IMarginEngine.Side.SHORT,
            20_000 * ONE_USDC,
            2,
            50_000 * ONE_USDC,
            0,
            USDC_1M
        );
    }

    // ------------------------------------------------------------------------------------------
    // checkInitialMargin — happy + 2 revert paths
    // ------------------------------------------------------------------------------------------

    function test_CheckInitialMargin_HappyPath() public view {
        // $50K notional / $10K collateral = 5× lev. IM = 20% × $50K = $10K. Both checks pass.
        marginEngine.checkInitialMargin(50_000 * ONE_USDC, 10_000 * ONE_USDC);
    }

    function test_CheckInitialMargin_RevertOnLeverageTooHigh() public {
        // $50K / $1K = 50× → above 5× cap.
        vm.expectRevert(
            abi.encodeWithSelector(IMarginEngine.LeverageTooHigh.selector, uint256(500_000), uint256(50_000))
        );
        marginEngine.checkInitialMargin(50_000 * ONE_USDC, 1_000 * ONE_USDC);
    }

    function test_CheckInitialMargin_RevertOnImShort() public {
        // Tighten IM to 30%, leverage stays OK. $50K @ 30% IM = $15K required, send $14K → short.
        vm.prank(governance);
        marginEngine.setMarginParams(3_000, 500, 250, 50_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarginEngine.InitialMarginShort.selector, uint256(15_000 * ONE_USDC), uint256(14_000 * ONE_USDC)
            )
        );
        marginEngine.checkInitialMargin(50_000 * ONE_USDC, 14_000 * ONE_USDC);
    }

    function test_CheckInitialMargin_RevertOnZeroCollateral() public {
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        marginEngine.checkInitialMargin(50_000 * ONE_USDC, 0);
    }

    // ------------------------------------------------------------------------------------------
    // checkInitialMarginResidual — used by removeCollateral
    // ------------------------------------------------------------------------------------------

    function test_CheckInitialMarginResidual_HappyPath() public view {
        marginEngine.checkInitialMarginResidual(11_000 * ONE_USDC, 50_000 * ONE_USDC, int256(0));
    }

    function test_CheckInitialMarginResidual_RevertOnImShort() public {
        // Lift max leverage to 6× (cap) so leverage is not the binding constraint. With IM = 20%,
        // $50K notional needs $10K. Send $9K + 0 uPnL → leverage 50K/9K = 5.55× ≤ 6×; IM check
        // fires.
        vm.prank(governance);
        marginEngine.setMarginParams(2_000, 500, 250, 60_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarginEngine.InitialMarginShort.selector, uint256(10_000 * ONE_USDC), uint256(9_000 * ONE_USDC)
            )
        );
        marginEngine.checkInitialMarginResidual(9_000 * ONE_USDC, 50_000 * ONE_USDC, int256(0));
    }

    function test_CheckInitialMarginResidual_RevertOnLeverage() public {
        // 5× cap, $50K / $5K = 10× → over.
        vm.expectRevert(
            abi.encodeWithSelector(IMarginEngine.LeverageTooHigh.selector, uint256(100_000), uint256(50_000))
        );
        marginEngine.checkInitialMarginResidual(5_000 * ONE_USDC, 50_000 * ONE_USDC, int256(0));
    }

    function test_CheckInitialMarginResidual_RevertOnZeroNotional() public {
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        marginEngine.checkInitialMarginResidual(1_000 * ONE_USDC, 0, int256(0));
    }

    function test_CheckInitialMarginResidual_NegativeEquityFlagsImShort() public {
        // Lift max leverage so the leverage check does not fire first. newCollateral + uPnl < 0 →
        // fail-safe path emits InitialMarginShort(required, 0).
        vm.prank(governance);
        marginEngine.setMarginParams(2_000, 500, 250, 60_000);
        // 50K notional, 10K collateral (lev 5×, ≤ 6× cap), uPnL = -15K → equity = -5K.
        vm.expectRevert(
            abi.encodeWithSelector(IMarginEngine.InitialMarginShort.selector, uint256(10_000 * ONE_USDC), uint256(0))
        );
        marginEngine.checkInitialMarginResidual(10_000 * ONE_USDC, 50_000 * ONE_USDC, -int256(15_000 * ONE_USDC));
    }

    // ------------------------------------------------------------------------------------------
    // isUnderMaintenance — pure probe
    // ------------------------------------------------------------------------------------------

    function test_IsUnderMaintenance_FalseAtOpenPrice() public view {
        // PerpEngine stores `size` in base units = (sizeNotional × 1e18) / mark. For a $50K USDC
        // (= 5e10 in 1e6 scale) position at $100/unit (= 100e18 mark), that's (5e10 × 1e18) /
        // 100e18 = 5e8. Mark == entry → uPnL = 0; equity = collateral; ratio = 10K/50K = 20%.
        int256 size = int256(uint256(5e8));
        bool under = marginEngine.isUnderMaintenance(size, 10_000 * ONE_USDC, 100 * ONE_18, 100 * ONE_18);
        assertFalse(under);
    }

    function test_IsUnderMaintenance_TrueAfterBigLoss() public view {
        // Long with size 5e8 (= $50K notional @ $100). Mark drops to $80 → uPnL = 5e8 ×
        // (80e18 − 100e18) / 1e18 = −1e10 (= −$10K). Equity = 10K − 10K = 0 → ratio 0 < MM.
        int256 size = int256(uint256(5e8));
        bool under = marginEngine.isUnderMaintenance(size, 10_000 * ONE_USDC, 80 * ONE_18, 100 * ONE_18);
        assertTrue(under);
    }

    function test_IsUnderMaintenance_FalseOnZeroSize() public view {
        assertFalse(marginEngine.isUnderMaintenance(0, 1, 1, 1));
    }

    function test_IsUnderMaintenance_FalseOnZeroMark() public view {
        assertFalse(marginEngine.isUnderMaintenance(1, 1, 0, 1));
    }

    // ------------------------------------------------------------------------------------------
    // Hooks — recordOpenDelta / recordCloseDelta
    // ------------------------------------------------------------------------------------------

    function test_RecordOpenDelta_RevertOnNonPerp() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.OnlyPerpEngine.selector, stranger));
        marginEngine.recordOpenDelta(trader, CATEGORY_ID, IMarginEngine.Side.LONG, 1e18, 2);
    }

    function test_RecordCloseDelta_RevertOnNonPerp() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.OnlyPerpEngine.selector, stranger));
        marginEngine.recordCloseDelta(trader, CATEGORY_ID, 1e18, true);
    }

    function test_RecordOpenDelta_LongIncrementsNet() public {
        vm.prank(address(engine));
        marginEngine.recordOpenDelta(trader, CATEGORY_ID, IMarginEngine.Side.LONG, 1_000 * ONE_USDC, 2);
        assertEq(marginEngine.netCategoryOiOf(CATEGORY_ID), int256(1_000 * ONE_USDC));
        (uint256 perp,, uint8 tier) = marginEngine.exposureOf(trader);
        assertEq(perp, 1_000 * ONE_USDC);
        assertEq(tier, 2);
    }

    function test_RecordOpenDelta_ShortDecrementsNet() public {
        vm.prank(address(engine));
        marginEngine.recordOpenDelta(trader, CATEGORY_ID, IMarginEngine.Side.SHORT, 1_000 * ONE_USDC, 2);
        assertEq(marginEngine.netCategoryOiOf(CATEGORY_ID), -int256(1_000 * ONE_USDC));
    }

    function test_RecordCloseDelta_LongUnwindsPositive() public {
        vm.startPrank(address(engine));
        marginEngine.recordOpenDelta(trader, CATEGORY_ID, IMarginEngine.Side.LONG, 1_000 * ONE_USDC, 2);
        marginEngine.recordCloseDelta(trader, CATEGORY_ID, 1_000 * ONE_USDC, true);
        vm.stopPrank();
        assertEq(marginEngine.netCategoryOiOf(CATEGORY_ID), int256(0));
        (uint256 perp,,) = marginEngine.exposureOf(trader);
        assertEq(perp, 0);
    }

    function test_RecordCloseDelta_ShortUnwindsNegative() public {
        vm.startPrank(address(engine));
        marginEngine.recordOpenDelta(trader, CATEGORY_ID, IMarginEngine.Side.SHORT, 1_000 * ONE_USDC, 2);
        marginEngine.recordCloseDelta(trader, CATEGORY_ID, 1_000 * ONE_USDC, false);
        vm.stopPrank();
        assertEq(marginEngine.netCategoryOiOf(CATEGORY_ID), int256(0));
    }

    // ------------------------------------------------------------------------------------------
    // setPerpEngine — wiring rotation
    // ------------------------------------------------------------------------------------------

    function test_SetPerpEngine_HappyPath() public {
        address fresh = makeAddr("freshPerp");
        vm.expectEmit(true, true, false, false, address(marginEngine));
        emit IMarginEngine.PerpEngineSet(address(engine), fresh);
        vm.prank(governance);
        marginEngine.setPerpEngine(fresh);
        assertEq(marginEngine.perpEngine(), fresh);
    }

    function test_SetPerpEngine_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        marginEngine.setPerpEngine(address(0));
    }

    function test_SetPerpEngine_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.Unauthorized.selector, stranger));
        marginEngine.setPerpEngine(makeAddr("x"));
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer — timelocked
    // ------------------------------------------------------------------------------------------

    function test_GovernanceTransfer_HappyPath() public {
        vm.expectEmit(true, false, false, true, address(marginEngine));
        emit IMarginEngine.GovernanceTransferProposed(newGovernance, uint64(block.timestamp + TIMELOCK_DELAY));
        vm.prank(governance);
        marginEngine.proposeGovernanceTransfer(newGovernance);
        (address pending, uint64 readyAt) = marginEngine.pendingGovernance();
        assertEq(pending, newGovernance);
        assertEq(uint256(readyAt), block.timestamp + TIMELOCK_DELAY);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, true, false, false, address(marginEngine));
        emit IMarginEngine.GovernanceTransferActivated(governance, newGovernance);
        marginEngine.activateGovernanceTransfer();
        assertEq(marginEngine.governance(), newGovernance);
    }

    function test_GovernanceTransfer_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        marginEngine.proposeGovernanceTransfer(address(0));
    }

    function test_GovernanceTransfer_RevertOnPendingExists() public {
        vm.startPrank(governance);
        marginEngine.proposeGovernanceTransfer(newGovernance);
        vm.expectRevert(IMarginEngine.PendingGovernanceTransferExists.selector);
        marginEngine.proposeGovernanceTransfer(newGovernance);
        vm.stopPrank();
    }

    function test_GovernanceTransfer_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.Unauthorized.selector, stranger));
        marginEngine.proposeGovernanceTransfer(newGovernance);
    }

    function test_GovernanceTransfer_ActivateRevertOnNoPending() public {
        vm.expectRevert(IMarginEngine.NoPendingGovernanceTransfer.selector);
        marginEngine.activateGovernanceTransfer();
    }

    function test_GovernanceTransfer_ActivateRevertBeforeTimelock() public {
        vm.prank(governance);
        marginEngine.proposeGovernanceTransfer(newGovernance);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.TimelockNotElapsed.selector, readyAt));
        marginEngine.activateGovernanceTransfer();
    }

    function test_GovernanceTransfer_Cancel() public {
        vm.prank(governance);
        marginEngine.proposeGovernanceTransfer(newGovernance);
        vm.expectEmit(true, false, false, false, address(marginEngine));
        emit IMarginEngine.GovernanceTransferCancelled(newGovernance);
        vm.prank(governance);
        marginEngine.cancelGovernanceTransfer();
        (address pending,) = marginEngine.pendingGovernance();
        assertEq(pending, address(0));
    }

    function test_GovernanceTransfer_CancelRevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(IMarginEngine.NoPendingGovernanceTransfer.selector);
        marginEngine.cancelGovernanceTransfer();
    }

    function test_GovernanceTransfer_CancelRevertOnNonGovernance() public {
        vm.prank(governance);
        marginEngine.proposeGovernanceTransfer(newGovernance);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.Unauthorized.selector, stranger));
        marginEngine.cancelGovernanceTransfer();
    }

    // ------------------------------------------------------------------------------------------
    // View pass-throughs
    // ------------------------------------------------------------------------------------------

    function test_Views_IndividualGetters() public view {
        assertEq(marginEngine.initialMarginBps(), 2_000);
        assertEq(marginEngine.maintenanceMarginBps(), 500);
        assertEq(marginEngine.liquidationBufferBps(), 250);
        assertEq(marginEngine.maxLeverageBps(), 50_000);
        assertEq(marginEngine.perSubjectSideOiCapBps(), 500);
        assertEq(marginEngine.categoryNetOiCapBps(), 2_000);
        assertEq(marginEngine.crossMarginMultiplier(), 0.25e18);
        assertEq(marginEngine.tierPerSubjectCap(1), 50_000 * ONE_USDC);
        assertEq(marginEngine.tierCombinedCap(1), 200_000 * ONE_USDC);
        assertEq(marginEngine.tierPerSubjectCap(2), 250_000 * ONE_USDC);
        assertEq(marginEngine.tierCombinedCap(2), 1_000_000 * ONE_USDC);
        assertEq(marginEngine.netCategoryOiOf(CATEGORY_ID), int256(0));
    }

    function test_Views_ExposureOf_EmptyTrader() public {
        (uint256 perp, uint256 evt, uint8 tier) = marginEngine.exposureOf(makeAddr("ghost"));
        assertEq(perp, 0);
        assertEq(evt, 0);
        assertEq(tier, 0);
    }

    function test_Views_IsMarginOk_EmptyPositionReturnsTrue() public view {
        assertTrue(marginEngine.isMarginOk(bytes32(0)));
    }

    function test_Views_IsMarginOk_AfterOpen() public {
        IPerpEngine.OpenParams memory p = IPerpEngine.OpenParams({
            subjectId: SUBJECT_ID,
            side: IPerpEngine.Side.LONG,
            collateralAmount: 10_000 * ONE_USDC,
            sizeNotional: 50_000 * ONE_USDC,
            expectedMark: INITIAL_MARK,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
        vm.prank(trader);
        bytes32 id = engine.openPosition(p);
        assertTrue(marginEngine.isMarginOk(id));
    }

    function test_Views_PositionForReadsThroughPerpEngine() public {
        IPerpEngine.OpenParams memory p = IPerpEngine.OpenParams({
            subjectId: SUBJECT_ID,
            side: IPerpEngine.Side.LONG,
            collateralAmount: 10_000 * ONE_USDC,
            sizeNotional: 50_000 * ONE_USDC,
            expectedMark: INITIAL_MARK,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
        vm.prank(trader);
        bytes32 id = engine.openPosition(p);
        IPerpEngine.Position memory pos = marginEngine.positionFor(id);
        assertGt(pos.size, 0);
        assertEq(pos.owner, trader);
    }

    // ------------------------------------------------------------------------------------------
    // UUPS upgrade authorisation
    // ------------------------------------------------------------------------------------------

    function test_UpgradeAuthorization_RevertOnNonGovernance() public {
        MarginEngine newImpl = new MarginEngine();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.Unauthorized.selector, stranger));
        marginEngine.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeAuthorization_GovernanceCanUpgrade() public {
        MarginEngine newImpl = new MarginEngine();
        vm.prank(governance);
        marginEngine.upgradeToAndCall(address(newImpl), "");
    }

    // ------------------------------------------------------------------------------------------
    // Wave 7 audit Fix #7 — seedNetCategoryOi (one-shot rotation helper)
    //
    // The seed is intended for the rotation flow: deploy fresh MarginEngine → governance
    // computes off-chain reconciliation of the live position set → seed accumulator → activate
    // rotation. The `seeded` flag is one-shot to prevent the accumulator from being rebased
    // after live use.
    // ------------------------------------------------------------------------------------------

    function test_Wave7Fix7_SeedNetCategoryOi_HappyPath() public {
        // Spin up a fresh MarginEngine — the existing `marginEngine` in setUp has already been
        // wired into PerpEngine, so we use a fresh proxy to exercise the rotation seed in
        // isolation.
        MarginEngine implFresh = new MarginEngine();
        bytes memory initData = abi.encodeCall(MarginEngine.initialize, (governance, address(engine), TIMELOCK_DELAY));
        MarginEngine fresh = MarginEngine(address(new ERC1967Proxy(address(implFresh), initData)));
        assertFalse(fresh.seeded());

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = CATEGORY_ID;
        ids[1] = CATEGORY_ID_ALT;
        int256[] memory vals = new int256[](2);
        vals[0] = int256(123 * int256(ONE_USDC));
        vals[1] = -int256(456 * int256(ONE_USDC));

        vm.expectEmit(true, false, false, true, address(fresh));
        emit IMarginEngine.NetCategoryOiSeeded(CATEGORY_ID, vals[0]);
        vm.expectEmit(true, false, false, true, address(fresh));
        emit IMarginEngine.NetCategoryOiSeeded(CATEGORY_ID_ALT, vals[1]);
        vm.expectEmit(false, false, false, false, address(fresh));
        emit IMarginEngine.SeedingFinalized();
        vm.prank(governance);
        fresh.seedNetCategoryOi(ids, vals);

        assertTrue(fresh.seeded());
        assertEq(fresh.netCategoryOiOf(CATEGORY_ID), vals[0]);
        assertEq(fresh.netCategoryOiOf(CATEGORY_ID_ALT), vals[1]);
    }

    function test_Wave7Fix7_SeedNetCategoryOi_RevertOnSecondCall() public {
        MarginEngine implFresh = new MarginEngine();
        bytes memory initData = abi.encodeCall(MarginEngine.initialize, (governance, address(engine), TIMELOCK_DELAY));
        MarginEngine fresh = MarginEngine(address(new ERC1967Proxy(address(implFresh), initData)));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = CATEGORY_ID;
        int256[] memory vals = new int256[](1);
        vals[0] = int256(1);

        vm.prank(governance);
        fresh.seedNetCategoryOi(ids, vals);

        vm.prank(governance);
        vm.expectRevert(IMarginEngine.AlreadySeeded.selector);
        fresh.seedNetCategoryOi(ids, vals);
    }

    function test_Wave7Fix7_SeedNetCategoryOi_RevertOnMismatchedLengths() public {
        MarginEngine implFresh = new MarginEngine();
        bytes memory initData = abi.encodeCall(MarginEngine.initialize, (governance, address(engine), TIMELOCK_DELAY));
        MarginEngine fresh = MarginEngine(address(new ERC1967Proxy(address(implFresh), initData)));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = CATEGORY_ID;
        ids[1] = CATEGORY_ID_ALT;
        int256[] memory vals = new int256[](1);
        vals[0] = int256(1);

        vm.prank(governance);
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        fresh.seedNetCategoryOi(ids, vals);

        // Flag must remain false on revert.
        assertFalse(fresh.seeded());
    }

    function test_Wave7Fix7_SeedNetCategoryOi_RevertOnNonGovernance() public {
        MarginEngine implFresh = new MarginEngine();
        bytes memory initData = abi.encodeCall(MarginEngine.initialize, (governance, address(engine), TIMELOCK_DELAY));
        MarginEngine fresh = MarginEngine(address(new ERC1967Proxy(address(implFresh), initData)));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = CATEGORY_ID;
        int256[] memory vals = new int256[](1);
        vals[0] = int256(1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.Unauthorized.selector, stranger));
        fresh.seedNetCategoryOi(ids, vals);
    }
}
