// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {ILPVault} from "../src/core/ILPVault.sol";
import {IPerpEngine} from "../src/core/IPerpEngine.sol";
import {LPVault} from "../src/core/LPVault.sol";
import {PerpEngine} from "../src/core/PerpEngine.sol";

import {ISubjectRegistry} from "../src/registry/ISubjectRegistry.sol";
import {SubjectRegistry} from "../src/registry/SubjectRegistry.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PerpEngineTest is Test {
    PerpEngine internal engine;
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

        // 4. Wire LPVault.setPerpEngine to the engine address (timelocked).
        vm.prank(governance);
        vault.proposeSetPerpEngine(address(engine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateSetPerpEngine();

        // 5. Configure SubjectRegistry: list subjects, set KYC tiers.
        vm.startPrank(regAdmin);
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);
        registry.listSubject(SUBJECT_ID2, CATEGORY_ID);
        vm.stopPrank();
        vm.startPrank(kycWriter);
        registry.setKycTier(trader, 2); // T2 → $250K per-subject, $1M combined
        registry.setKycTier(trader2, 1); // T1 → $50K per-subject, $200K combined
        vm.stopPrank();

        // 6. Configure PerpEngine: KYC caps + mark writer.
        vm.startPrank(governance);
        engine.setKycCaps(1, 50_000 * ONE_USDC, 200_000 * ONE_USDC);
        engine.setKycCaps(2, 250_000 * ONE_USDC, 1_000_000 * ONE_USDC);
        engine.setKycCaps(3, 1_000_000 * ONE_USDC, 4_000_000 * ONE_USDC);
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

    // ------------------------------------------------------------------------------------------
    // initialize
    // ------------------------------------------------------------------------------------------

    function test_Initialize_StoresParams() public view {
        assertEq(engine.governance(), governance);
        assertEq(engine.timelockDelay(), TIMELOCK_DELAY);
        assertEq(engine.subjectRegistry(), address(registry));
        assertEq(engine.lpVault(), address(vault));
        assertEq(engine.markStaleAfter(), 30 seconds);
        (uint16 imBps, uint16 mmBps,, uint16 maxLevBps,) = engine.marginParams();
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
        engine.pushMark(SUBJECT_ID, 200 * ONE_18);
        (uint256 priceA,) = engine.markOf(SUBJECT_ID);
        (uint256 priceB,) = engine.markOf(SUBJECT_ID2);
        assertEq(priceA, 200 * ONE_18);
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
        engine.setMarginParams(3_000, 500, 250, 50_000);

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

        IPerpEngine.OpenParams memory p = _baseOpenParams();
        p.sizeNotional = 60_000 * ONE_USDC; // > $50K per-trader-subject cap
        p.collateralAmount = 12_000 * ONE_USDC;

        vm.prank(trader2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPerpEngine.PerTraderSubjectCapExceeded.selector,
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
        engine.setMarginParams(3_000, 500, 250, 50_000);

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

        // Now lift the trader's combined cap to $300K so we can hit it on the second open.
        vm.prank(governance);
        engine.setKycCaps(2, 250_000 * ONE_USDC, 300_000 * ONE_USDC);

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
        engine.setMarginParams(2_500, 600, 300, 40_000);
        (uint16 im, uint16 mm, uint16 buf, uint16 lev,) = engine.marginParams();
        assertEq(im, 2_500);
        assertEq(mm, 600);
        assertEq(buf, 300);
        assertEq(lev, 40_000);
    }

    function test_SetMarginParams_RevertOnInvalidImBps() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setMarginParams(0, 500, 250, 50_000);

        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setMarginParams(10_001, 500, 250, 50_000);
    }

    function test_SetMarginParams_RevertOnMmGteIm() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setMarginParams(2_000, 2_000, 250, 50_000);
    }

    function test_SetMarginParams_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.Unauthorized.selector, stranger));
        engine.setMarginParams(2_000, 500, 250, 50_000);
    }

    function test_SetMarginParams_RevertOnInvalidMm() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setMarginParams(2_000, 0, 250, 50_000);

        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setMarginParams(2_000, 5_001, 250, 50_000);
    }

    function test_SetMarginParams_RevertOnInvalidBuf() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setMarginParams(2_000, 500, 2_001, 50_000);
    }

    function test_SetMarginParams_RevertOnInvalidLev() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setMarginParams(2_000, 500, 250, 0);

        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setMarginParams(2_000, 500, 250, 60_001);
    }

    function test_SetKycCaps_HappyPath() public {
        vm.prank(governance);
        engine.setKycCaps(1, 100_000 * ONE_USDC, 400_000 * ONE_USDC);
        (uint256 perSubject, uint256 combined) = engine.tierCaps(1);
        assertEq(perSubject, 100_000 * ONE_USDC);
        assertEq(combined, 400_000 * ONE_USDC);
    }

    function test_SetKycCaps_RevertOnInvalidTier() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.KycTierInvalid.selector, uint8(0)));
        engine.setKycCaps(0, 100, 200);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.KycTierInvalid.selector, uint8(4)));
        engine.setKycCaps(4, 100, 200);
    }

    function test_SetKycCaps_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setKycCaps(1, 0, 100);

        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setKycCaps(1, 100, 0);
    }

    function test_SetKycCaps_RevertOnCombinedLessThanPerSubject() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setKycCaps(1, 200, 100);
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
        engine.setPerSubjectSideOiCapBps(1_000); // 10%
        (,,,, uint16 cap) = engine.marginParams();
        assertEq(cap, 1_000);
    }

    function test_SetPerSubjectSideOiCapBps_RevertOnOutOfRange() public {
        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setPerSubjectSideOiCapBps(0);

        vm.prank(governance);
        vm.expectRevert(IPerpEngine.InvalidConfig.selector);
        engine.setPerSubjectSideOiCapBps(5_001);
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
        assertTrue(engine.isMarginOk(positionId));
    }

    function test_Views_ZeroSizePositionReturnsDefaults() public view {
        bytes32 unknown = bytes32(0);
        assertEq(engine.equityOf(unknown), 0);
        assertEq(engine.marginRatioBpsOf(unknown), 0);
        assertEq(engine.leverageBpsOf(unknown), 0);
        assertTrue(engine.isMarginOk(unknown)); // empty position is "OK"
    }

    function test_Views_ExposureOf() public {
        _open(_baseOpenParams());
        (uint256 totalPerp, uint256 totalEvent, uint8 tier) = engine.exposureOf(trader);
        assertEq(totalPerp, 50_000 * ONE_USDC);
        assertEq(totalEvent, 0);
        assertEq(tier, 2);
    }

    function test_Views_TierCaps() public view {
        (uint256 perS, uint256 combined) = engine.tierCaps(2);
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
}
