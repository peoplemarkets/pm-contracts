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

contract PerpEngineTest is Test {
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

    bytes32 internal constant SUBJECT_ID = keccak256("drake");
    bytes32 internal constant SUBJECT_ID2 = keccak256("taylor");
    bytes32 internal constant CATEGORY_ID = keccak256("musician");

    uint32 internal constant TIMELOCK_DELAY = 2 days;
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant USDC_1M = 1_000_000 * ONE_USDC;
    uint256 internal constant USDC_10M = 10 * USDC_1M;
    uint256 internal constant ONE_18 = 1e18;
    uint256 internal constant INITIAL_MARK = 100 * ONE_18; // $100 / Drake

    // ------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------

    function setUp() public {
        // 0. baseline timestamp far enough into the future that we don't underflow on warps.
        vm.warp(2_000_000_000);

        usdc = new MockUSDC();

        // 1. SubjectRegistry behind UUPS.
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

        // 2. LPVault behind UUPS.
        {
            LPVault impl = new LPVault();
            bytes memory initData = abi.encodeCall(
                LPVault.initialize,
                (IERC20(address(usdc)), governance, vaultOperator, TIMELOCK_DELAY, "People Markets LP USDC", "pmUSDC")
            );
            vault = LPVault(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 3. PerpEngine behind UUPS.
        {
            PerpEngine impl = new PerpEngine();
            bytes memory initData =
                abi.encodeCall(PerpEngine.initialize, (governance, TIMELOCK_DELAY, address(registry), address(vault)));
            engine = PerpEngine(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 4. MarginEngine behind UUPS — Wave 4 extraction.
        {
            MarginEngine impl = new MarginEngine();
            bytes memory initData =
                abi.encodeCall(MarginEngine.initialize, (governance, address(engine), TIMELOCK_DELAY));
            marginEngine = MarginEngine(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 5. Wire LPVault.setPerpEngine to the engine address (timelocked).
        vm.prank(governance);
        vault.proposeSetPerpEngine(address(engine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateSetPerpEngine();

        // 6. Wire PerpEngine.marginEngine (timelocked).
        vm.prank(governance);
        engine.proposeSetMarginEngine(address(marginEngine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetMarginEngine();

        // 7. Configure SubjectRegistry: list subjects, set KYC tiers.
        vm.startPrank(regAdmin);
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);
        registry.listSubject(SUBJECT_ID2, CATEGORY_ID);
        vm.stopPrank();
        vm.startPrank(kycWriter);
        registry.setKycTier(trader, 2); // T2 → $250K per-subject, $1M combined
        registry.setKycTier(trader2, 1); // T1 → $50K per-subject, $200K combined
        vm.stopPrank();

        // 8. Configure margin caps on MarginEngine, mark writer on PerpEngine.
        vm.startPrank(governance);
        marginEngine.setKycCaps(1, 50_000 * ONE_USDC, 200_000 * ONE_USDC);
        marginEngine.setKycCaps(2, 250_000 * ONE_USDC, 1_000_000 * ONE_USDC);
        marginEngine.setKycCaps(3, 1_000_000 * ONE_USDC, 4_000_000 * ONE_USDC);
        // Lift the mark-delta cap to its maximum (50%) for the suite — most tests need to push
        // large mark moves to exercise PnL/underwater paths. Dedicated tests for the
        // delta-cap behavior at the default 15% live below.
        engine.setMarkMaxDeltaBps(5_000);
        engine.proposeAddMarkWriter(markWriter);
        vm.stopPrank();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateAddMarkWriter(markWriter);

        // 7. Push initial mark.
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, INITIAL_MARK);
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID2, INITIAL_MARK);

        // 8. Fund actors with USDC and approve the vault.
        usdc.mint(alice, USDC_10M);
        usdc.mint(trader, USDC_1M);
        usdc.mint(trader2, USDC_1M);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader2);
        usdc.approve(address(vault), type(uint256).max);

        // 9. Seed the LP vault with $1M from alice so the OI cap (5% of TVL = $50K) is meaningful.
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);

        // 10. Poke the OI cap snapshot. Without this the cap denominator is 0 and all opens
        // revert PerSubjectOiCapExceeded. Permissionless — anyone can call.
        engine.pokeCappedTvl();
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _baseOpenParams() internal view returns (IPerpEngine.OpenParams memory p) {
        p = IPerpEngine.OpenParams({
            subjectId: SUBJECT_ID,
            side: IPerpEngine.Side.LONG,
            collateralAmount: 10_000 * ONE_USDC, // $10K collateral
            sizeNotional: 50_000 * ONE_USDC, // $50K notional → 5× leverage
            expectedMark: INITIAL_MARK,
            maxSlippageBps: 100, // 1%
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
    }

    function _baseCloseParams() internal view returns (IPerpEngine.CloseParams memory p) {
        p = IPerpEngine.CloseParams({
            subjectId: SUBJECT_ID,
            sizeFractionBps: 10_000, // full close
            expectedMark: INITIAL_MARK,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
    }

    function _open(IPerpEngine.OpenParams memory p) internal returns (bytes32) {
        vm.prank(trader);
        return engine.openPosition(p);
    }

    function _pushMarkAt(uint256 newMark) internal {
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, newMark);
    }

    function _pushMarkAt2(uint256 newMark) internal {
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID2, newMark);
    }

    // ------------------------------------------------------------------------------------------
    // initialize
    // ------------------------------------------------------------------------------------------

    function test_Initialize_StoresParams() public view {
        assertEq(engine.governance(), governance);
        assertEq(engine.timelockDelay(), TIMELOCK_DELAY);
        assertEq(engine.subjectRegistry(), address(registry));
        assertEq(engine.lpVault(), address(vault));
        assertEq(engine.markStaleAfter(), 30 seconds);
        (uint16 imBps, uint16 mmBps,, uint16 maxLevBps,) = marginEngine.marginParams();
        assertEq(imBps, 2_000);
        assertEq(mmBps, 500);
        assertEq(maxLevBps, 50_000);
    }

    function test_Initialize_RevertOnZeroGovernance() public {
        PerpEngine impl = new PerpEngine();
        bytes memory initData =
            abi.encodeCall(PerpEngine.initialize, (address(0), TIMELOCK_DELAY, address(registry), address(vault)));
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroRegistry() public {
        PerpEngine impl = new PerpEngine();
        bytes memory initData =
            abi.encodeCall(PerpEngine.initialize, (governance, TIMELOCK_DELAY, address(0), address(vault)));
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroVault() public {
        PerpEngine impl = new PerpEngine();
        bytes memory initData =
            abi.encodeCall(PerpEngine.initialize, (governance, TIMELOCK_DELAY, address(registry), address(0)));
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooShort() public {
        PerpEngine impl = new PerpEngine();
        bytes memory initData =
            abi.encodeCall(PerpEngine.initialize, (governance, uint32(1 minutes), address(registry), address(vault)));
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_DoubleInitReverts() public {
        vm.expectRevert();
        engine.initialize(governance, TIMELOCK_DELAY, address(registry), address(vault));
    }

    // ------------------------------------------------------------------------------------------
    // pushMark
    // ------------------------------------------------------------------------------------------

    function test_PushMark_HappyPath() public {
        uint256 newMark = 105 * ONE_18;
        vm.expectEmit(true, false, false, true, address(engine));
        emit IPerpEngine.MarkPushed(SUBJECT_ID, INITIAL_MARK, newMark, uint64(block.timestamp));
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, newMark);
        (uint256 price, uint64 ts) = engine.markOf(SUBJECT_ID);
        assertEq(price, newMark);
        assertEq(ts, uint64(block.timestamp));
    }

    function test_PushMark_RevertOnNonWriter() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.Unauthorized.selector, stranger));
        engine.pushMark(SUBJECT_ID, 100 * ONE_18);
    }

    function test_PushMark_RevertOnZero() public {
        vm.prank(markWriter);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.MarkValueOutOfRange.selector, uint256(0)));
        engine.pushMark(SUBJECT_ID, 0);
    }

    function test_PushMark_RevertOnAboveMax() public {
        vm.prank(markWriter);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.MarkValueOutOfRange.selector, uint256(1e36 + 1)));
        engine.pushMark(SUBJECT_ID, 1e36 + 1);
    }

    function test_PushMark_MultiSubjectIndependent() public {
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, 140 * ONE_18); // +40%, within suite-wide 50% cap
        (uint256 priceA,) = engine.markOf(SUBJECT_ID);
        (uint256 priceB,) = engine.markOf(SUBJECT_ID2);
        assertEq(priceA, 140 * ONE_18);
        assertEq(priceB, INITIAL_MARK); // unchanged
    }

    // ------------------------------------------------------------------------------------------
    // openPosition — happy paths
    // ------------------------------------------------------------------------------------------

    function test_OpenPosition_LongHappyPath() public {
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        bytes32 positionId = _open(p);

        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertGt(pos.size, 0);
        assertEq(pos.collateral, p.collateralAmount);
        assertEq(pos.entryPrice, INITIAL_MARK);
        assertEq(pos.owner, trader);
        assertEq(pos.subjectId, SUBJECT_ID);

        assertEq(engine.positionIdOf(trader, SUBJECT_ID), positionId);
        (uint256 longOI, uint256 shortOI) = engine.openInterestOf(SUBJECT_ID);
        assertEq(longOI, p.sizeNotional);
        assertEq(shortOI, 0);

        // Vault state
        assertEq(vault.positionCollateral(), p.collateralAmount);
    }

    function test_OpenPosition_ShortHappyPath() public {
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.side = IPerpEngine.Side.SHORT;
        bytes32 positionId = _open(p);

        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertLt(pos.size, 0);

        (uint256 longOI, uint256 shortOI) = engine.openInterestOf(SUBJECT_ID);
        assertEq(longOI, 0);
        assertEq(shortOI, p.sizeNotional);
    }

    function test_OpenPosition_FeesGoToVault() public {
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        // taker fee = 0.075% × $50K = $37.50
        uint256 expectedFee = (p.sizeNotional * 750) / 1_000_000; // 37.5e6
        uint256 lpRebate = (expectedFee * 40) / 100;
        uint256 insurance = (expectedFee * 50) / 100;
        uint256 residual = expectedFee - lpRebate - insurance;

        uint256 freeAssetsBefore = vault.freeAssets();
        _open(p);

        // freeAssets gains lpRebate (LP rebate stays in share-NAV pool)
        assertEq(vault.freeAssets(), freeAssetsBefore + lpRebate);
        assertEq(vault.insuranceFundBalance(), insurance);
        assertEq(vault.accruedFees(), residual);
    }

    function test_OpenPosition_MakerFeeIsLower() public {
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.isMaker = true;
        // maker fee = 0.025% × $50K = $12.50
        uint256 expectedFee = (p.sizeNotional * 250) / 1_000_000;
        uint256 freeBefore = vault.freeAssets();
        uint256 insBefore = vault.insuranceFundBalance();
        _open(p);
        assertEq(vault.insuranceFundBalance(), insBefore + (expectedFee * 50) / 100);
        assertEq(vault.freeAssets(), freeBefore + (expectedFee * 40) / 100);
    }

    function test_OpenPosition_TwoTradersIndependent() public {
        // OI cap is 5% of $1M TVL = $50K. Two $20K positions stay under.
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.sizeNotional = 20_000 * ONE_USDC;
        p.collateralAmount = 4_000 * ONE_USDC;
        bytes32 id1 = _open(p);

        vm.prank(trader2);
        bytes32 id2 = engine.openPosition(p);

        assertTrue(id1 != id2);
        (uint256 longOI,) = engine.openInterestOf(SUBJECT_ID);
        assertEq(longOI, 40_000 * ONE_USDC);
    }

    // ------------------------------------------------------------------------------------------
    // openPosition — reverts
    // ------------------------------------------------------------------------------------------

    function test_OpenPosition_RevertOnGlobalHalt() public {
        vm.prank(governance);
        engine.setGlobalHalt(true);
        vm.prank(trader);
        vm.expectRevert(IPerpEngine.GlobalHaltedError.selector);
        engine.openPosition(_baseOpenParams());
    }

    function test_OpenPosition_RevertOnDeadlineExpired() public {
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        uint64 dl = uint64(block.timestamp) - 1;
        p.deadline = dl;
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.DeadlineExpired.selector, dl));
        engine.openPosition(p);
    }

    function test_OpenPosition_RevertOnZeroAmounts() public {
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.collateralAmount = 0;
        vm.prank(trader);
        vm.expectRevert(IPerpEngine.AmountZero.selector);
        engine.openPosition(p);

        p = _baseOpenParams();
        p.sizeNotional = 0;
        vm.prank(trader);
        vm.expectRevert(IPerpEngine.AmountZero.selector);
        engine.openPosition(p);
    }

    function test_OpenPosition_RevertOnSubjectNotTradeable() public {
        // Pause the subject and try to open.
        vm.prank(regGuardian);
        registry.setAutoPaused(SUBJECT_ID, 1);
        vm.prank(trader);
        vm.expectRevert();
        engine.openPosition(_baseOpenParams());
    }

    function test_OpenPosition_RevertOnUnregisteredSubject() public {
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.subjectId = keccak256("unknown");
        vm.prank(trader);
        vm.expectRevert();
        engine.openPosition(p);
    }

    function test_OpenPosition_RevertOnKycMissing() public {
        // Stranger has no KYC tier set.
        usdc.mint(stranger, USDC_1M);
        vm.prank(stranger);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.KycTierMissing.selector, stranger));
        engine.openPosition(_baseOpenParams());
    }

    function test_OpenPosition_RevertOnMarkStale() public {
        vm.warp(block.timestamp + 31 seconds); // > 30s staleness
        vm.prank(trader);
        vm.expectRevert();
        engine.openPosition(_baseOpenParams());
    }

    function test_OpenPosition_RevertOnMarkNotSet() public {
        // Use a freshly listed subject without a mark push.
        bytes32 freshSubject = keccak256("freshsubject");
        vm.prank(regAdmin);
        registry.listSubject(freshSubject, CATEGORY_ID);
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.subjectId = freshSubject;
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.MarkNotSet.selector, freshSubject));
        engine.openPosition(p);
    }

    function test_OpenPosition_RevertOnSlippage() public {
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.expectedMark = 90 * ONE_18; // ~10% off; cap is 1%
        vm.prank(trader);
        vm.expectRevert();
        engine.openPosition(p);
    }

    function test_OpenPosition_RevertOnAlreadyOpen() public {
        _open(_baseOpenParams());
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.PositionAlreadyOpen.selector, trader, SUBJECT_ID));
        engine.openPosition(_baseOpenParams());
    }

    function test_OpenPosition_RevertOnLeverageTooHigh() public {
        // Use $1K collateral against $50K notional → 50× leverage, cap is 5×.
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.collateralAmount = 1_000 * ONE_USDC;
        vm.prank(trader);
        vm.expectRevert();
        engine.openPosition(p);
    }

    function test_OpenPosition_RevertOnIMShort() public {
        // Lower leverage but below IM. $50K notional needs 20% = $10K IM. Try $9K.
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.collateralAmount = 9_000 * ONE_USDC;
        vm.prank(trader);
        vm.expectRevert();
        engine.openPosition(p);
    }

    function test_OpenPosition_RevertOnIMShortBindingPath() public {
        // With default params (IM=20%, maxLev=5×) the leverage check is the binding constraint —
        // it trips before IM. Strengthen IM to 30% so it becomes binding, then trigger.
        vm.prank(governance);
        marginEngine.setMarginParams(3_000, 500, 250, 50_000);

        IPerpEngine.OpenParams memory p = _baseOpenParams();
        // 50K notional, IM=30% → IM = $15K. Use $14K collateral so leverage is OK (3.57×) but IM short.
        p.collateralAmount = 14_000 * ONE_USDC;
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPerpEngine.InitialMarginShort.selector, uint256(15_000 * ONE_USDC), uint256(14_000 * ONE_USDC)
            )
        );
        engine.openPosition(p);
    }

    function test_OpenPosition_RevertOnPerTraderSubjectCap_BindingPath() public {
        // Make TVL large enough that the OI cap doesn't bind first; use trader2 (T1, $50K cap).
        usdc.mint(alice, 100 * USDC_10M);
        vm.prank(alice);
        vault.deposit(50 * USDC_10M, alice); // ~$500M TVL → 5% OI cap = $25M
        // v2-audit Fix #3: cappedTvl is pinned at warm-start value until poked.
        vm.warp(block.timestamp + 61);
        engine.pokeCappedTvl();
        _pushMarkAt(INITIAL_MARK); // refresh staleness after the warp

        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.sizeNotional = 60_000 * ONE_USDC; // > $50K per-trader-subject cap
        p.collateralAmount = 12_000 * ONE_USDC;

        vm.prank(trader2);
        // Wave 4: cap reverts now bubble up from MarginEngine with the MarginEngine error
        // signature (PerSubjectTraderCapExceeded). PerpEngine's legacy alias is retained on the
        // interface for source compatibility but the selector matches the MarginEngine variant.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarginEngine.PerSubjectTraderCapExceeded.selector,
                trader2,
                SUBJECT_ID,
                uint256(60_000 * ONE_USDC),
                uint256(50_000 * ONE_USDC)
            )
        );
        engine.openPosition(p);
    }

    function test_OpenPosition_RevertOnZeroExpectedMark() public {
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.expectedMark = 0;
        vm.prank(trader);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.openPosition(p);
    }

    function test_RemoveCollateral_RevertOnIMShortBindingPath() public {
        // Lift IM to 30% so it can bind on remove without leverage tripping first.
        vm.prank(governance);
        marginEngine.setMarginParams(3_000, 500, 250, 50_000);

        // Open with $20K collateral, $50K notional. Leverage 2.5×, well below cap. IM=30% = $15K.
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.collateralAmount = 20_000 * ONE_USDC;
        _open(p);

        // Remove $6K → residual $14K < $15K IM, leverage 50K/14K = 3.57× < 5× cap.
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPerpEngine.InitialMarginShort.selector, uint256(15_000 * ONE_USDC), uint256(14_000 * ONE_USDC)
            )
        );
        engine.removeCollateral(SUBJECT_ID, 6_000 * ONE_USDC);
    }

    function test_OpenPosition_RevertOnPerSubjectOiCap() public {
        // Cap is 5% × $1.1M TVL ≈ $55K. Try $60K notional.
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.sizeNotional = 60_000 * ONE_USDC;
        p.collateralAmount = 12_000 * ONE_USDC;
        vm.prank(trader);
        vm.expectRevert();
        engine.openPosition(p);
    }

    function test_OpenPosition_RevertOnPerTraderSubjectCap() public {
        // T1 trader has a $50K per-subject cap. Try $50,001.
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.sizeNotional = 50_001 * ONE_USDC;
        p.collateralAmount = 10_001 * ONE_USDC;
        // Use trader2 (T1).
        vm.prank(trader2);
        vm.expectRevert();
        engine.openPosition(p);
    }

    function test_OpenPosition_RevertOnCombinedExposureCap() public {
        // T2 combined cap is $1M. Open four $250K positions on different subjects... but we only
        // have 2 subjects. Let's open $250K on SUBJECT_ID and try $250K on SUBJECT_ID2 with more
        // generous LP TVL so the side OI cap isn't hit first.
        usdc.mint(alice, 100 * USDC_10M);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(50 * USDC_10M, alice);
        // v2-audit Fix #3: poke the OI cap snapshot so cap follows the inflated TVL.
        vm.warp(block.timestamp + 61);
        engine.pokeCappedTvl();
        _pushMarkAt(INITIAL_MARK); // refresh staleness after the warp
        _pushMarkAt2(INITIAL_MARK); // also refresh subject 2 (used in the second open)

        // Now lift the trader's combined cap to $300K so we can hit it on the second open.
        vm.prank(governance);
        marginEngine.setKycCaps(2, 250_000 * ONE_USDC, 300_000 * ONE_USDC);

        // First open: $250K on SUBJECT_ID. Within combined cap.
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.sizeNotional = 250_000 * ONE_USDC;
        p.collateralAmount = 50_000 * ONE_USDC;
        _open(p);

        // Second: $250K on SUBJECT_ID2 → combined would be $500K > $300K cap.
        p.subjectId = SUBJECT_ID2;
        vm.prank(trader);
        vm.expectRevert();
        engine.openPosition(p);
    }

    // ------------------------------------------------------------------------------------------
    // closePosition
    // ------------------------------------------------------------------------------------------

    function test_ClosePosition_FullCloseAtBreakEven() public {
        bytes32 positionId = _open(_baseOpenParams());
        uint256 traderBalBefore = usdc.balanceOf(trader);

        vm.prank(trader);
        int256 pnl = engine.closePosition(_baseCloseParams());
        assertEq(pnl, 0);

        // Position deleted
        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertEq(pos.size, 0);
        assertEq(engine.positionIdOf(trader, SUBJECT_ID), bytes32(0));

        // Trader received collateral - fee
        uint256 fee = ((50_000 * ONE_USDC) * 750) / 1_000_000;
        assertEq(usdc.balanceOf(trader) - traderBalBefore, 10_000 * ONE_USDC - fee);

        // OI cleared
        (uint256 longOI,) = engine.openInterestOf(SUBJECT_ID);
        assertEq(longOI, 0);
    }

    function test_ClosePosition_LongProfit() public {
        _open(_baseOpenParams());
        // Mark goes up 10% — long profits.
        _pushMarkAt(110 * ONE_18);

        IPerpEngine.CloseParams memory p = _baseCloseParams();
        p.expectedMark = 110 * ONE_18;
        uint256 traderBalBefore = usdc.balanceOf(trader);

        vm.prank(trader);
        int256 pnl = engine.closePosition(p);
        assertGt(pnl, 0);
        // PnL ≈ 10% × $50K = $5K (less fee).
        assertGt(usdc.balanceOf(trader) - traderBalBefore, 14_000 * ONE_USDC);
    }

    function test_ClosePosition_LongLoss() public {
        _open(_baseOpenParams());
        _pushMarkAt(95 * ONE_18); // -5%

        IPerpEngine.CloseParams memory p = _baseCloseParams();
        p.expectedMark = 95 * ONE_18;
        uint256 traderBalBefore = usdc.balanceOf(trader);

        vm.prank(trader);
        int256 pnl = engine.closePosition(p);
        assertLt(pnl, 0);
        // PnL ≈ -5% × $50K = -$2.5K. Trader gets $10K - $2.5K - fee.
        assertLt(usdc.balanceOf(trader) - traderBalBefore, 8_000 * ONE_USDC);
    }

    function test_ClosePosition_ShortProfit() public {
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.side = IPerpEngine.Side.SHORT;
        _open(p);
        _pushMarkAt(95 * ONE_18); // -5% benefits short

        IPerpEngine.CloseParams memory cp = _baseCloseParams();
        cp.expectedMark = 95 * ONE_18;
        vm.prank(trader);
        int256 pnl = engine.closePosition(cp);
        assertGt(pnl, 0);
    }

    function test_ClosePosition_PartialClose() public {
        bytes32 positionId = _open(_baseOpenParams());

        IPerpEngine.CloseParams memory p = _baseCloseParams();
        p.sizeFractionBps = 5_000; // 50%
        vm.prank(trader);
        engine.closePosition(p);

        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertGt(pos.size, 0); // still open
        assertEq(pos.collateral, 5_000 * ONE_USDC); // halved
        assertEq(pos.entryPrice, INITIAL_MARK); // unchanged
        (uint256 longOI,) = engine.openInterestOf(SUBJECT_ID);
        assertEq(longOI, 25_000 * ONE_USDC); // halved
    }

    function test_ClosePosition_RevertOnGlobalHalt() public {
        _open(_baseOpenParams());
        vm.prank(governance);
        engine.setGlobalHalt(true);
        vm.prank(trader);
        vm.expectRevert(IPerpEngine.GlobalHaltedError.selector);
        engine.closePosition(_baseCloseParams());
    }

    function test_ClosePosition_AllowedDuringSubjectPause() public {
        _open(_baseOpenParams());
        vm.prank(regGuardian);
        registry.setAutoPaused(SUBJECT_ID, 1);
        // Closes must still work for wind-down.
        vm.prank(trader);
        engine.closePosition(_baseCloseParams());
    }

    function test_ClosePosition_RevertOnNoPosition() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.PositionNotOpen.selector, SUBJECT_ID));
        engine.closePosition(_baseCloseParams());
    }

    function test_ClosePosition_RevertOnInvalidFraction() public {
        _open(_baseOpenParams());
        IPerpEngine.CloseParams memory p = _baseCloseParams();
        p.sizeFractionBps = 0;
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.InvalidSizeFraction.selector, uint256(0)));
        engine.closePosition(p);

        p.sizeFractionBps = 10_001;
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.InvalidSizeFraction.selector, uint256(10_001)));
        engine.closePosition(p);
    }

    function test_ClosePosition_RevertOnUnderwater() public {
        _open(_baseOpenParams());
        // Mark drops 25% — long takes -$12.5K loss on $10K collateral → underwater.
        _pushMarkAt(75 * ONE_18);
        IPerpEngine.CloseParams memory p = _baseCloseParams();
        p.expectedMark = 75 * ONE_18;
        vm.prank(trader);
        vm.expectRevert();
        engine.closePosition(p);
    }

    function test_ClosePosition_RevertOnDeadline() public {
        _open(_baseOpenParams());
        IPerpEngine.CloseParams memory p = _baseCloseParams();
        uint64 dl = uint64(block.timestamp) - 1;
        p.deadline = dl;
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.DeadlineExpired.selector, dl));
        engine.closePosition(p);
    }

    function test_ClosePosition_RevertOnSlippage() public {
        _open(_baseOpenParams());
        _pushMarkAt(110 * ONE_18); // moved 10%
        IPerpEngine.CloseParams memory p = _baseCloseParams();
        p.expectedMark = 100 * ONE_18; // expected old price — slippage
        vm.prank(trader);
        vm.expectRevert();
        engine.closePosition(p);
    }

    function test_ClosePosition_RevertOnStaleMark() public {
        _open(_baseOpenParams());
        vm.warp(block.timestamp + 31 seconds);
        vm.prank(trader);
        vm.expectRevert();
        engine.closePosition(_baseCloseParams());
    }

    // ------------------------------------------------------------------------------------------
    // addCollateral / removeCollateral
    // ------------------------------------------------------------------------------------------

    function test_AddCollateral_HappyPath() public {
        bytes32 positionId = _open(_baseOpenParams());
        vm.prank(trader);
        engine.addCollateral(SUBJECT_ID, 5_000 * ONE_USDC);
        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertEq(pos.collateral, 15_000 * ONE_USDC);
    }

    function test_AddCollateral_RevertOnNoPosition() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.PositionNotOpen.selector, SUBJECT_ID));
        engine.addCollateral(SUBJECT_ID, 1_000 * ONE_USDC);
    }

    function test_AddCollateral_RevertOnZero() public {
        _open(_baseOpenParams());
        vm.prank(trader);
        vm.expectRevert(IPerpEngine.AmountZero.selector);
        engine.addCollateral(SUBJECT_ID, 0);
    }

    function test_AddCollateral_RevertOnGlobalHalt() public {
        _open(_baseOpenParams());
        vm.prank(governance);
        engine.setGlobalHalt(true);
        vm.prank(trader);
        vm.expectRevert(IPerpEngine.GlobalHaltedError.selector);
        engine.addCollateral(SUBJECT_ID, 1_000 * ONE_USDC);
    }

    function test_RemoveCollateral_HappyPath() public {
        // Open with extra collateral so we can remove some without breaking IM.
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.collateralAmount = 20_000 * ONE_USDC; // 2.5× leverage
        bytes32 positionId = _open(p);

        uint256 traderBefore = usdc.balanceOf(trader);
        // Remove enough to bring leverage to ~5× (just above 4×). $50K / $11K ≈ 4.5×, IM = $10K, so $11K still fits IM.
        vm.prank(trader);
        engine.removeCollateral(SUBJECT_ID, 9_000 * ONE_USDC);
        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertEq(pos.collateral, 11_000 * ONE_USDC);
        assertEq(usdc.balanceOf(trader) - traderBefore, 9_000 * ONE_USDC);
    }

    function test_RemoveCollateral_RevertOnZero() public {
        _open(_baseOpenParams());
        vm.prank(trader);
        vm.expectRevert(IPerpEngine.AmountZero.selector);
        engine.removeCollateral(SUBJECT_ID, 0);
    }

    function test_RemoveCollateral_RevertOnNoPosition() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.PositionNotOpen.selector, SUBJECT_ID));
        engine.removeCollateral(SUBJECT_ID, 1_000 * ONE_USDC);
    }

    function test_RemoveCollateral_RevertOnAllCollateral() public {
        _open(_baseOpenParams());
        vm.prank(trader);
        vm.expectRevert(IPerpEngine.AmountZero.selector);
        engine.removeCollateral(SUBJECT_ID, 10_000 * ONE_USDC);
    }

    function test_RemoveCollateral_RevertOnIMBreach() public {
        // Open at IM minimum. Removing any collateral pushes us under IM.
        _open(_baseOpenParams());
        vm.prank(trader);
        vm.expectRevert();
        engine.removeCollateral(SUBJECT_ID, 100 * ONE_USDC);
    }

    function test_RemoveCollateral_RevertOnGlobalHalt() public {
        _open(_baseOpenParams());
        vm.prank(governance);
        engine.setGlobalHalt(true);
        vm.prank(trader);
        vm.expectRevert(IPerpEngine.GlobalHaltedError.selector);
        engine.removeCollateral(SUBJECT_ID, 1_000 * ONE_USDC);
    }

    function test_RemoveCollateral_RevertOnNegativeEquity() public {
        // Open, then mark drops so equity goes negative. Even removing 1 wei should fail.
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.collateralAmount = 20_000 * ONE_USDC;
        _open(p);
        _pushMarkAt(50 * ONE_18); // -50% → uPnL on $50K notional ≈ -$25K, equity $20K - $25K = -$5K

        vm.prank(trader);
        vm.expectRevert();
        engine.removeCollateral(SUBJECT_ID, 1);
    }

    // ------------------------------------------------------------------------------------------
    // Mark writer governance
    // ------------------------------------------------------------------------------------------

    function test_MarkWriter_AddTimelocked() public {
        address newWriter = makeAddr("newWriter");
        vm.prank(governance);
        engine.proposeAddMarkWriter(newWriter);
        assertEq(engine.pendingMarkWriterActivatesAt(newWriter), uint64(block.timestamp + TIMELOCK_DELAY));
        assertFalse(engine.isMarkWriter(newWriter));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateAddMarkWriter(newWriter);
        assertTrue(engine.isMarkWriter(newWriter));
        assertEq(engine.pendingMarkWriterActivatesAt(newWriter), 0);
    }

    function test_MarkWriter_RemoveImmediate() public {
        // Already added in setUp.
        assertTrue(engine.isMarkWriter(markWriter));
        vm.prank(governance);
        engine.removeMarkWriter(markWriter);
        assertFalse(engine.isMarkWriter(markWriter));
    }

    function test_MarkWriter_ProposeRevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.Unauthorized.selector, stranger));
        engine.proposeAddMarkWriter(makeAddr("x"));
    }

    function test_MarkWriter_ProposeRevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.proposeAddMarkWriter(address(0));
    }

    function test_MarkWriter_ProposeRevertOnAlreadyAdded() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.MarkWriterAlreadyAdded.selector, markWriter));
        engine.proposeAddMarkWriter(markWriter);
    }

    function test_MarkWriter_ProposeRevertOnPendingExists() public {
        address newWriter = makeAddr("newWriter");
        vm.startPrank(governance);
        engine.proposeAddMarkWriter(newWriter);
        vm.expectRevert(IPerpEngine.PendingProposalExists.selector);
        engine.proposeAddMarkWriter(newWriter);
        vm.stopPrank();
    }

    function test_MarkWriter_ActivateRevertOnNoPending() public {
        vm.expectRevert(IPerpEngine.NoPendingProposal.selector);
        engine.activateAddMarkWriter(makeAddr("x"));
    }

    function test_MarkWriter_ActivateRevertOnTimelock() public {
        address newWriter = makeAddr("newWriter");
        vm.prank(governance);
        engine.proposeAddMarkWriter(newWriter);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.TimelockNotElapsed.selector, readyAt));
        engine.activateAddMarkWriter(newWriter);
    }

    function test_MarkWriter_CancelHappyPath() public {
        address newWriter = makeAddr("newWriter");
        vm.prank(governance);
        engine.proposeAddMarkWriter(newWriter);
        vm.prank(governance);
        engine.cancelAddMarkWriter(newWriter);
        assertEq(engine.pendingMarkWriterActivatesAt(newWriter), 0);
    }

    function test_MarkWriter_CancelRevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.NoPendingProposal.selector);
        engine.cancelAddMarkWriter(makeAddr("x"));
    }

    function test_MarkWriter_RemoveRevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.Unauthorized.selector, stranger));
        engine.removeMarkWriter(markWriter);
    }

    function test_MarkWriter_RemoveRevertOnNotFound() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.MarkWriterNotFound.selector, stranger));
        engine.removeMarkWriter(stranger);
    }

    function test_MarkWriter_CancelRevertOnNonGovernance() public {
        address newWriter = makeAddr("newWriter");
        vm.prank(governance);
        engine.proposeAddMarkWriter(newWriter);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.Unauthorized.selector, stranger));
        engine.cancelAddMarkWriter(newWriter);
    }

    // ------------------------------------------------------------------------------------------
    // Margin params + KYC caps + mark stale after
    // ------------------------------------------------------------------------------------------

    function test_SetMarginParams_HappyPath() public {
        vm.prank(governance);
        marginEngine.setMarginParams(2_500, 600, 300, 40_000);
        (uint16 im, uint16 mm, uint16 buf, uint16 lev,) = marginEngine.marginParams();
        assertEq(im, 2_500);
        assertEq(mm, 600);
        assertEq(buf, 300);
        assertEq(lev, 40_000);
    }

    function test_SetMarginParams_RevertOnInvalidImBps() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.InitialMarginBpsOutOfRange.selector, uint16(0)));
        marginEngine.setMarginParams(0, 500, 250, 50_000);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.InitialMarginBpsOutOfRange.selector, uint16(10_001)));
        marginEngine.setMarginParams(10_001, 500, 250, 50_000);
    }

    function test_SetMarginParams_RevertOnMmGteIm() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.MmGteIm.selector, uint16(2_000), uint16(2_000)));
        marginEngine.setMarginParams(2_000, 2_000, 250, 50_000);
    }

    function test_SetMarginParams_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.Unauthorized.selector, stranger));
        marginEngine.setMarginParams(2_000, 500, 250, 50_000);
    }

    function test_SetMarginParams_RevertOnInvalidMm() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.MaintenanceMarginBpsOutOfRange.selector, uint16(0)));
        marginEngine.setMarginParams(2_000, 0, 250, 50_000);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.MaintenanceMarginBpsOutOfRange.selector, uint16(5_001)));
        marginEngine.setMarginParams(2_000, 5_001, 250, 50_000);
    }

    function test_SetMarginParams_RevertOnInvalidBuf() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.LiquidationBufferBpsOutOfRange.selector, uint16(2_001)));
        marginEngine.setMarginParams(2_000, 500, 2_001, 50_000);
    }

    function test_SetMarginParams_RevertOnInvalidLev() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.MaxLeverageBpsOutOfRange.selector, uint16(0)));
        marginEngine.setMarginParams(2_000, 500, 250, 0);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.MaxLeverageBpsOutOfRange.selector, uint16(60_001)));
        marginEngine.setMarginParams(2_000, 500, 250, 60_001);
    }

    function test_SetKycCaps_HappyPath() public {
        vm.prank(governance);
        marginEngine.setKycCaps(1, 100_000 * ONE_USDC, 400_000 * ONE_USDC);
        (uint256 perSubject, uint256 combined) = marginEngine.tierCaps(1);
        assertEq(perSubject, 100_000 * ONE_USDC);
        assertEq(combined, 400_000 * ONE_USDC);
    }

    function test_SetKycCaps_RevertOnInvalidTier() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.InvalidKycTier.selector, uint8(0)));
        marginEngine.setKycCaps(0, 100, 200);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.InvalidKycTier.selector, uint8(4)));
        marginEngine.setKycCaps(4, 100, 200);
    }

    function test_SetKycCaps_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        marginEngine.setKycCaps(1, 0, 100);

        vm.prank(governance);
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        marginEngine.setKycCaps(1, 100, 0);
    }

    function test_SetKycCaps_RevertOnCombinedLessThanPerSubject() public {
        vm.prank(governance);
        vm.expectRevert(IMarginEngine.InvalidConfig.selector);
        marginEngine.setKycCaps(1, 200, 100);
    }

    function test_SetMarkStaleAfter_HappyPath() public {
        vm.prank(governance);
        engine.setMarkStaleAfter(60 seconds);
        assertEq(engine.markStaleAfter(), 60 seconds);
    }

    function test_SetMarkStaleAfter_RevertOnOutOfRange() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setMarkStaleAfter(2 seconds); // below MIN_MARK_STALE_AFTER

        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setMarkStaleAfter(2 hours); // above MAX
    }

    function test_SetPerSubjectSideOiCapBps_HappyPath() public {
        vm.prank(governance);
        marginEngine.setPerSubjectSideOiCapBps(1_000); // 10%
        (,,,, uint16 cap) = marginEngine.marginParams();
        assertEq(cap, 1_000);
    }

    function test_SetPerSubjectSideOiCapBps_RevertOnOutOfRange() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.PerSubjectSideOiCapBpsOutOfRange.selector, uint16(0)));
        marginEngine.setPerSubjectSideOiCapBps(0);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.PerSubjectSideOiCapBpsOutOfRange.selector, uint16(5_001)));
        marginEngine.setPerSubjectSideOiCapBps(5_001);
    }

    // ------------------------------------------------------------------------------------------
    // setGlobalHalt
    // ------------------------------------------------------------------------------------------

    function test_SetGlobalHalt_HappyPath() public {
        vm.prank(governance);
        engine.setGlobalHalt(true);
        assertTrue(engine.globalHalt());

        vm.prank(governance);
        engine.setGlobalHalt(false);
        assertFalse(engine.globalHalt());
    }

    function test_SetGlobalHalt_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.Unauthorized.selector, stranger));
        engine.setGlobalHalt(true);
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer
    // ------------------------------------------------------------------------------------------

    function test_GovernanceTransfer_HappyPath() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        engine.proposeGovernanceTransfer(newGov);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateGovernanceTransfer();
        assertEq(engine.governance(), newGov);
    }

    function test_GovernanceTransfer_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.Unauthorized.selector, stranger));
        engine.proposeGovernanceTransfer(makeAddr("x"));
    }

    function test_GovernanceTransfer_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.proposeGovernanceTransfer(address(0));
    }

    function test_GovernanceTransfer_RevertOnPendingExists() public {
        vm.startPrank(governance);
        engine.proposeGovernanceTransfer(makeAddr("x"));
        vm.expectRevert(IPerpEngine.PendingProposalExists.selector);
        engine.proposeGovernanceTransfer(makeAddr("y"));
        vm.stopPrank();
    }

    function test_GovernanceTransfer_ActivateRevertOnNoPending() public {
        vm.expectRevert(IPerpEngine.NoPendingProposal.selector);
        engine.activateGovernanceTransfer();
    }

    function test_GovernanceTransfer_ActivateRevertBeforeTimelock() public {
        vm.prank(governance);
        engine.proposeGovernanceTransfer(makeAddr("x"));
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.TimelockNotElapsed.selector, readyAt));
        engine.activateGovernanceTransfer();
    }

    function test_GovernanceTransfer_CancelHappyPath() public {
        vm.prank(governance);
        engine.proposeGovernanceTransfer(makeAddr("x"));
        vm.prank(governance);
        engine.cancelGovernanceTransfer();
        (address pending, uint64 readyAt) = engine.pendingGovernance();
        assertEq(pending, address(0));
        assertEq(readyAt, 0);
    }

    function test_GovernanceTransfer_CancelRevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.NoPendingProposal.selector);
        engine.cancelGovernanceTransfer();
    }

    function test_GovernanceTransfer_CancelRevertOnNonGovernance() public {
        vm.prank(governance);
        engine.proposeGovernanceTransfer(makeAddr("x"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.Unauthorized.selector, stranger));
        engine.cancelGovernanceTransfer();
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function test_Views_OpenPositionViews() public {
        bytes32 positionId = _open(_baseOpenParams());
        assertGt(engine.equityOf(positionId), 0);
        assertGt(engine.marginRatioBpsOf(positionId), 0);
        assertGt(engine.leverageBpsOf(positionId), 0);
        assertTrue(marginEngine.isMarginOk(positionId));
    }

    function test_Views_ZeroSizePositionReturnsDefaults() public view {
        bytes32 unknown = bytes32(0);
        assertEq(engine.equityOf(unknown), 0);
        assertEq(engine.marginRatioBpsOf(unknown), 0);
        assertEq(engine.leverageBpsOf(unknown), 0);
        assertTrue(marginEngine.isMarginOk(unknown)); // empty position is "OK"
    }

    function test_Views_ExposureOf() public {
        _open(_baseOpenParams());
        (uint256 totalPerp, uint256 totalEvent, uint8 tier) = marginEngine.exposureOf(trader);
        assertEq(totalPerp, 50_000 * ONE_USDC);
        assertEq(totalEvent, 0);
        assertEq(tier, 2);
    }

    function test_Views_TierCaps() public view {
        (uint256 perS, uint256 combined) = marginEngine.tierCaps(2);
        assertEq(perS, 250_000 * ONE_USDC);
        assertEq(combined, 1_000_000 * ONE_USDC);
    }

    function test_Views_PendingMarkWriter() public {
        address w = makeAddr("w");
        vm.prank(governance);
        engine.proposeAddMarkWriter(w);
        assertGt(engine.pendingMarkWriterActivatesAt(w), 0);
    }

    function test_Views_MarkOf() public view {
        (uint256 price, uint64 ts) = engine.markOf(SUBJECT_ID);
        assertEq(price, INITIAL_MARK);
        assertGt(ts, 0);
    }

    // ------------------------------------------------------------------------------------------
    // Fix #7 — forceSettleSubject + closeAtForcedSettlement
    // ------------------------------------------------------------------------------------------

    /// @dev Helper: drive subject to DELISTED through the involuntary path (cleanest, no warps).
    function _delistSubject(bytes32 subjectId) internal {
        vm.prank(regAdmin);
        registry.involuntaryDelist(subjectId);
    }

    function test_ForceSettleSubject_HappyPath_AfterInvoluntaryDelist() public {
        _delistSubject(SUBJECT_ID);
        vm.expectEmit(true, false, true, true, address(engine));
        emit IPerpEngine.SubjectForceSettled(SUBJECT_ID, 110 * ONE_18, governance);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, 110 * ONE_18);

        assertTrue(engine.isForceSettled(SUBJECT_ID));
        assertEq(engine.settlementMarkOf(SUBJECT_ID), 110 * ONE_18);
    }

    function test_ForceSettleSubject_HappyPath_AfterDeathConfirmed() public {
        vm.prank(regAdmin);
        registry.flagDeathPending(SUBJECT_ID);
        vm.prank(regAdmin);
        registry.confirmDeath(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, 100 * ONE_18);
        assertTrue(engine.isForceSettled(SUBJECT_ID));
    }

    function test_ForceSettleSubject_HappyPath_AfterDelistingWindow() public {
        vm.prank(regAdmin);
        registry.requestDelisting(SUBJECT_ID);
        vm.warp(block.timestamp + 7 days);
        registry.forceSettle(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, 100 * ONE_18);
        assertTrue(engine.isForceSettled(SUBJECT_ID));
    }

    function test_ForceSettleSubject_RevertOnNonGovernance() public {
        _delistSubject(SUBJECT_ID);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.Unauthorized.selector, stranger));
        engine.forceSettleSubject(SUBJECT_ID, 100 * ONE_18);
    }

    function test_ForceSettleSubject_RevertOnActiveStatus() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.SubjectNotDelisted.selector, SUBJECT_ID));
        engine.forceSettleSubject(SUBJECT_ID, 100 * ONE_18);
    }

    function test_ForceSettleSubject_RevertOnDeathPendingNotConfirmed() public {
        vm.prank(regAdmin);
        registry.flagDeathPending(SUBJECT_ID);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.SubjectNotDelisted.selector, SUBJECT_ID));
        engine.forceSettleSubject(SUBJECT_ID, 100 * ONE_18);
    }

    function test_ForceSettleSubject_RevertOnDoubleCall() public {
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, 100 * ONE_18);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.SubjectAlreadyForceSettled.selector, SUBJECT_ID));
        engine.forceSettleSubject(SUBJECT_ID, 110 * ONE_18);
    }

    function test_ForceSettleSubject_RevertOnZeroMark() public {
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.MarkValueOutOfRange.selector, uint256(0)));
        engine.forceSettleSubject(SUBJECT_ID, 0);
    }

    function test_ForceSettleSubject_RevertOnMarkAboveMax() public {
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.MarkValueOutOfRange.selector, uint256(1e36 + 1)));
        engine.forceSettleSubject(SUBJECT_ID, 1e36 + 1);
    }

    function test_ClosePosition_RevertOnForceSettled() public {
        _open(_baseOpenParams());
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, 100 * ONE_18);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.SubjectIsForceSettled.selector, SUBJECT_ID));
        engine.closePosition(_baseCloseParams());
    }

    function test_AddCollateral_RevertOnForceSettled() public {
        _open(_baseOpenParams());
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, 100 * ONE_18);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.SubjectIsForceSettled.selector, SUBJECT_ID));
        engine.addCollateral(SUBJECT_ID, 1_000 * ONE_USDC);
    }

    function test_RemoveCollateral_RevertOnForceSettled() public {
        _open(_baseOpenParams());
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, 100 * ONE_18);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.SubjectIsForceSettled.selector, SUBJECT_ID));
        engine.removeCollateral(SUBJECT_ID, 100 * ONE_USDC);
    }

    function test_CloseAtForcedSettlement_HappyPath_NoMove() public {
        _open(_baseOpenParams());
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, INITIAL_MARK);

        uint256 traderBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        int256 pnl = engine.closeAtForcedSettlement(SUBJECT_ID);
        assertEq(pnl, 0);
        // No fee on forced settlement — trader gets full collateral back
        assertEq(usdc.balanceOf(trader) - traderBefore, 10_000 * ONE_USDC);
    }

    function test_CloseAtForcedSettlement_HappyPath_LongProfit() public {
        _open(_baseOpenParams());
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, 110 * ONE_18); // +10% → +$5K on $50K notional

        uint256 traderBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        int256 pnl = engine.closeAtForcedSettlement(SUBJECT_ID);
        assertGt(pnl, 0);
        // Collat $10K + ~$5K profit, zero fee
        assertEq(usdc.balanceOf(trader) - traderBefore, 15_000 * ONE_USDC);
    }

    function test_CloseAtForcedSettlement_HappyPath_LongLoss() public {
        _open(_baseOpenParams());
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, 95 * ONE_18); // -5% → -$2.5K

        uint256 traderBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        int256 pnl = engine.closeAtForcedSettlement(SUBJECT_ID);
        assertLt(pnl, 0);
        assertEq(usdc.balanceOf(trader) - traderBefore, 7_500 * ONE_USDC);
    }

    function test_CloseAtForcedSettlement_HappyPath_Short() public {
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.side = IPerpEngine.Side.SHORT;
        _open(p);
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, 90 * ONE_18); // -10% → +$5K for short

        vm.prank(trader);
        int256 pnl = engine.closeAtForcedSettlement(SUBJECT_ID);
        assertGt(pnl, 0);
    }

    function test_CloseAtForcedSettlement_RevertOnNotForceSettled() public {
        _open(_baseOpenParams());
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.SubjectNotForceSettled.selector, SUBJECT_ID));
        engine.closeAtForcedSettlement(SUBJECT_ID);
    }

    function test_CloseAtForcedSettlement_RevertOnNoPosition() public {
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, 100 * ONE_18);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.PositionNotOpen.selector, SUBJECT_ID));
        engine.closeAtForcedSettlement(SUBJECT_ID);
    }

    function test_CloseAtForcedSettlement_UnderwaterCappedAtCollateral() public {
        // v2-audit Fix #1: an underwater position settles cleanly with trader losing all
        // collateral; the vault keeps the full collateral as loss-recovery. Pre-fix this would
        // revert UnderwaterClose and permanently strand the collateral.
        _open(_baseOpenParams());
        _delistSubject(SUBJECT_ID);
        // Force-settle at -25% → -$12.5K loss on $10K collat → underwater by $2.5K
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, 75 * ONE_18);

        uint256 traderBalBefore = usdc.balanceOf(trader);
        uint256 vaultPosCollatBefore = vault.positionCollateral();

        vm.prank(trader);
        int256 pnl = engine.closeAtForcedSettlement(SUBJECT_ID);
        // Trader gets nothing (collateral fully wiped)
        assertEq(usdc.balanceOf(trader), traderBalBefore);
        // Position cleared
        assertEq(engine.positionIdOf(trader, SUBJECT_ID), bytes32(0));
        // Vault positionCollateral decremented by the position's collateral
        assertEq(vault.positionCollateral(), vaultPosCollatBefore - 10_000 * ONE_USDC);
        // PnL reported is capped at -collateral (not the true -$12.5K loss)
        assertEq(pnl, -int256(10_000 * ONE_USDC));
    }

    function test_CloseAtForcedSettlement_IgnoresStaleness() public {
        _open(_baseOpenParams());
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, INITIAL_MARK);
        // Let the live mark go stale; capture is canonical, so close still works
        vm.warp(block.timestamp + 1 hours);
        vm.prank(trader);
        engine.closeAtForcedSettlement(SUBJECT_ID);
        assertEq(engine.positionIdOf(trader, SUBJECT_ID), bytes32(0));
    }

    function test_CloseAtForcedSettlement_NotBlockedByGlobalHalt() public {
        _open(_baseOpenParams());
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, INITIAL_MARK);
        vm.prank(governance);
        engine.setGlobalHalt(true);
        vm.prank(trader);
        engine.closeAtForcedSettlement(SUBJECT_ID); // succeeds despite halt
    }

    function test_CloseAtForcedSettlement_OiAndExposureCleared() public {
        _open(_baseOpenParams());
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, INITIAL_MARK);
        vm.prank(trader);
        engine.closeAtForcedSettlement(SUBJECT_ID);
        (uint256 longOI, uint256 shortOI) = engine.openInterestOf(SUBJECT_ID);
        assertEq(longOI, 0);
        assertEq(shortOI, 0);
        (uint256 totalNotional,,) = marginEngine.exposureOf(trader);
        assertEq(totalNotional, 0);
    }

    function test_CloseAtForcedSettlement_TwoTradersIndependent() public {
        // Open two positions on the same subject (2 different traders), then force-settle.
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.sizeNotional = 20_000 * ONE_USDC;
        p.collateralAmount = 4_000 * ONE_USDC;
        _open(p);
        vm.prank(trader2);
        engine.openPosition(p);

        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, INITIAL_MARK);

        vm.prank(trader);
        engine.closeAtForcedSettlement(SUBJECT_ID);
        // trader2 claims independently later
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(trader2);
        engine.closeAtForcedSettlement(SUBJECT_ID);

        assertEq(engine.positionIdOf(trader, SUBJECT_ID), bytes32(0));
        assertEq(engine.positionIdOf(trader2, SUBJECT_ID), bytes32(0));
    }

    function test_OpenPosition_BlockedOnForceSettledSubject() public {
        // A delisted subject is already blocked by requireTradeable, but verify the chain.
        _delistSubject(SUBJECT_ID);
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, INITIAL_MARK);
        vm.prank(trader);
        vm.expectRevert(); // requireTradeable rejects DELISTED status
        engine.openPosition(_baseOpenParams());
    }

    // ------------------------------------------------------------------------------------------
    // v2-audit Fix #3 — slow-moving TVL signal for OI cap
    // ------------------------------------------------------------------------------------------

    function test_PokeCappedTvl_HappyPath() public {
        // setUp already poked. Advance past cooldown and re-poke.
        (uint256 tvl0,) = engine.cappedTvl();
        vm.warp(block.timestamp + 61);
        // Add LP to grow freeAssets
        usdc.mint(alice, 5 * USDC_1M);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(2 * USDC_1M, alice);
        engine.pokeCappedTvl();
        (uint256 tvl1,) = engine.cappedTvl();
        assertGt(tvl1, tvl0);
    }

    function test_PokeCappedTvl_RevertOnCooldown() public {
        (, uint64 lastUpdate) = engine.cappedTvl();
        uint64 readyAt = lastUpdate + 60;
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.CappedTvlPokeTooSoon.selector, readyAt));
        engine.pokeCappedTvl();
    }

    function test_FlashDepositCannotInflateOiCap() public {
        // Reset to default OI cap (5%, ~$50K against ~$1M TVL) for this test.
        // Attacker deposits a huge amount in the same tx as opening to inflate freeAssets.
        // Without the cap, attacker could open against the inflated TVL.
        // With the cap (cappedTvl is set to pre-deposit value), the attacker is bounded.
        usdc.mint(trader, 100 * USDC_1M);
        // First, the trader's pre-flash open at $50K (within the original $50K cap).
        IPerpEngine.OpenParams memory pBaseline = _baseOpenParams();
        _open(pBaseline); // succeeds
        vm.prank(trader);
        engine.closePosition(_baseCloseParams()); // close to free up cap

        // Now try to open MORE than 5% of pre-deposit TVL after flash-depositing massive USDC.
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        vault.deposit(50 * USDC_1M, trader); // huge flash-style deposit to try to inflate cap
        // Try to open $200K notional (4× over the $50K cap of pre-deposit TVL).
        IPerpEngine.OpenParams memory pBig = _baseOpenParams();
        pBig.sizeNotional = 200_000 * ONE_USDC;
        pBig.collateralAmount = 40_000 * ONE_USDC;
        vm.prank(trader);
        vm.expectRevert(); // PerSubjectOiCapExceeded — cap stayed pinned at pre-deposit cappedTvl
        engine.openPosition(pBig);
    }

    function test_CappedTvlReadsLowerOfStoredAndLive() public {
        // After a withdrawal, freeAssets drops below cappedTvl. Cap should immediately tighten.
        // Setup deposits alice's USDC at setUp; she holds vault shares. Warm-start cappedTvl = $1M.
        // alice has all the LP shares; redeem half to drop freeAssets to ~$500K.
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares / 2, alice, alice); // freeAssets drops ≈ $500K
        // cappedTvl is unchanged at ~$1M (last poked in setUp), but live is now ~$500K.
        // OI cap reads min(cappedTvl, liveTvl) → ~$500K → cap = ~$25K.
        // Try to open $40K (under the stale cap of $50K, but over the new effective cap of $25K).
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.sizeNotional = 40_000 * ONE_USDC;
        p.collateralAmount = 8_000 * ONE_USDC;
        vm.prank(trader);
        vm.expectRevert(); // PerSubjectOiCapExceeded — cap follows the lower of the two
        engine.openPosition(p);
    }

    // ------------------------------------------------------------------------------------------
    // v2-audit Fix #5 — pushMark per-update max-delta cap
    // ------------------------------------------------------------------------------------------

    function test_MarkMaxDeltaBps_DefaultIs1500() public {
        // Reset to default for this test (setUp lifts to 5000).
        vm.prank(governance);
        engine.setMarkMaxDeltaBps(1_500);
        assertEq(engine.markMaxDeltaBps(), 1_500);
    }

    function test_PushMark_WithinCap() public {
        vm.prank(governance);
        engine.setMarkMaxDeltaBps(1_500);
        // 100 → 110 = +10%, within 15% cap
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, 110 * ONE_18);
        (uint256 mark,) = engine.markOf(SUBJECT_ID);
        assertEq(mark, 110 * ONE_18);
    }

    function test_PushMark_ExactlyAtCap() public {
        vm.prank(governance);
        engine.setMarkMaxDeltaBps(1_500);
        // 100 → 115 = exactly +15%
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, 115 * ONE_18);
    }

    function test_PushMark_RevertOnDeltaTooLargeUp() public {
        vm.prank(governance);
        engine.setMarkMaxDeltaBps(1_500);
        // 100 → 116 = +16%, exceeds 15% cap
        vm.prank(markWriter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPerpEngine.MarkDeltaTooLarge.selector, SUBJECT_ID, INITIAL_MARK, 116 * ONE_18, uint16(1_500)
            )
        );
        engine.pushMark(SUBJECT_ID, 116 * ONE_18);
    }

    function test_PushMark_RevertOnDeltaTooLargeDown() public {
        vm.prank(governance);
        engine.setMarkMaxDeltaBps(1_500);
        // 100 → 84 = -16%, exceeds 15% cap
        vm.prank(markWriter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPerpEngine.MarkDeltaTooLarge.selector, SUBJECT_ID, INITIAL_MARK, 84 * ONE_18, uint16(1_500)
            )
        );
        engine.pushMark(SUBJECT_ID, 84 * ONE_18);
    }

    function test_PushMark_FirstPushUncappedOnFreshSubject() public {
        // Fresh subject with no prior mark — first push is unbounded.
        bytes32 freshSubject = keccak256("fresh");
        vm.prank(regAdmin);
        registry.listSubject(freshSubject, CATEGORY_ID);

        vm.prank(governance);
        engine.setMarkMaxDeltaBps(1_500);

        // Any value within MIN_MARK..MAX_MARK is allowed on first push.
        vm.prank(markWriter);
        engine.pushMark(freshSubject, 1_000_000 * ONE_18); // far beyond 15% of any prior reference
        (uint256 mark,) = engine.markOf(freshSubject);
        assertEq(mark, 1_000_000 * ONE_18);
    }

    function test_SetMarkMaxDeltaBps_RevertBelowMin() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.MarkMaxDeltaBpsOutOfRange.selector, uint16(99)));
        engine.setMarkMaxDeltaBps(99);
    }

    function test_SetMarkMaxDeltaBps_RevertAboveMax() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.MarkMaxDeltaBpsOutOfRange.selector, uint16(5_001)));
        engine.setMarkMaxDeltaBps(5_001);
    }

    function test_SetMarkMaxDeltaBps_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.Unauthorized.selector, stranger));
        engine.setMarkMaxDeltaBps(1_500);
    }

    // ------------------------------------------------------------------------------------------
    // Fix #11 — setLpRebatePct
    // ------------------------------------------------------------------------------------------

    function test_LpRebatePct_DefaultIs40() public view {
        assertEq(engine.lpRebatePct(), 40);
    }

    function test_SetLpRebatePct_HappyPath_AtMin() public {
        vm.expectEmit(false, false, false, true, address(engine));
        emit IPerpEngine.LpRebatePctSet(40, 25);
        vm.prank(governance);
        engine.setLpRebatePct(25);
        assertEq(engine.lpRebatePct(), 25);
    }

    function test_SetLpRebatePct_HappyPath_AtMax() public {
        vm.prank(governance);
        engine.setLpRebatePct(50);
        assertEq(engine.lpRebatePct(), 50);
    }

    function test_SetLpRebatePct_RevertBelowMin() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.LpRebatePctOutOfRange.selector, uint8(24)));
        engine.setLpRebatePct(24);
    }

    function test_SetLpRebatePct_RevertAboveMax() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.LpRebatePctOutOfRange.selector, uint8(51)));
        engine.setLpRebatePct(51);
    }

    function test_SetLpRebatePct_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.Unauthorized.selector, stranger));
        engine.setLpRebatePct(35);
    }

    function test_FeeSplit_RespectsRebatePct_AtOpen() public {
        vm.prank(governance);
        engine.setLpRebatePct(30);

        uint256 freeBefore = vault.freeAssets();
        uint256 insBefore = vault.insuranceFundBalance();
        uint256 accruedBefore = vault.accruedFees();
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        _open(p);

        uint256 fee = (p.sizeNotional * 750) / 1_000_000;
        uint256 expectedRebate = (fee * 30) / 100;
        uint256 expectedInsurance = (fee * 50) / 100;
        uint256 expectedResidual = fee - expectedRebate - expectedInsurance;

        assertEq(vault.freeAssets() - freeBefore, expectedRebate);
        assertEq(vault.insuranceFundBalance() - insBefore, expectedInsurance);
        assertEq(vault.accruedFees() - accruedBefore, expectedResidual);
    }

    function test_FeeSplit_AtMaxRebate_ResidualIsZero() public {
        vm.prank(governance);
        engine.setLpRebatePct(50);
        uint256 accruedBefore = vault.accruedFees();
        _open(_baseOpenParams());
        // 50 + 50 = 100% — residual is zero
        assertEq(vault.accruedFees(), accruedBefore);
    }

    function test_FeeSplit_AtMinRebate_ResidualIsMaxed() public {
        vm.prank(governance);
        engine.setLpRebatePct(25);
        uint256 accruedBefore = vault.accruedFees();
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        _open(p);
        uint256 fee = (p.sizeNotional * 750) / 1_000_000;
        uint256 expectedResidual = fee - (fee * 25) / 100 - (fee * 50) / 100;
        assertEq(vault.accruedFees() - accruedBefore, expectedResidual);
    }

    function test_FeeSplit_RespectsRebatePct_AtClose() public {
        _open(_baseOpenParams());
        vm.prank(governance);
        engine.setLpRebatePct(35);

        uint256 insBefore = vault.insuranceFundBalance();
        uint256 accruedBefore = vault.accruedFees();
        vm.prank(trader);
        engine.closePosition(_baseCloseParams());

        // Close fee = full notional × taker rate
        uint256 closeNotional = 50_000 * ONE_USDC;
        uint256 fee = (closeNotional * 750) / 1_000_000;
        uint256 expectedRebate = (fee * 35) / 100;
        uint256 expectedInsurance = (fee * 50) / 100;
        uint256 expectedResidual = fee - expectedRebate - expectedInsurance;

        assertEq(vault.insuranceFundBalance() - insBefore, expectedInsurance);
        assertEq(vault.accruedFees() - accruedBefore, expectedResidual);
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function test_UpgradeAuthorization_RevertOnNonGovernance() public {
        PerpEngine newImpl = new PerpEngine();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.Unauthorized.selector, stranger));
        engine.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeAuthorization_GovernanceCanUpgrade() public {
        PerpEngine newImpl = new PerpEngine();
        vm.prank(governance);
        engine.upgradeToAndCall(address(newImpl), "");
        assertEq(engine.governance(), governance);
    }

    // ------------------------------------------------------------------------------------------
    // Tier-1: funding event stub + entryFundingIndex snapshot (Wave 2)
    // ------------------------------------------------------------------------------------------

    function test_Tier1_PushFundingIndex_RevertWhenWriterUnset() public {
        // fundingEngine is `address(0)` at v0 — any caller (including stranger) reverts.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyFundingEngine.selector, stranger));
        engine.pushFundingIndex(SUBJECT_ID, int256(1e18), int256(1e15));
    }

    function _wireFundingEngine(address newEngine) internal {
        vm.prank(governance);
        engine.proposeSetFundingEngine(newEngine);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetFundingEngine();
        // Refresh mark so post-warp staleness doesn't bite downstream calls.
        _pushMarkAt(INITIAL_MARK);
        _pushMarkAt2(INITIAL_MARK);
    }

    function test_Tier1_PushFundingIndex_Happy_AfterRotation() public {
        address fundingWriter = makeAddr("fundingWriter");
        _wireFundingEngine(fundingWriter);
        assertEq(engine.fundingEngine(), fundingWriter);

        vm.expectEmit(true, false, false, true, address(engine));
        emit IPerpEngine.FundingPushed(SUBJECT_ID, 0, int256(1e18), int256(1e15), uint64(block.timestamp));
        vm.prank(fundingWriter);
        engine.pushFundingIndex(SUBJECT_ID, int256(1e18), int256(1e15));

        assertEq(engine.cumulativeFundingIndex(SUBJECT_ID), int256(1e18));
        assertEq(engine.lastFundingAt(SUBJECT_ID), uint64(block.timestamp));
    }

    function test_Tier1_PushFundingIndex_RevertOnPaused() public {
        address fundingWriter = makeAddr("fundingWriter");
        _wireFundingEngine(fundingWriter);

        // Auto-pause the subject — requireTradeable should reject pushFundingIndex.
        vm.prank(regGuardian);
        registry.setAutoPaused(SUBJECT_ID, 5);

        vm.prank(fundingWriter);
        vm.expectRevert();
        engine.pushFundingIndex(SUBJECT_ID, int256(1e18), int256(1e15));
    }

    function test_Tier1_OpenPosition_SnapshotsEntryFundingIndex() public {
        // Write a non-zero cumulative index, then open a position.
        address fundingWriter = makeAddr("fundingWriter");
        _wireFundingEngine(fundingWriter);
        vm.prank(fundingWriter);
        engine.pushFundingIndex(SUBJECT_ID, int256(42e18), int256(0));

        bytes32 posId = _open(_baseOpenParams());
        // Read back the position's entryFundingIndex.
        IPerpEngine.Position memory pos = engine.positionOf(posId);
        assertEq(pos.entryFundingIndex, int256(42e18));
    }

    function test_Tier1_ClosePosition_EmitsFundingSettled() public {
        bytes32 posId = _open(_baseOpenParams());
        vm.expectEmit(true, true, false, true, address(engine));
        emit IPerpEngine.FundingSettled(posId, trader, int256(0));
        vm.prank(trader);
        engine.closePosition(_baseCloseParams());
    }

    function test_Tier1_ProposeSetFundingEngine_Happy() public {
        address w = makeAddr("w");
        vm.prank(governance);
        engine.proposeSetFundingEngine(w);
        (address acct, uint64 activatesAt) = engine.pendingFundingEngine();
        assertEq(acct, w);
        assertEq(activatesAt, uint64(block.timestamp + TIMELOCK_DELAY));
    }

    function test_Tier1_ActivateSetFundingEngine_BeforeTimelock_Reverts() public {
        address w = makeAddr("w");
        vm.prank(governance);
        engine.proposeSetFundingEngine(w);
        vm.expectRevert();
        engine.activateSetFundingEngine();
    }

    function test_Tier1_CancelSetFundingEngine_ClearsPending() public {
        address w = makeAddr("w");
        vm.prank(governance);
        engine.proposeSetFundingEngine(w);
        vm.prank(governance);
        engine.cancelSetFundingEngine();
        (address acct, uint64 activatesAt) = engine.pendingFundingEngine();
        assertEq(acct, address(0));
        assertEq(activatesAt, 0);
    }

    function test_Tier1_ProposeSetFundingEngine_RevertOnZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.proposeSetFundingEngine(address(0));
    }

    function test_Tier1_ProposeSetFundingEngine_RevertWhenPendingExists() public {
        address w1 = makeAddr("w1");
        address w2 = makeAddr("w2");
        vm.prank(governance);
        engine.proposeSetFundingEngine(w1);
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.PendingFundingEngineExists.selector);
        engine.proposeSetFundingEngine(w2);
    }

    // ------------------------------------------------------------------------------------------
    // Tier-1: net-category OI cap (Wave 2)
    // ------------------------------------------------------------------------------------------

    function test_Tier1_CategoryOiCap_DefaultIs20Pct() public view {
        assertEq(marginEngine.categoryNetOiCapBps(), 2_000);
    }

    function test_Tier1_CategoryOiCap_IncrementsOnOpen() public {
        // Long open on SUBJECT_ID (in CATEGORY_ID) → net += sizeNotional.
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        _open(p);
        assertEq(marginEngine.netCategoryOiOf(CATEGORY_ID), int256(p.sizeNotional));
    }

    function test_Tier1_CategoryOiCap_DecrementsOnClose() public {
        _open(_baseOpenParams());
        vm.prank(trader);
        engine.closePosition(_baseCloseParams());
        assertEq(marginEngine.netCategoryOiOf(CATEGORY_ID), int256(0));
    }

    function test_Tier1_CategoryOiCap_RevertOnExceeded() public {
        // Cap default = 20% of TVL. TVL = 1M USDC → cap = 200k.
        // Tighten to 5% (= 50k) so we can hit it with a single 100k position.
        // But MIN_CATEGORY_NET_OI_CAP_BPS = 500 (5%) — exact min works.
        vm.prank(governance);
        marginEngine.setCategoryNetOiCapBps(500); // 5% = 50k cap

        // First trade: 49_900 USDC long — under cap.
        IPerpEngine.OpenParams memory p1 = _baseOpenParams();
        p1.sizeNotional = 49_900 * ONE_USDC;
        p1.collateralAmount = 10_000 * ONE_USDC;
        _open(p1);

        // Second trade on subject 2 (same category): 200 USDC long would tip net over 50k cap.
        // Use trader2 to avoid one-position invariant collision on SUBJECT_ID.
        vm.prank(kycWriter);
        registry.setKycTier(trader2, 2);
        IPerpEngine.OpenParams memory p2 = IPerpEngine.OpenParams({
            subjectId: SUBJECT_ID2,
            side: IPerpEngine.Side.LONG,
            collateralAmount: 1_000 * ONE_USDC,
            sizeNotional: 200 * ONE_USDC,
            expectedMark: INITIAL_MARK,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
        vm.prank(trader2);
        vm.expectRevert();
        engine.openPosition(p2);
    }

    function test_Tier1_SetCategoryNetOiCapBps_Happy() public {
        vm.prank(governance);
        marginEngine.setCategoryNetOiCapBps(3_000); // 30%
        assertEq(marginEngine.categoryNetOiCapBps(), 3_000);
    }

    function test_Tier1_SetCategoryNetOiCapBps_RevertOnTooLow() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.CategoryNetOiCapBpsOutOfRange.selector, uint16(499)));
        marginEngine.setCategoryNetOiCapBps(499);
    }

    function test_Tier1_SetCategoryNetOiCapBps_RevertOnTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.CategoryNetOiCapBpsOutOfRange.selector, uint16(5_001)));
        marginEngine.setCategoryNetOiCapBps(5_001);
    }

    function test_Tier1_SetCategoryNetOiCapBps_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.Unauthorized.selector, stranger));
        marginEngine.setCategoryNetOiCapBps(3_000);
    }

    // ------------------------------------------------------------------------------------------
    // Wave 3B: applyImpulse + FeedbackController rotation
    // ------------------------------------------------------------------------------------------

    function test_ApplyImpulse_RevertWhenFeedbackControllerUnset() public {
        // Default state: no feedbackController configured.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyFeedbackController.selector, stranger));
        engine.applyImpulse(SUBJECT_ID, int256(500));
    }

    function test_ApplyImpulse_ProposeSetFeedbackController_Happy() public {
        address fb = makeAddr("fbController");
        vm.expectEmit(true, false, false, true, address(engine));
        emit IPerpEngine.FeedbackControllerProposed(fb, uint64(block.timestamp + TIMELOCK_DELAY));
        vm.prank(governance);
        engine.proposeSetFeedbackController(fb);
        (address pending, uint64 readyAt) = engine.pendingFeedbackController();
        assertEq(pending, fb);
        assertEq(uint256(readyAt), block.timestamp + TIMELOCK_DELAY);
    }

    function test_ApplyImpulse_ProposeSetFeedbackController_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.proposeSetFeedbackController(address(0));
    }

    function test_ApplyImpulse_ProposeSetFeedbackController_RevertOnExisting() public {
        address fb = makeAddr("fbController");
        vm.prank(governance);
        engine.proposeSetFeedbackController(fb);
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.PendingFeedbackControllerExists.selector);
        engine.proposeSetFeedbackController(fb);
    }

    function test_ApplyImpulse_ActivateSetFeedbackController_Happy() public {
        address fb = makeAddr("fbController");
        vm.prank(governance);
        engine.proposeSetFeedbackController(fb);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, true, false, false, address(engine));
        emit IPerpEngine.FeedbackControllerActivated(address(0), fb);
        engine.activateSetFeedbackController();
        assertEq(engine.feedbackController(), fb);
    }

    function test_ApplyImpulse_ActivateSetFeedbackController_RevertOnNoPending() public {
        vm.expectRevert(IPerpEngine.NoPendingFeedbackController.selector);
        engine.activateSetFeedbackController();
    }

    function test_ApplyImpulse_ActivateSetFeedbackController_RevertOnTimelockNotElapsed() public {
        address fb = makeAddr("fbController");
        vm.prank(governance);
        engine.proposeSetFeedbackController(fb);
        vm.expectRevert(
            abi.encodeWithSelector(IPerpEngine.TimelockNotElapsed.selector, uint64(block.timestamp + TIMELOCK_DELAY))
        );
        engine.activateSetFeedbackController();
    }

    function test_ApplyImpulse_CancelSetFeedbackController_Happy() public {
        address fb = makeAddr("fbController");
        vm.prank(governance);
        engine.proposeSetFeedbackController(fb);
        vm.expectEmit(true, false, false, false, address(engine));
        emit IPerpEngine.FeedbackControllerCancelled(fb);
        vm.prank(governance);
        engine.cancelSetFeedbackController();
        (address pending,) = engine.pendingFeedbackController();
        assertEq(pending, address(0));
    }

    function test_ApplyImpulse_CancelSetFeedbackController_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.NoPendingFeedbackController.selector);
        engine.cancelSetFeedbackController();
    }

    /// @dev Helper: rotate a mock FeedbackController address into engine via the timelocked flow.
    function _activateFeedbackController(address fb) internal {
        vm.prank(governance);
        engine.proposeSetFeedbackController(fb);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetFeedbackController();
    }

    function test_ApplyImpulse_HappyPath_Positive() public {
        address fb = makeAddr("fbController");
        _activateFeedbackController(fb);
        uint256 oldMark = INITIAL_MARK;
        vm.expectEmit(true, false, false, true, address(engine));
        emit IPerpEngine.MarkImpulsed(
            SUBJECT_ID, oldMark, oldMark * 10_500 / 10_000, int256(500), uint64(block.timestamp)
        );
        vm.prank(fb);
        engine.applyImpulse(SUBJECT_ID, int256(500)); // +5%
        (uint256 newMark, uint64 updatedAt) = engine.markOf(SUBJECT_ID);
        assertEq(newMark, oldMark * 10_500 / 10_000);
        assertEq(uint256(updatedAt), block.timestamp);
    }

    function test_ApplyImpulse_NegativeImpulse_LowersMark() public {
        address fb = makeAddr("fbController");
        _activateFeedbackController(fb);
        vm.prank(fb);
        engine.applyImpulse(SUBJECT_ID, -int256(500)); // -5%
        (uint256 newMark,) = engine.markOf(SUBJECT_ID);
        assertEq(newMark, INITIAL_MARK * 9_500 / 10_000);
    }

    function test_ApplyImpulse_RevertOnUnderflow() public {
        address fb = makeAddr("fbController");
        _activateFeedbackController(fb);
        vm.prank(fb);
        vm.expectRevert(IPerpEngine.ImpulseUnderflow.selector);
        engine.applyImpulse(SUBJECT_ID, -int256(10_000)); // multiplier = 0 → newMark = 0
    }

    function test_ApplyImpulse_RevertOnPausedSubject() public {
        address fb = makeAddr("fbController");
        _activateFeedbackController(fb);
        vm.prank(regGuardian);
        registry.setAutoPaused(SUBJECT_ID, 0);
        vm.prank(fb);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.AUTO_PAUSED,
                ISubjectRegistry.SubjectStatus.ACTIVE
            )
        );
        engine.applyImpulse(SUBJECT_ID, int256(500));
    }

    function test_ApplyImpulse_RevertOnUninitializedMark() public {
        address fb = makeAddr("fbController");
        _activateFeedbackController(fb);
        bytes32 fresh = keccak256("freshpe");
        vm.prank(regAdmin);
        registry.listSubject(fresh, CATEGORY_ID);
        vm.prank(fb);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.MarkNotInitialized.selector, fresh));
        engine.applyImpulse(fresh, int256(500));
    }

    function test_ApplyImpulse_RevertOnNonControllerCaller() public {
        address fb = makeAddr("fbController");
        _activateFeedbackController(fb);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyFeedbackController.selector, stranger));
        engine.applyImpulse(SUBJECT_ID, int256(500));
    }

    // ------------------------------------------------------------------------------------------
    // Wave 5B — LiquidationEngine rotation + liquidateClose entrypoint
    // ------------------------------------------------------------------------------------------

    function _activateLiquidationEngine(address le) internal {
        vm.prank(governance);
        engine.proposeSetLiquidationEngine(le);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetLiquidationEngine();
        // Refresh mark so subsequent opens / interactions don't trip MarkStale.
        _pushMarkAt(INITIAL_MARK);
        _pushMarkAt2(INITIAL_MARK);
    }

    function test_ProposeSetLiquidationEngine_HappyPath() public {
        address le = makeAddr("liqEngine");
        vm.prank(governance);
        engine.proposeSetLiquidationEngine(le);
        (address pending, uint64 ts) = engine.pendingLiquidationEngine();
        assertEq(pending, le);
        assertEq(ts, uint64(block.timestamp + TIMELOCK_DELAY));
        assertEq(engine.liquidationEngine(), address(0)); // not yet active
    }

    function test_ProposeSetLiquidationEngine_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.proposeSetLiquidationEngine(address(0));
    }

    function test_ProposeSetLiquidationEngine_RevertOnPending() public {
        address le = makeAddr("liqEngine");
        vm.prank(governance);
        engine.proposeSetLiquidationEngine(le);
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.PendingLiquidationEngineExists.selector);
        engine.proposeSetLiquidationEngine(le);
    }

    function test_ActivateSetLiquidationEngine_HappyPath() public {
        address le = makeAddr("liqEngine");
        _activateLiquidationEngine(le);
        assertEq(engine.liquidationEngine(), le);
        (address pending, uint64 ts) = engine.pendingLiquidationEngine();
        assertEq(pending, address(0));
        assertEq(ts, 0);
    }

    function test_ActivateSetLiquidationEngine_RevertOnNoPending() public {
        vm.expectRevert(IPerpEngine.NoPendingLiquidationEngine.selector);
        engine.activateSetLiquidationEngine();
    }

    function test_ActivateSetLiquidationEngine_RevertOnTimelock() public {
        address le = makeAddr("liqEngine");
        vm.prank(governance);
        engine.proposeSetLiquidationEngine(le);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.TimelockNotElapsed.selector, readyAt));
        engine.activateSetLiquidationEngine();
    }

    function test_CancelSetLiquidationEngine_HappyPath() public {
        address le = makeAddr("liqEngine");
        vm.prank(governance);
        engine.proposeSetLiquidationEngine(le);
        vm.prank(governance);
        engine.cancelSetLiquidationEngine();
        (address pending,) = engine.pendingLiquidationEngine();
        assertEq(pending, address(0));
    }

    function test_CancelSetLiquidationEngine_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.NoPendingLiquidationEngine.selector);
        engine.cancelSetLiquidationEngine();
    }

    function test_LiquidateClose_RevertOnUnsetEngine() public {
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        bytes32 positionId = _open(p);
        // No liquidation engine wired ⇒ reverts at the modifier.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyLiquidationEngine.selector, stranger));
        engine.liquidateClose(positionId, 1, 0, 0, 0, stranger, 1);
    }

    function test_LiquidateClose_RevertOnNonEngineCaller() public {
        address le = makeAddr("liqEngine");
        _activateLiquidationEngine(le);
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        bytes32 positionId = _open(p);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyLiquidationEngine.selector, stranger));
        engine.liquidateClose(positionId, 1, 0, 0, 0, stranger, 1);
    }

    function test_LiquidateClose_HappyFullClose() public {
        address le = makeAddr("liqEngine");
        // We need a real LiquidationEngine address that the vault also accepts. Use the same
        // address; for the purposes of this test, the LiquidationEngine is `le` and we use
        // `vm.prank(le)` to call `liquidateClose`. We also need the LPVault to allow
        // `settleLiquidation` from PerpEngine, which it already does.
        _activateLiquidationEngine(le);

        IPerpEngine.OpenParams memory p = _baseOpenParams();
        bytes32 positionId = _open(p);
        IPerpEngine.Position memory pos = engine.positionOf(positionId);

        // Full close at entry — pnl = 0; trader gets back the collateral minus bounty.
        // Payout-conservation: traderPayout + bounty = collateral + signedPnl
        //                     = $10K + 0 = $10K
        // Choose: bounty = $100, traderPayout = $9,900 → signedPnl = $100 + $9,900 - $10K = 0.
        uint256 bounty = 100 * ONE_USDC;
        uint256 traderPayout = pos.collateral - bounty;

        uint256 traderBalBefore = usdc.balanceOf(trader);
        uint256 liquidatorBalBefore = usdc.balanceOf(le);

        vm.prank(le);
        engine.liquidateClose(positionId, pos.size, traderPayout, bounty, int256(0), le, 2);

        // Position deleted.
        assertEq(engine.positionOf(positionId).size, 0);
        assertEq(engine.positionIdOf(trader, SUBJECT_ID), bytes32(0));

        // OI cleared.
        (uint256 longOI,) = engine.openInterestOf(SUBJECT_ID);
        assertEq(longOI, 0);

        // Trader got back traderPayout, liquidator got bounty.
        assertEq(usdc.balanceOf(trader), traderBalBefore + traderPayout);
        assertEq(usdc.balanceOf(le), liquidatorBalBefore + bounty);
    }

    function test_LiquidateClose_HappyPartialClose() public {
        address le = makeAddr("liqEngine");
        _activateLiquidationEngine(le);

        IPerpEngine.OpenParams memory p = _baseOpenParams();
        bytes32 positionId = _open(p);
        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        int256 halfSize = pos.size / 2;

        // Partial close at entry — pnl on the half-slice = 0; slice collateral = $5K.
        // bounty + traderPayout = sliceCollateral + signedPnl = $5K. Bounty = $50,
        // traderPayout = $4,950, signedPnl = 0.
        uint256 bounty = 50 * ONE_USDC;
        uint256 traderPayout = (pos.collateral / 2) - bounty;

        vm.prank(le);
        engine.liquidateClose(positionId, halfSize, traderPayout, bounty, int256(0), le, 1);

        // Position still open with half the size + half the collateral.
        IPerpEngine.Position memory residual = engine.positionOf(positionId);
        assertEq(residual.size, pos.size - halfSize);
        assertEq(residual.collateral, pos.collateral - (pos.collateral / 2));
    }

    // ------------------------------------------------------------------------------------------
    // Router governance (Wave 7: trusted-router set)
    // ------------------------------------------------------------------------------------------

    function _activateRouter(address router) internal {
        vm.prank(governance);
        engine.proposeAddRouter(router);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateAddRouter(router);
        // Refresh marks — they go stale during the timelock warp.
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, INITIAL_MARK);
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID2, INITIAL_MARK);
    }

    function test_Router_ProposeAddIsTimelocked() public {
        address router = makeAddr("router");
        vm.prank(governance);
        engine.proposeAddRouter(router);
        assertEq(engine.pendingRouterActivatesAt(router), uint64(block.timestamp + TIMELOCK_DELAY));
        assertFalse(engine.isRouter(router));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateAddRouter(router);
        assertTrue(engine.isRouter(router));
        assertEq(engine.pendingRouterActivatesAt(router), 0);
    }

    function test_Router_RemoveIsImmediate() public {
        address router = makeAddr("router");
        _activateRouter(router);
        assertTrue(engine.isRouter(router));

        vm.prank(governance);
        engine.removeRouter(router);
        assertFalse(engine.isRouter(router));
    }

    function test_Router_ProposeRevertsOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.Unauthorized.selector, stranger));
        engine.proposeAddRouter(makeAddr("router"));
    }

    function test_Router_ProposeRevertsOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.proposeAddRouter(address(0));
    }

    function test_Router_ProposeRevertsOnAlreadySet() public {
        address router = makeAddr("router");
        _activateRouter(router);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.RouterAlreadySet.selector, router));
        engine.proposeAddRouter(router);
    }

    function test_Router_ProposeRevertsOnPendingExists() public {
        address router = makeAddr("router");
        vm.startPrank(governance);
        engine.proposeAddRouter(router);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.PendingRouterExists.selector, router));
        engine.proposeAddRouter(router);
        vm.stopPrank();
    }

    function test_Router_ActivateRevertsOnNoPending() public {
        address router = makeAddr("router");
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.NoPendingRouter.selector, router));
        engine.activateAddRouter(router);
    }

    function test_Router_ActivateRevertsOnTimelockNotElapsed() public {
        address router = makeAddr("router");
        vm.prank(governance);
        engine.proposeAddRouter(router);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.TimelockNotElapsed.selector, readyAt));
        engine.activateAddRouter(router);
    }

    function test_Router_CancelHappyPath() public {
        address router = makeAddr("router");
        vm.prank(governance);
        engine.proposeAddRouter(router);

        vm.prank(governance);
        engine.cancelAddRouter(router);
        assertEq(engine.pendingRouterActivatesAt(router), 0);
        assertFalse(engine.isRouter(router));
    }

    function test_Router_CancelRevertsOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.NoPendingRouter.selector, stranger));
        engine.cancelAddRouter(stranger);
    }

    function test_Router_RemoveRevertsOnNonGovernance() public {
        address router = makeAddr("router");
        _activateRouter(router);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.Unauthorized.selector, stranger));
        engine.removeRouter(router);
    }

    function test_Router_RemoveRevertsOnNotSet() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.RouterNotSet.selector, stranger));
        engine.removeRouter(stranger);
    }

    // ------------------------------------------------------------------------------------------
    // openPositionFor — onlyRouter + behavioural parity with openPosition
    // ------------------------------------------------------------------------------------------

    function test_OpenPositionFor_RevertsOnNonRouter() public {
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyRouter.selector, stranger));
        engine.openPositionFor(trader, p);
    }

    function test_OpenPositionFor_HappyPathLong() public {
        address router = makeAddr("router");
        _activateRouter(router);

        IPerpEngine.OpenParams memory p = _baseOpenParams();
        vm.prank(router);
        bytes32 positionId = engine.openPositionFor(trader, p);

        // Trader owns the position even though the router was msg.sender.
        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertEq(pos.owner, trader);
        assertGt(pos.size, 0);
        assertEq(pos.collateral, p.collateralAmount);
        assertEq(engine.positionIdOf(trader, SUBJECT_ID), positionId);
    }

    function test_OpenPositionFor_HappyPathShort() public {
        address router = makeAddr("router");
        _activateRouter(router);

        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.side = IPerpEngine.Side.SHORT;
        vm.prank(router);
        bytes32 positionId = engine.openPositionFor(trader, p);
        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertLt(pos.size, 0);
        assertEq(pos.owner, trader);
    }

    function test_OpenPositionFor_RevertsOnZeroTrader() public {
        address router = makeAddr("router");
        _activateRouter(router);
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        vm.prank(router);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.openPositionFor(address(0), p);
    }

    function test_OpenPositionFor_FundsComeFromTrader() public {
        // The collateral + fee MUST be pulled from the trader (not the router). Verify by
        // checking the trader's USDC balance drops by collateral + fee.
        address router = makeAddr("router");
        _activateRouter(router);

        IPerpEngine.OpenParams memory p = _baseOpenParams();
        uint256 fee = (p.sizeNotional * 750) / 1_000_000;
        uint256 traderBalBefore = usdc.balanceOf(trader);
        uint256 routerBalBefore = usdc.balanceOf(router);

        vm.prank(router);
        engine.openPositionFor(trader, p);

        assertEq(usdc.balanceOf(trader), traderBalBefore - p.collateralAmount - fee);
        // Router balance unchanged — it never touches funds.
        assertEq(usdc.balanceOf(router), routerBalBefore);
    }

    function test_OpenPositionFor_UsesTraderKycTier() public {
        // The KYC tier check applies to `trader`, not `msg.sender`. The router doesn't need a
        // KYC tier; the trader does. Verify by stripping the router's KYC tier (it never had
        // one) and confirming the call still succeeds — and reverts when the *trader* loses KYC.
        address router = makeAddr("router");
        _activateRouter(router);

        IPerpEngine.OpenParams memory p = _baseOpenParams();
        // Strip the trader's KYC tier — call MUST revert with KycTierMissing(trader).
        vm.prank(kycWriter);
        registry.setKycTier(trader, 0);

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.KycTierMissing.selector, trader));
        engine.openPositionFor(trader, p);
    }

    function test_OpenPositionFor_RevertsAfterRouterRemoved() public {
        address router = makeAddr("router");
        _activateRouter(router);
        vm.prank(governance);
        engine.removeRouter(router);

        IPerpEngine.OpenParams memory p = _baseOpenParams();
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyRouter.selector, router));
        engine.openPositionFor(trader, p);
    }

    // ------------------------------------------------------------------------------------------
    // closePositionFor — onlyRouter + behavioural parity with closePosition (Wave 6C)
    // ------------------------------------------------------------------------------------------

    function test_ClosePositionFor_RevertsOnNonRouter() public {
        IPerpEngine.CloseParams memory cp = _baseCloseParams();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyRouter.selector, stranger));
        engine.closePositionFor(trader, cp);
    }

    function test_ClosePositionFor_HappyPath_FullClose() public {
        // Seed: open via the router so trader owns a position the router can close.
        address router = makeAddr("router");
        _activateRouter(router);

        IPerpEngine.OpenParams memory p = _baseOpenParams();
        vm.prank(router);
        bytes32 positionId = engine.openPositionFor(trader, p);

        // Close via the router. Mark unchanged → realized PnL is 0.
        IPerpEngine.CloseParams memory cp = _baseCloseParams();
        vm.prank(router);
        int256 pnl = engine.closePositionFor(trader, cp);

        assertEq(pnl, int256(0));
        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertEq(pos.size, 0);
        assertEq(engine.positionIdOf(trader, SUBJECT_ID), bytes32(0));
    }

    function test_ClosePositionFor_HappyPath_PartialClose() public {
        address router = makeAddr("router");
        _activateRouter(router);

        IPerpEngine.OpenParams memory p = _baseOpenParams();
        vm.prank(router);
        bytes32 positionId = engine.openPositionFor(trader, p);

        IPerpEngine.CloseParams memory cp = _baseCloseParams();
        cp.sizeFractionBps = 5_000; // 50% partial
        vm.prank(router);
        engine.closePositionFor(trader, cp);

        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertEq(pos.collateral, p.collateralAmount / 2);
    }

    function test_ClosePositionFor_RevertsAfterRouterRemoved() public {
        address router = makeAddr("router");
        _activateRouter(router);
        // Seed a position for the trader.
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        vm.prank(router);
        engine.openPositionFor(trader, p);

        vm.prank(governance);
        engine.removeRouter(router);

        IPerpEngine.CloseParams memory cp = _baseCloseParams();
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyRouter.selector, router));
        engine.closePositionFor(trader, cp);
    }

    function test_ClosePositionFor_RevertsOnNoPosition() public {
        address router = makeAddr("router");
        _activateRouter(router);

        IPerpEngine.CloseParams memory cp = _baseCloseParams();
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.PositionNotOpen.selector, SUBJECT_ID));
        engine.closePositionFor(trader, cp);
    }

    // ------------------------------------------------------------------------------------------
    // addCollateralFor / removeCollateralFor — onlyRouter + happy paths (Wave 6C)
    // ------------------------------------------------------------------------------------------

    function test_AddCollateralFor_RevertsOnNonRouter() public {
        bytes32 positionId = _open(_baseOpenParams());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyRouter.selector, stranger));
        engine.addCollateralFor(trader, positionId, 1_000 * ONE_USDC);
    }

    function test_AddCollateralFor_HappyPath() public {
        address router = makeAddr("router");
        _activateRouter(router);
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        vm.prank(router);
        bytes32 positionId = engine.openPositionFor(trader, p);

        vm.prank(router);
        engine.addCollateralFor(trader, positionId, 5_000 * ONE_USDC);

        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertEq(pos.collateral, 15_000 * ONE_USDC);
    }

    function test_AddCollateralFor_RevertsOnTraderNotOwner() public {
        // A position owned by `trader` cannot be topped up under a different trader address.
        address router = makeAddr("router");
        _activateRouter(router);
        bytes32 positionId = _open(_baseOpenParams());

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.PositionNotOpen.selector, SUBJECT_ID));
        engine.addCollateralFor(trader2, positionId, 1_000 * ONE_USDC);
    }

    function test_RemoveCollateralFor_RevertsOnNonRouter() public {
        bytes32 positionId = _open(_baseOpenParams());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyRouter.selector, stranger));
        engine.removeCollateralFor(trader, positionId, 1_000 * ONE_USDC);
    }

    function test_RemoveCollateralFor_HappyPath() public {
        address router = makeAddr("router");
        _activateRouter(router);

        // Open with extra collateral so we can pull some without breaking IM.
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.collateralAmount = 20_000 * ONE_USDC;
        vm.prank(router);
        bytes32 positionId = engine.openPositionFor(trader, p);

        uint256 traderBefore = usdc.balanceOf(trader);
        vm.prank(router);
        engine.removeCollateralFor(trader, positionId, 9_000 * ONE_USDC);

        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertEq(pos.collateral, 11_000 * ONE_USDC);
        assertEq(usdc.balanceOf(trader) - traderBefore, 9_000 * ONE_USDC);
    }

    function test_RemoveCollateralFor_RevertsOnTraderNotOwner() public {
        address router = makeAddr("router");
        _activateRouter(router);
        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.collateralAmount = 20_000 * ONE_USDC;
        bytes32 positionId = _open(p);

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.PositionNotOpen.selector, SUBJECT_ID));
        engine.removeCollateralFor(trader2, positionId, 1_000 * ONE_USDC);
    }
}
