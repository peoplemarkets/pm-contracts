// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {IPerpEngine} from "../src/core/IPerpEngine.sol";
import {LPVault} from "../src/core/LPVault.sol";
import {MarginEngine} from "../src/core/MarginEngine.sol";
import {PerpEngine} from "../src/core/PerpEngine.sol";
import {SubjectRegistry} from "../src/registry/SubjectRegistry.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title  PerpEngine funding-settlement integration tests.
/// @notice Self-contained deployment (registry + margin engine + vault + mark writer + funding
///         writer) exercising the Tier-1 funding-debt settlement wired into `closePosition` and
///         `closeAtForcedSettlement`. The cumulative quote funding index is driven directly via
///         `pushFundingQuoteIndex` (a real FundingEngine is not needed to test consumption).
///
/// @dev    Base position: collateral $10K, notional $50K, mark $100 ⇒ signed size = +500e6 (long).
///         At 0.1%/h, one hour accrues $0.10/base and therefore $50 of funding debt.
contract PerpEngineFundingTest is Test {
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
    address internal fundingWriter = makeAddr("fundingWriter");

    address internal alice = makeAddr("alice"); // LP
    address internal trader = makeAddr("trader");

    bytes32 internal constant SUBJECT_ID = keccak256("drake");
    bytes32 internal constant CATEGORY_ID = keccak256("musician");

    uint32 internal constant TIMELOCK_DELAY = 2 days;
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant USDC_1M = 1_000_000 * ONE_USDC;
    uint256 internal constant USDC_10M = 10 * USDC_1M;
    uint256 internal constant ONE_18 = 1e18;
    uint256 internal constant INITIAL_MARK = 100 * ONE_18; // $100 / Drake
    int256 internal constant RATE_10_BPS = 1e15; // 0.1% per hour

    uint256 internal constant TAKER_FEE = 37_500_000; // $50K notional × 0.075% = $37.50

    function setUp() public {
        vm.warp(2_000_000_000);
        usdc = new MockUSDC();

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
        {
            LPVault impl = new LPVault();
            bytes memory initData = abi.encodeCall(
                LPVault.initialize,
                (IERC20(address(usdc)), governance, vaultOperator, TIMELOCK_DELAY, "People Markets LP USDC", "pmUSDC")
            );
            vault = LPVault(address(new ERC1967Proxy(address(impl), initData)));
        }
        {
            PerpEngine impl = new PerpEngine();
            bytes memory initData =
                abi.encodeCall(PerpEngine.initialize, (governance, TIMELOCK_DELAY, address(registry), address(vault)));
            engine = PerpEngine(address(new ERC1967Proxy(address(impl), initData)));
        }
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

        // Funding-engine writer rotation (timelocked).
        vm.prank(governance);
        engine.proposeSetFundingEngine(fundingWriter);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetFundingEngine();

        vm.prank(regAdmin);
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);
        vm.prank(kycWriter);
        registry.setKycTier(trader, 2);

        vm.startPrank(governance);
        marginEngine.setKycCaps(2, 250_000 * ONE_USDC, 1_000_000 * ONE_USDC);
        engine.setMarkMaxDeltaBps(5_000);
        engine.proposeAddMarkWriter(markWriter);
        vm.stopPrank();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateAddMarkWriter(markWriter);

        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, INITIAL_MARK);

        usdc.mint(alice, USDC_10M);
        usdc.mint(trader, USDC_1M);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(alice);
        vault.deposit(USDC_1M, alice);
        engine.pokeCappedTvl();
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _openParams(IPerpEngine.Side side) internal view returns (IPerpEngine.OpenParams memory p) {
        p = IPerpEngine.OpenParams({
            subjectId: SUBJECT_ID,
            side: side,
            collateralAmount: 10_000 * ONE_USDC,
            sizeNotional: 50_000 * ONE_USDC,
            expectedMark: INITIAL_MARK,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
    }

    function _closeParams() internal view returns (IPerpEngine.CloseParams memory p) {
        p = IPerpEngine.CloseParams({
            subjectId: SUBJECT_ID,
            sizeFractionBps: 10_000,
            expectedMark: INITIAL_MARK,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
    }

    function _open(IPerpEngine.Side side) internal returns (bytes32) {
        vm.prank(trader);
        return engine.openPosition(_openParams(side));
    }

    function _seedQuoteFunding() internal {
        if (engine.lastQuoteFundingAt(SUBJECT_ID) != 0) return;
        vm.prank(fundingWriter);
        engine.pushFundingQuoteIndex(SUBJECT_ID, 0, 0, INITIAL_MARK);
    }

    function _accrueQuoteFunding(int256 rate1e18, uint64 elapsed) internal returns (int256 newIndex) {
        _seedQuoteFunding();
        vm.warp(block.timestamp + elapsed);
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, INITIAL_MARK);

        int256 current = engine.cumulativeFundingQuoteIndex(SUBJECT_ID);
        int256 delta = (rate1e18 * int256(INITIAL_MARK) * int256(uint256(elapsed))) / int256(ONE_18 * 3600);
        newIndex = current + delta;
        vm.prank(fundingWriter);
        engine.pushFundingQuoteIndex(SUBJECT_ID, newIndex, rate1e18, INITIAL_MARK);
    }

    function _delist() internal {
        vm.prank(regAdmin);
        registry.involuntaryDelist(SUBJECT_ID);
    }

    // ------------------------------------------------------------------------------------------
    // Long pays / short receives
    // ------------------------------------------------------------------------------------------

    function test_Funding_LongPaysOnPositiveGrowth() public {
        bytes32 positionId = _open(IPerpEngine.Side.LONG);
        _accrueQuoteFunding(RATE_10_BPS, 1 hours);

        uint256 balBefore = usdc.balanceOf(trader);
        vm.expectEmit(true, true, false, true, address(engine));
        emit IPerpEngine.FundingSettled(positionId, trader, int256(50e6));
        vm.prank(trader);
        engine.closePosition(_closeParams());

        // collateral − funding − fee (mark unchanged ⇒ zero trading PnL).
        assertEq(usdc.balanceOf(trader) - balBefore, 10_000e6 - 50e6 - TAKER_FEE);
    }

    function test_Funding_ShortReceivesOnPositiveGrowth() public {
        bytes32 positionId = _open(IPerpEngine.Side.SHORT);
        _accrueQuoteFunding(RATE_10_BPS, 1 hours);

        uint256 balBefore = usdc.balanceOf(trader);
        vm.expectEmit(true, true, false, true, address(engine));
        emit IPerpEngine.FundingSettled(positionId, trader, -int256(50e6));
        vm.prank(trader);
        engine.closePosition(_closeParams());

        assertEq(usdc.balanceOf(trader) - balBefore, 10_000e6 + 50e6 - TAKER_FEE);
    }

    function test_Funding_LongReceivesOnNegativeGrowth() public {
        bytes32 positionId = _open(IPerpEngine.Side.LONG);
        _accrueQuoteFunding(-RATE_10_BPS, 1 hours);

        uint256 balBefore = usdc.balanceOf(trader);
        vm.expectEmit(true, true, false, true, address(engine));
        emit IPerpEngine.FundingSettled(positionId, trader, -int256(50e6));
        vm.prank(trader);
        engine.closePosition(_closeParams());

        assertEq(usdc.balanceOf(trader) - balBefore, 10_000e6 + 50e6 - TAKER_FEE);
    }

    // ------------------------------------------------------------------------------------------
    // Entry-index snapshot semantics
    // ------------------------------------------------------------------------------------------

    function test_Funding_OnlyChargesGrowthAfterEntry() public {
        _accrueQuoteFunding(RATE_10_BPS, 1 hours); // pre-entry funding is not charged
        bytes32 positionId = _open(IPerpEngine.Side.LONG);
        _accrueQuoteFunding(RATE_10_BPS, 1 hours);
        _accrueQuoteFunding(RATE_10_BPS, 1 hours); // post-entry delta $0.20/base ⇒ $100

        vm.expectEmit(true, true, false, true, address(engine));
        emit IPerpEngine.FundingSettled(positionId, trader, int256(100e6));
        vm.prank(trader);
        engine.closePosition(_closeParams());
    }

    function test_Funding_ZeroWhenIndexUnchanged() public {
        bytes32 positionId = _open(IPerpEngine.Side.LONG);
        vm.expectEmit(true, true, false, true, address(engine));
        emit IPerpEngine.FundingSettled(positionId, trader, int256(0));
        vm.prank(trader);
        engine.closePosition(_closeParams());
    }

    // ------------------------------------------------------------------------------------------
    // Partial close settles funding on the slice only
    // ------------------------------------------------------------------------------------------

    function test_Funding_PartialClosesSliceThenResidual() public {
        bytes32 positionId = _open(IPerpEngine.Side.LONG);
        _accrueQuoteFunding(RATE_10_BPS, 1 hours);

        IPerpEngine.CloseParams memory cp = _closeParams();
        cp.sizeFractionBps = 5_000; // 50% ⇒ 250 bases × $0.10 = $25
        vm.expectEmit(true, true, false, true, address(engine));
        emit IPerpEngine.FundingSettled(positionId, trader, int256(25e6));
        vm.prank(trader);
        engine.closePosition(cp);

        // Residual keeps its original entry. Two more hours bring cumulative quote funding to
        // $0.30/base, so the remaining 250 bases owe $75.
        _accrueQuoteFunding(RATE_10_BPS, 2 hours);
        cp.sizeFractionBps = 10_000;
        cp.deadline = uint64(block.timestamp + 1 hours);
        vm.expectEmit(true, true, false, true, address(engine));
        emit IPerpEngine.FundingSettled(positionId, trader, int256(75e6));
        vm.prank(trader);
        engine.closePosition(cp);
    }

    // ------------------------------------------------------------------------------------------
    // Underwater-by-funding guard
    // ------------------------------------------------------------------------------------------

    function test_Funding_UnderwaterByFundingReverts() public {
        _open(IPerpEngine.Side.LONG);
        // 30%/h at $100 accrues $30/base: 500 bases owe $15K, beyond posted collateral.
        _accrueQuoteFunding(0.3e18, 1 hours);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.UnderwaterClose.selector, -int256(5_037_500_000)));
        engine.closePosition(_closeParams());
    }

    // ------------------------------------------------------------------------------------------
    // Funding at forced settlement
    // ------------------------------------------------------------------------------------------

    function test_Funding_ForcedSettlementChargesFunding() public {
        bytes32 positionId = _open(IPerpEngine.Side.LONG);
        _accrueQuoteFunding(RATE_10_BPS, 1 hours);

        _delist();
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, INITIAL_MARK);

        uint256 balBefore = usdc.balanceOf(trader);
        vm.expectEmit(true, true, false, true, address(engine));
        emit IPerpEngine.FundingSettled(positionId, trader, int256(50e6));
        vm.prank(trader);
        engine.closeAtForcedSettlement(SUBJECT_ID);

        // collateral − funding (zero fee, captured mark == entry ⇒ zero trading PnL).
        assertEq(usdc.balanceOf(trader) - balBefore, 10_000e6 - 50e6);
    }

    // ------------------------------------------------------------------------------------------
    // Upgrade compatibility and writer validation
    // ------------------------------------------------------------------------------------------

    function test_Funding_LegacyIndexIsPreservedButNeverReinterpreted() public {
        vm.prank(fundingWriter);
        engine.pushFundingIndex(SUBJECT_ID, 1e15, 0);

        bytes32 positionId = _open(IPerpEngine.Side.LONG);
        assertEq(engine.positionOf(positionId).entryFundingIndex, 1e15);
        assertEq(engine.positionFundingQuoteIndex(positionId), 0);

        _accrueQuoteFunding(RATE_10_BPS, 1 hours);
        assertEq(engine.cumulativeFundingIndex(SUBJECT_ID), 1e15);
        assertEq(engine.fundingDebtOf(positionId), 50e6);

        vm.expectEmit(true, true, false, true, address(engine));
        emit IPerpEngine.FundingSettled(positionId, trader, int256(50e6));
        vm.prank(trader);
        engine.closePosition(_closeParams());
    }

    function test_Funding_QuoteSeedRejectsNonZeroIndex() public {
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.QuoteFundingMustSeedAtZero.selector, int256(1)));
        vm.prank(fundingWriter);
        engine.pushFundingQuoteIndex(SUBJECT_ID, 1, 0, INITIAL_MARK);
    }

    function test_Funding_QuoteSeedRejectsNonZeroRate() public {
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.QuoteFundingSeedRateNotZero.selector, RATE_10_BPS));
        vm.prank(fundingWriter);
        engine.pushFundingQuoteIndex(SUBJECT_ID, 0, RATE_10_BPS, INITIAL_MARK);
    }

    function test_Funding_QuotePushRejectsMarkMismatch() public {
        vm.expectRevert(
            abi.encodeWithSelector(IPerpEngine.FundingMarkMismatch.selector, INITIAL_MARK, INITIAL_MARK + 1)
        );
        vm.prank(fundingWriter);
        engine.pushFundingQuoteIndex(SUBJECT_ID, 0, 0, INITIAL_MARK + 1);
    }

    function test_Funding_QuotePushRejectsIncorrectIndex() public {
        _seedQuoteFunding();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, INITIAL_MARK);

        int256 expected = 0.1e18;
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.InvalidFundingQuoteIndex.selector, expected, expected + 1));
        vm.prank(fundingWriter);
        engine.pushFundingQuoteIndex(SUBJECT_ID, expected + 1, RATE_10_BPS, INITIAL_MARK);
    }

    function test_Funding_LegacyWriterFailsClosedAfterQuoteActivation() public {
        _seedQuoteFunding();
        vm.expectRevert(IPerpEngine.LegacyFundingIndexDisabled.selector);
        vm.prank(fundingWriter);
        engine.pushFundingIndex(SUBJECT_ID, 1, 0);
    }

    function test_Funding_DebtFlowsIntoRiskViewsAndCollateralRemoval() public {
        bytes32 positionId = _open(IPerpEngine.Side.LONG);
        _accrueQuoteFunding(0.2e18, 1 hours); // $20/base × 500 = $10K debt

        assertEq(engine.fundingDebtOf(positionId), 10_000e6);
        assertEq(engine.equityOf(positionId), 0);
        assertEq(engine.marginRatioBpsOf(positionId), 0);
        assertFalse(marginEngine.isMarginOk(positionId));

        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.MaintenanceMarginShort.selector, 0, 0));
        vm.prank(trader);
        engine.removeCollateral(SUBJECT_ID, ONE_USDC);
    }
}
