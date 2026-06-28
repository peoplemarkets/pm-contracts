// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ILPVault} from "../../src/core/ILPVault.sol";
import {EventMarket} from "../../src/events/EventMarket.sol";
import {EventMarketFactory} from "../../src/events/EventMarketFactory.sol";
import {EventMarketRouter} from "../../src/events/EventMarketRouter.sol";
import {IEventMarket} from "../../src/events/IEventMarket.sol";
import {IEventMarketRouter} from "../../src/events/IEventMarketRouter.sol";
import {LMSRMath} from "../../src/events/LMSRMath.sol";
import {IFeedbackController} from "../../src/feedback/IFeedbackController.sol";
import {UMAAdapter} from "../../src/oracle/UMAAdapter.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockFeedbackController, MockLPVault, MockUMAAdapter, ReentrantToken} from "./mocks/MockEventDeps.sol";

/// @title EventMarket + EventMarketRouter test suite (WS-1).
/// @notice Covers market creation, direct buy/sell, LMSR pricing sanity, resolve/redeem (YES/NO/
///         VOID), the engine-relayed operator path (credit-the-trader invariant, USDC custody),
///         two-layer access control, slippage, closed/resolved reverts, and reentrancy.
contract EventMarketTest is Test {
    EventMarketFactory internal factory;
    EventMarketRouter internal router;
    MockUSDC internal usdc;
    MockLPVault internal lpVault;
    MockFeedbackController internal feedback;
    MockUMAAdapter internal uma;

    address internal governance = makeAddr("governance");
    address internal operatorKey = makeAddr("operatorKey"); // engine KMS key
    address internal alice = makeAddr("alice"); // trader
    address internal bob = makeAddr("bob"); // trader
    address internal stranger = makeAddr("stranger");

    uint32 internal constant TIMELOCK = 1 days;
    uint256 internal constant LMSR_B = 10_000e6;
    uint64 internal constant DEADLINE = 2_000_000_000;

    bytes32 internal constant SUBJECT_ID = keccak256("subject.drake");
    bytes32 internal constant EVENT_ID = keccak256("event.drake.grammy");

    function setUp() public {
        vm.warp(1_900_000_000);

        usdc = new MockUSDC();
        lpVault = new MockLPVault(IERC20(address(usdc)));
        feedback = new MockFeedbackController();
        uma = new MockUMAAdapter();

        // Fund the LPVault so it can seed markets.
        usdc.mint(address(lpVault), 10_000_000e6);

        // Factory behind a UUPS proxy.
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

        // Router behind a UUPS proxy.
        EventMarketRouter routerImpl = new EventMarketRouter();
        bytes memory rInit =
            abi.encodeCall(EventMarketRouter.initialize, (governance, address(factory), address(usdc), TIMELOCK));
        router = EventMarketRouter(address(new ERC1967Proxy(address(routerImpl), rInit)));

        // Register the router as an operator on the factory (layer i) — timelocked add.
        vm.prank(governance);
        factory.proposeAddOperator(address(router));
        vm.warp(block.timestamp + TIMELOCK);
        factory.activateAddOperator(address(router));

        // Register the engine key as an operator on the router (layer ii) — timelocked add.
        vm.prank(governance);
        router.proposeAddOperator(operatorKey);
        vm.warp(block.timestamp + TIMELOCK);
        router.activateAddOperator(operatorKey);

        // Fund traders.
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _createMarket(bytes32 eventId) internal returns (EventMarket m) {
        vm.prank(governance);
        address addr = factory.createMarket(SUBJECT_ID, eventId, uint8(1), "Will Drake win?", DEADLINE, 0, LMSR_B);
        m = EventMarket(addr);
    }

    function _defaultMarket() internal returns (EventMarket m) {
        return _createMarket(EVENT_ID);
    }

    // ------------------------------------------------------------------------------------------
    // Market creation
    // ------------------------------------------------------------------------------------------

    function test_createMarket_seedsAndRegisters() public {
        EventMarket m = _defaultMarket();
        uint256 expectedSeed = LMSRMath.cost(0, 0, LMSR_B);
        assertEq(usdc.balanceOf(address(m)), expectedSeed, "seed escrow");
        assertEq(factory.getMarket(EVENT_ID), address(m), "registry");
        assertTrue(factory.isMarket(address(m)), "isMarket");
        assertEq(uint256(m.status()), uint256(IEventMarket.Status.OPEN), "open");
    }

    function test_createMarket_onlyGovernance() public {
        vm.expectRevert(EventMarketFactory.Unauthorized.selector);
        vm.prank(stranger);
        factory.createMarket(SUBJECT_ID, EVENT_ID, uint8(1), "Q", DEADLINE, 0, LMSR_B);
    }

    function test_createMarket_duplicateReverts() public {
        _defaultMarket();
        vm.expectRevert("EventMarketFactory: already exists");
        vm.prank(governance);
        factory.createMarket(SUBJECT_ID, EVENT_ID, uint8(1), "Q", DEADLINE, 0, LMSR_B);
    }

    // ------------------------------------------------------------------------------------------
    // Direct buy / sell (self-custody path)
    // ------------------------------------------------------------------------------------------

    function test_directBuy_creditsBuyerAndPullsUsdc() public {
        EventMarket m = _defaultMarket();
        uint256 spend = 100e6;
        uint256 balBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        usdc.approve(address(m), spend);
        uint256 shares = m.buyOutcome(true, spend, 0);
        vm.stopPrank();

        assertGt(shares, 0, "shares minted");
        assertEq(m.yesBalance(alice), shares, "credited buyer");
        assertEq(usdc.balanceOf(alice), balBefore - spend, "usdc pulled");
        assertEq(m.totalYesShares(), shares, "q1 updated");
    }

    function test_directSell_returnsUsdcToSeller() public {
        EventMarket m = _defaultMarket();
        vm.startPrank(alice);
        usdc.approve(address(m), 100e6);
        uint256 shares = m.buyOutcome(true, 100e6, 0);
        uint256 balBeforeSell = usdc.balanceOf(alice);
        uint256 out = m.sellOutcome(true, shares, 0);
        vm.stopPrank();

        assertGt(out, 0, "usdc out");
        assertEq(m.yesBalance(alice), 0, "shares burned");
        assertEq(usdc.balanceOf(alice), balBeforeSell + out, "usdc returned");
    }

    function test_directBuy_zeroAmountReverts() public {
        EventMarket m = _defaultMarket();
        vm.prank(alice);
        vm.expectRevert(EventMarket.AmountZero.selector);
        m.buyOutcome(true, 0, 0);
    }

    function test_directSell_insufficientBalanceReverts() public {
        EventMarket m = _defaultMarket();
        vm.prank(alice);
        vm.expectRevert(EventMarket.InsufficientBalance.selector);
        m.sellOutcome(true, 1e6, 0);
    }

    // ------------------------------------------------------------------------------------------
    // LMSR pricing sanity
    // ------------------------------------------------------------------------------------------

    function test_lmsr_priceImpactMonotonic() public {
        EventMarket m = _defaultMarket();
        vm.startPrank(alice);
        usdc.approve(address(m), type(uint256).max);
        // Equal USDC buys of YES yield progressively fewer shares as price rises.
        uint256 s1 = m.buyOutcome(true, 100e6, 0);
        uint256 s2 = m.buyOutcome(true, 100e6, 0);
        uint256 s3 = m.buyOutcome(true, 100e6, 0);
        vm.stopPrank();
        assertGt(s1, s2, "price impact 1>2");
        assertGt(s2, s3, "price impact 2>3");
    }

    function test_lmsr_buyYesRaisesYesPrice() public {
        EventMarket m = _defaultMarket();
        uint256 pYesBefore = m.priceOf(true);
        vm.startPrank(alice);
        usdc.approve(address(m), 5_000e6);
        m.buyOutcome(true, 5_000e6, 0);
        vm.stopPrank();
        uint256 pYesAfter = m.priceOf(true);
        assertGt(pYesAfter, pYesBefore, "yes price rose");
    }

    function test_lmsr_roundTripDoesNotProfit() public {
        // Buy then immediately sell the same shares must not return more USDC than spent.
        EventMarket m = _defaultMarket();
        vm.startPrank(alice);
        usdc.approve(address(m), 100e6);
        uint256 shares = m.buyOutcome(true, 100e6, 0);
        uint256 out = m.sellOutcome(true, shares, 0);
        vm.stopPrank();
        assertLe(out, 100e6, "no risk-free profit");
    }

    // ------------------------------------------------------------------------------------------
    // Slippage
    // ------------------------------------------------------------------------------------------

    function test_buy_slippageReverts() public {
        EventMarket m = _defaultMarket();
        vm.startPrank(alice);
        usdc.approve(address(m), 100e6);
        uint256 quote = LMSRMath.sharesForUsdc(0, 0, LMSR_B, 100e6);
        vm.expectRevert(abi.encodeWithSelector(EventMarket.SlippageExceeded.selector, quote, quote + 1));
        m.buyOutcome(true, 100e6, quote + 1);
        vm.stopPrank();
    }

    function test_buy_slippageBoundaryPasses() public {
        EventMarket m = _defaultMarket();
        vm.startPrank(alice);
        usdc.approve(address(m), 100e6);
        uint256 quote = LMSRMath.sharesForUsdc(0, 0, LMSR_B, 100e6);
        uint256 shares = m.buyOutcome(true, 100e6, quote); // exact min == result
        vm.stopPrank();
        assertEq(shares, quote, "exact boundary ok");
    }

    function test_sell_slippageReverts() public {
        EventMarket m = _defaultMarket();
        vm.startPrank(alice);
        usdc.approve(address(m), 100e6);
        uint256 shares = m.buyOutcome(true, 100e6, 0);
        uint256 quote = LMSRMath.usdcForShares(m.totalYesShares(), m.totalNoShares(), LMSR_B, shares);
        vm.expectRevert(abi.encodeWithSelector(EventMarket.SlippageExceeded.selector, quote, quote + 1));
        m.sellOutcome(true, shares, quote + 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------
    // Operator path — credit-the-trader invariant + USDC custody
    // ------------------------------------------------------------------------------------------

    function test_operatorBuy_creditsTraderNotOperator() public {
        EventMarket m = _defaultMarket();
        uint256 spend = 100e6;

        // Trader approves the ROUTER once (single approval target).
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);

        uint256 aliceBefore = usdc.balanceOf(alice);

        // Engine operator key relays the buy.
        vm.prank(operatorKey);
        uint256 shares = router.buyOutcomeFor(alice, address(m), true, spend, 0);

        // Shares credited to the trader, not the operator/router.
        assertEq(m.yesBalance(alice), shares, "trader credited");
        assertEq(m.yesBalance(operatorKey), 0, "operator not credited");
        assertEq(m.yesBalance(address(router)), 0, "router not credited");
        // USDC pulled from the trader.
        assertEq(usdc.balanceOf(alice), aliceBefore - spend, "usdc from trader");
        // Router holds no funds at rest and no residual allowance.
        assertEq(usdc.balanceOf(address(router)), 0, "router stateless");
        assertEq(usdc.allowance(address(router), address(m)), 0, "allowance cleared");
    }

    function test_operatorBuy_emitsTraderAsBuyer() public {
        EventMarket m = _defaultMarket();
        uint256 spend = 100e6;
        uint256 quote = LMSRMath.sharesForUsdc(0, 0, LMSR_B, spend);

        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);

        vm.expectEmit(true, false, false, true, address(m));
        emit EventMarket.SharesBought(alice, true, spend, quote);

        vm.prank(operatorKey);
        router.buyOutcomeFor(alice, address(m), true, spend, 0);
    }

    function test_operatorSell_proceedsToTrader() public {
        EventMarket m = _defaultMarket();

        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(operatorKey);
        uint256 shares = router.buyOutcomeFor(alice, address(m), true, 100e6, 0);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(operatorKey);
        uint256 out = router.sellOutcomeFor(alice, address(m), true, shares, 0);

        assertGt(out, 0, "proceeds");
        assertEq(m.yesBalance(alice), 0, "shares burned");
        // Proceeds go directly to the trader; router never custodies sell proceeds.
        assertEq(usdc.balanceOf(alice), aliceBefore + out, "trader paid");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds nothing");
    }

    function test_operatorSell_emitsTraderAsSeller() public {
        EventMarket m = _defaultMarket();
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(operatorKey);
        uint256 shares = router.buyOutcomeFor(alice, address(m), true, 100e6, 0);

        uint256 quote = LMSRMath.usdcForShares(m.totalYesShares(), m.totalNoShares(), LMSR_B, shares);
        vm.expectEmit(true, false, false, true, address(m));
        emit EventMarket.SharesSold(alice, true, shares, quote);
        vm.prank(operatorKey);
        router.sellOutcomeFor(alice, address(m), true, shares, 0);
    }

    function test_operatorBuy_slippageReverts() public {
        EventMarket m = _defaultMarket();
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        uint256 quote = LMSRMath.sharesForUsdc(0, 0, LMSR_B, 100e6);
        vm.expectRevert(abi.encodeWithSelector(EventMarket.SlippageExceeded.selector, quote, quote + 1));
        vm.prank(operatorKey);
        router.buyOutcomeFor(alice, address(m), true, 100e6, quote + 1);
    }

    // ------------------------------------------------------------------------------------------
    // Access control — two layers
    // ------------------------------------------------------------------------------------------

    function test_router_nonOperatorReverts() public {
        EventMarket m = _defaultMarket();
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NotOperator.selector, stranger));
        vm.prank(stranger);
        router.buyOutcomeFor(alice, address(m), true, 100e6, 0);
    }

    function test_router_removedOperatorReverts() public {
        EventMarket m = _defaultMarket();
        vm.prank(governance);
        router.removeOperator(operatorKey);
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NotOperator.selector, operatorKey));
        vm.prank(operatorKey);
        router.buyOutcomeFor(alice, address(m), true, 100e6, 0);
    }

    function test_market_directOperatorEntrypoint_nonOperatorReverts() public {
        // Calling the market's *For entrypoint directly (not via the router) must fail layer (i).
        EventMarket m = _defaultMarket();
        vm.prank(alice);
        usdc.approve(address(m), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(EventMarket.NotOperator.selector, alice));
        vm.prank(alice);
        m.buyOutcomeFor(alice, true, 100e6, 0);
    }

    function test_market_routerIsOperator_directCallWorks() public {
        // The router is an allowlisted factory operator: a direct market call from the router
        // address passes layer (i). (Proves the market trusts the router.)
        EventMarket m = _defaultMarket();
        usdc.mint(address(router), 100e6);
        vm.prank(address(router));
        usdc.approve(address(m), 100e6);
        vm.prank(address(router));
        uint256 shares = m.buyOutcomeFor(alice, true, 100e6, 0);
        assertEq(m.yesBalance(alice), shares, "trader credited via direct router call");
    }

    function test_router_removedFromFactory_marketRejects() public {
        // Layer (i) kill switch: remove the router as a factory operator → market rejects it.
        EventMarket m = _defaultMarket();
        vm.prank(governance);
        factory.removeOperator(address(router));
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(EventMarket.NotOperator.selector, address(router)));
        vm.prank(operatorKey);
        router.buyOutcomeFor(alice, address(m), true, 100e6, 0);
    }

    function test_router_rejectsNonFactoryMarket() public {
        // Router must refuse to pull trader USDC into a non-factory address.
        address fakeMarket = makeAddr("fakeMarket");
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NotAMarket.selector, fakeMarket));
        vm.prank(operatorKey);
        router.buyOutcomeFor(alice, fakeMarket, true, 100e6, 0);
    }

    function test_router_zeroTraderReverts() public {
        EventMarket m = _defaultMarket();
        vm.expectRevert(IEventMarketRouter.ZeroTrader.selector);
        vm.prank(operatorKey);
        router.buyOutcomeFor(address(0), address(m), true, 100e6, 0);
    }

    // ------------------------------------------------------------------------------------------
    // Operator allowlist governance (timelocked add / immediate remove)
    // ------------------------------------------------------------------------------------------

    function test_factory_operatorAdd_requiresTimelock() public {
        address newOp = makeAddr("newOp");
        vm.prank(governance);
        factory.proposeAddOperator(newOp);
        assertFalse(factory.isOperator(newOp), "not yet active");
        // Too early.
        vm.expectRevert();
        factory.activateAddOperator(newOp);
        vm.warp(block.timestamp + TIMELOCK);
        factory.activateAddOperator(newOp);
        assertTrue(factory.isOperator(newOp), "active after timelock");
    }

    function test_factory_operatorAdd_onlyGovernance() public {
        vm.expectRevert(EventMarketFactory.Unauthorized.selector);
        vm.prank(stranger);
        factory.proposeAddOperator(makeAddr("x"));
    }

    function test_factory_removeOperator_immediate() public {
        assertTrue(factory.isOperator(address(router)));
        vm.prank(governance);
        factory.removeOperator(address(router));
        assertFalse(factory.isOperator(address(router)));
    }

    function test_router_operatorAdd_requiresTimelock() public {
        address newOp = makeAddr("newOp2");
        vm.prank(governance);
        router.proposeAddOperator(newOp);
        vm.expectRevert();
        router.activateAddOperator(newOp);
        vm.warp(block.timestamp + TIMELOCK);
        router.activateAddOperator(newOp);
        assertTrue(router.isOperator(newOp));
    }

    function test_router_cancelOperator() public {
        address newOp = makeAddr("newOp3");
        vm.prank(governance);
        router.proposeAddOperator(newOp);
        vm.prank(governance);
        router.cancelAddOperator(newOp);
        assertEq(router.pendingOperatorActivatesAt(newOp), 0);
        vm.warp(block.timestamp + TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NoPendingOperator.selector, newOp));
        router.activateAddOperator(newOp);
    }

    // ------------------------------------------------------------------------------------------
    // Closed / resolved reverts
    // ------------------------------------------------------------------------------------------

    function test_buy_pastDeadlineReverts() public {
        EventMarket m = _defaultMarket();
        vm.warp(DEADLINE + 1);
        vm.prank(alice);
        usdc.approve(address(m), 100e6);
        vm.expectRevert("EventMarket: past deadline");
        vm.prank(alice);
        m.buyOutcome(true, 100e6, 0);
    }

    function test_operatorBuy_afterResolveReverts() public {
        EventMarket m = _defaultMarket();
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(operatorKey);
        router.buyOutcomeFor(alice, address(m), true, 100e6, 0);

        // Resolve YES.
        uma.setLatestValue(uint256(IEventMarket.Outcome.YES), uint64(block.timestamp));
        m.settleResolution();

        vm.expectRevert("EventMarket: not open");
        vm.prank(operatorKey);
        router.buyOutcomeFor(alice, address(m), true, 100e6, 0);
    }

    // ------------------------------------------------------------------------------------------
    // Resolution + redemption (YES / NO / VOID)
    // ------------------------------------------------------------------------------------------

    function test_resolveYes_redeemWinner() public {
        EventMarket m = _defaultMarket();
        vm.startPrank(alice);
        usdc.approve(address(m), 200e6);
        uint256 yesShares = m.buyOutcome(true, 200e6, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(m), 200e6);
        m.buyOutcome(false, 200e6, 0);
        vm.stopPrank();

        uma.setLatestValue(uint256(IEventMarket.Outcome.YES), uint64(block.timestamp));
        m.settleResolution();
        assertEq(uint256(m.outcome()), uint256(IEventMarket.Outcome.YES));

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = m.redeemWinnings();
        assertEq(payout, yesShares, "winner paid per share");
        assertEq(usdc.balanceOf(alice), aliceBefore + payout);

        // NO holder gets nothing.
        vm.expectRevert("EventMarket: no winnings");
        vm.prank(bob);
        m.redeemWinnings();
    }

    function test_resolveNo_redeemWinner() public {
        EventMarket m = _defaultMarket();
        vm.startPrank(bob);
        usdc.approve(address(m), 200e6);
        uint256 noShares = m.buyOutcome(false, 200e6, 0);
        vm.stopPrank();

        uma.setLatestValue(uint256(IEventMarket.Outcome.NO), uint64(block.timestamp));
        m.settleResolution();

        vm.prank(bob);
        uint256 payout = m.redeemWinnings();
        assertEq(payout, noShares, "no-winner paid");
    }

    function test_resolveVoid_redeemHalf() public {
        EventMarket m = _defaultMarket();
        vm.startPrank(alice);
        usdc.approve(address(m), 200e6);
        uint256 yesShares = m.buyOutcome(true, 200e6, 0);
        vm.stopPrank();

        uma.setLatestValue(uint256(IEventMarket.Outcome.VOID), uint64(block.timestamp));
        m.settleResolution();

        vm.prank(alice);
        uint256 payout = m.redeemWinnings();
        assertEq(payout, yesShares / 2, "void pays half");
    }

    function test_redeem_beforeResolveReverts() public {
        EventMarket m = _defaultMarket();
        vm.prank(alice);
        vm.expectRevert("EventMarket: not resolved");
        m.redeemWinnings();
    }

    // ------------------------------------------------------------------------------------------
    // Reentrancy — malicious token re-entering buyOutcome must hit the nonReentrant guard
    // ------------------------------------------------------------------------------------------

    function test_reentrancy_buyBlocked() public {
        // Build a parallel stack whose USDC is a reentrancy-probing token.
        ReentrantToken evil = new ReentrantToken();
        MockLPVault evilLp = new MockLPVault(IERC20(address(evil)));
        evil.mint(address(evilLp), 1_000_000e6);

        EventMarket marketImpl = new EventMarket();
        EventMarketFactory factoryImpl = new EventMarketFactory();
        bytes memory init = abi.encodeCall(
            EventMarketFactory.initialize,
            (
                governance,
                TIMELOCK,
                ILPVault(address(evilLp)),
                IFeedbackController(address(feedback)),
                UMAAdapter(address(uma)),
                IERC20(address(evil)),
                address(marketImpl)
            )
        );
        EventMarketFactory evilFactory = EventMarketFactory(address(new ERC1967Proxy(address(factoryImpl), init)));

        vm.prank(governance);
        address mAddr = evilFactory.createMarket(SUBJECT_ID, EVENT_ID, uint8(1), "Q", DEADLINE, 0, LMSR_B);
        EventMarket m = EventMarket(mAddr);

        evil.mint(alice, 1_000e6);
        vm.prank(alice);
        evil.approve(address(m), type(uint256).max);

        // Arm the token to re-enter buyOutcome during the market's safeTransferFrom.
        evil.arm(address(m));

        vm.prank(alice);
        vm.expectRevert(); // nonReentrant guard trips; the re-entry require unwinds the whole tx.
        m.buyOutcome(true, 100e6, 0);
    }
}
