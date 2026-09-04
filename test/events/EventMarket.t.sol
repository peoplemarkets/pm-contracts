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

contract MockEventERC1271Signer {
    mapping(bytes32 digest => bool approved) internal approvals;

    function setApproved(bytes32 digest, bool approved) external {
        approvals[digest] = approved;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return approvals[digest] ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @title EventMarket + EventMarketRouter test suite (WS-1).
/// @notice Covers market creation, direct buy/sell, LMSR pricing sanity, resolve/redeem (YES/NO/
///         VOID), wallet-signed engine relay authorization, the credit-the-trader invariant,
///         transient USDC custody, slippage, closed/resolved reverts, and reentrancy.
contract EventMarketTest is Test {
    EventMarketFactory internal factory;
    EventMarketRouter internal router;
    MockUSDC internal usdc;
    MockLPVault internal lpVault;
    MockFeedbackController internal feedback;
    MockUMAAdapter internal uma;

    address internal governance = makeAddr("governance");
    address internal operatorKey = makeAddr("operatorKey"); // engine KMS key
    address internal alice; // trader
    address internal bob = makeAddr("bob"); // trader
    address internal stranger = makeAddr("stranger");

    uint32 internal constant TIMELOCK = 1 days;
    uint256 internal constant LMSR_B = 10_000e6;
    uint256 internal constant UMA_BOND = 100e6;
    uint64 internal constant DEADLINE = 2_000_000_000;
    uint256 internal constant ALICE_KEY = 0xA11CE;

    bytes32 internal constant SUBJECT_ID = keccak256("subject.drake");
    bytes32 internal constant EVENT_ID = keccak256("event.drake.grammy");

    function setUp() public {
        vm.warp(1_900_000_000);
        alice = vm.addr(ALICE_KEY);

        usdc = new MockUSDC();
        lpVault = new MockLPVault(IERC20(address(usdc)));
        feedback = new MockFeedbackController();
        uma = new MockUMAAdapter();
        uma.setBondConfig(address(usdc), UMA_BOND);

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
        // Fix D: the readiness gate requires the UMA metric registered before creation.
        uma.setRegistered(eventId, true);
        vm.prank(governance);
        address addr = factory.createMarket(SUBJECT_ID, eventId, uint8(1), "Will Drake win?", DEADLINE, 0, LMSR_B);
        m = EventMarket(addr);
    }

    function _defaultMarket() internal returns (EventMarket m) {
        return _createMarket(EVENT_ID);
    }

    function _eventOrder(
        address trader,
        address market,
        bool isYes,
        IEventMarketRouter.OrderIntent intent,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 nonce
    )
        internal
        view
        returns (IEventMarketRouter.EventOrder memory order)
    {
        order = IEventMarketRouter.EventOrder({
            trader: trader,
            executor: operatorKey,
            market: market,
            isYes: isYes,
            intent: intent,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            nonce: nonce,
            deadline: uint64(block.timestamp + 1 days)
        });
    }

    function _sign(uint256 key, IEventMarketRouter.EventOrder memory order) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, router.hashOrder(order));
        return abi.encodePacked(r, s, v);
    }

    function _execute(
        IEventMarketRouter.EventOrder memory order,
        bytes memory signature
    )
        internal
        returns (uint256 amountOut)
    {
        vm.prank(operatorKey);
        return router.executeOrder(order, signature);
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

    function test_priceOf_freshMarketIsHalfAndSumsToOne() public {
        EventMarket m = _defaultMarket();
        uint256 pYes = m.priceOf(true);
        uint256 pNo = m.priceOf(false);
        // Balanced book (q1 == q2 == 0) => each outcome ~= 0.5e18.
        assertApproxEqAbs(pYes, 0.5e18, 1e6, "yes ~= 0.5e18");
        assertApproxEqAbs(pNo, 0.5e18, 1e6, "no ~= 0.5e18");
        // Probabilities must partition exactly.
        assertEq(pYes + pNo, 1e18, "sum == 1e18");
    }

    function test_priceOf_afterYesBuyRisesAndStillSumsToOne() public {
        EventMarket m = _defaultMarket();
        uint256 pYesBefore = m.priceOf(true);

        vm.startPrank(alice);
        usdc.approve(address(m), 5_000e6);
        m.buyOutcome(true, 5_000e6, 0);
        vm.stopPrank();

        uint256 pYes = m.priceOf(true);
        uint256 pNo = m.priceOf(false);
        assertGt(pYes, pYesBefore, "yes price rose after YES buy");
        assertGt(pYes, pNo, "yes now more likely than no");
        assertEq(pYes + pNo, 1e18, "sum still == 1e18");
    }

    function test_priceOf_extremeImbalanceDoesNotRevert() public {
        EventMarket m = _defaultMarket();
        // Drive a large one-sided position; the shift-invariant softmax must not overflow expWad.
        vm.startPrank(alice);
        usdc.approve(address(m), type(uint256).max);
        m.buyOutcome(true, 900_000e6, 0);
        vm.stopPrank();

        uint256 pYes = m.priceOf(true);
        uint256 pNo = m.priceOf(false);
        // YES saturates toward 1e18; NO toward 0. No revert, and they still partition exactly.
        assertGt(pYes, pNo, "yes dominates");
        assertLe(pYes, 1e18, "yes bounded by 1e18");
        assertEq(pYes + pNo, 1e18, "sum still == 1e18 under imbalance");
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

    /// @notice Cross-language guard for the browser's one-percent LMSR protection vectors.
    ///         Each browser floor must stay below the fixed-point Solidity quote.
    function test_uiLmsrBuyFloor_symmetricSmallLiquidity() public pure {
        assertGe(LMSRMath.sharesForUsdc(0, 0, 2_000_000, 25_000_000), 26_122_427);
    }

    function test_uiLmsrBuyFloor_skewedSmallLiquidityYes() public pure {
        assertGe(LMSRMath.sharesForUsdc(5_000_000, 1_000_000, 2_000_000, 1_000_000), 1_092_724);
    }

    function test_uiLmsrBuyFloor_skewedSmallLiquidityNo() public pure {
        assertGe(LMSRMath.sharesForUsdc(1_000_000, 5_000_000, 2_000_000, 1_000_000), 3_688_470);
    }

    function test_uiLmsrBuyFloor_skewedDeepLiquidityYes() public pure {
        assertGe(LMSRMath.sharesForUsdc(300_000_000, 125_000_000, 100_000_000, 50_000_000), 56_047_715);
    }

    function test_uiLmsrBuyFloor_skewedDeepLiquidityNo() public pure {
        assertGe(LMSRMath.sharesForUsdc(125_000_000, 300_000_000, 100_000_000, 50_000_000), 166_620_267);
    }

    function test_uiLmsrSellFloor_roundTripSmallLiquidity() public pure {
        assertGe(LMSRMath.usdcForShares(26_386_290, 0, 2_000_000, 26_386_290), 24_749_999);
    }

    function test_uiLmsrSellFloor_skewedSmallLiquidity() public pure {
        assertGe(LMSRMath.usdcForShares(5_000_000, 1_000_000, 2_000_000, 2_000_000), 1_611_059);
    }

    function test_uiLmsrSellFloor_skewedDeepLiquidityYes() public pure {
        assertGe(LMSRMath.usdcForShares(300_000_000, 125_000_000, 100_000_000, 10_000_000), 8_370_421);
    }

    function test_uiLmsrSellFloor_skewedDeepLiquidityNo() public pure {
        assertGe(LMSRMath.usdcForShares(125_000_000, 300_000_000, 100_000_000, 10_000_000), 1_404_685);
    }

    // ------------------------------------------------------------------------------------------
    // Wallet-authorized relay path
    // ------------------------------------------------------------------------------------------

    function test_routerDomainAndHash_matchCanonicalEip712Encoding() public {
        EventMarket m = _defaultMarket();
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 1, 7);
        bytes32 typeHash = keccak256(
            "EventOrder(address trader,address executor,address market,bool isYes,uint8 intent,uint256 amountIn,uint256 minAmountOut,uint256 nonce,uint64 deadline)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                order.trader,
                order.executor,
                order.market,
                order.isYes,
                order.intent,
                order.amountIn,
                order.minAmountOut,
                order.nonce,
                order.deadline
            )
        );
        bytes32 expected = keccak256(abi.encodePacked("\x19\x01", router.domainSeparator(), structHash));

        assertEq(router.EVENT_ORDER_TYPEHASH(), typeHash);
        assertEq(router.hashOrder(order), expected);
        assertNotEq(router.domainSeparator(), bytes32(0));
    }

    function test_signedBuy_creditsTraderNotOperator() public {
        EventMarket m = _defaultMarket();
        uint256 spend = 100e6;
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, spend, 0, 1);

        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 shares = _execute(order, _sign(ALICE_KEY, order));

        assertGt(shares, 0, "shares minted");
        assertEq(m.yesBalance(alice), shares, "trader credited");
        assertEq(m.yesBalance(operatorKey), 0, "operator not credited");
        assertEq(m.yesBalance(address(router)), 0, "router not credited");
        assertEq(usdc.balanceOf(alice), aliceBefore - spend, "usdc from trader");
        assertEq(usdc.balanceOf(address(router)), 0, "router stateless");
        assertEq(usdc.allowance(address(router), address(m)), 0, "allowance cleared");
        assertTrue(router.isNonceUsed(alice, order.nonce), "nonce consumed");
    }

    function test_signedBuy_emitsTraderAsBuyer() public {
        EventMarket m = _defaultMarket();
        uint256 spend = 100e6;
        uint256 quote = LMSRMath.sharesForUsdc(0, 0, LMSR_B, spend);
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, spend, 0, 2);
        bytes memory signature = _sign(ALICE_KEY, order);

        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        vm.expectEmit(true, false, false, true, address(m));
        emit EventMarket.SharesBought(alice, true, spend, quote);
        vm.expectEmit(true, true, true, true, address(router));
        emit IEventMarketRouter.EventOrderExecuted(
            router.hashOrder(order),
            alice,
            address(m),
            operatorKey,
            true,
            IEventMarketRouter.OrderIntent.BUY,
            spend,
            quote,
            order.nonce
        );
        _execute(order, signature);
    }

    function test_signedSell_proceedsToTrader() public {
        EventMarket m = _defaultMarket();
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        IEventMarketRouter.EventOrder memory buy =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 3);
        uint256 shares = _execute(buy, _sign(ALICE_KEY, buy));

        uint256 aliceBefore = usdc.balanceOf(alice);
        IEventMarketRouter.EventOrder memory sell =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.SELL, shares, 0, 4);
        uint256 out = _execute(sell, _sign(ALICE_KEY, sell));

        assertGt(out, 0, "proceeds");
        assertEq(m.yesBalance(alice), 0, "shares burned");
        assertEq(usdc.balanceOf(alice), aliceBefore + out, "trader paid");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds nothing");
    }

    function test_signedSell_emitsTraderAsSeller() public {
        EventMarket m = _defaultMarket();
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        IEventMarketRouter.EventOrder memory buy =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 5);
        uint256 shares = _execute(buy, _sign(ALICE_KEY, buy));

        uint256 quote = LMSRMath.usdcForShares(m.totalYesShares(), m.totalNoShares(), LMSR_B, shares);
        IEventMarketRouter.EventOrder memory sell =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.SELL, shares, quote, 6);
        bytes memory signature = _sign(ALICE_KEY, sell);
        vm.expectEmit(true, false, false, true, address(m));
        emit EventMarket.SharesSold(alice, true, shares, quote);
        _execute(sell, signature);
    }

    function test_signedBuy_slippageRevertsAndNonceRollsBack() public {
        EventMarket m = _defaultMarket();
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        uint256 quote = LMSRMath.sharesForUsdc(0, 0, LMSR_B, 100e6);
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, quote + 1, 7);
        bytes memory signature = _sign(ALICE_KEY, order);

        vm.expectRevert(abi.encodeWithSelector(EventMarket.SlippageExceeded.selector, quote, quote + 1));
        _execute(order, signature);
        assertFalse(router.isNonceUsed(alice, order.nonce), "reverted nonce must remain available");
    }

    function test_signedOrder_supportsERC1271Trader() public {
        EventMarket m = _defaultMarket();
        MockEventERC1271Signer wallet = new MockEventERC1271Signer();
        usdc.mint(address(wallet), 100e6);
        vm.prank(address(wallet));
        usdc.approve(address(router), type(uint256).max);
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(address(wallet), address(m), false, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 8);
        wallet.setApproved(router.hashOrder(order), true);

        uint256 shares = _execute(order, bytes("wallet-signature"));
        assertEq(m.noBalance(address(wallet)), shares, "contract wallet credited");
        assertTrue(router.isNonceUsed(address(wallet), order.nonce));
    }

    function test_signedOrder_rejectsInvalidOrTamperedSignature() public {
        EventMarket m = _defaultMarket();
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 9);
        bytes memory signature = _sign(ALICE_KEY, order);
        order.amountIn += 1;

        bytes32 tamperedHash = router.hashOrder(order);
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.InvalidSignature.selector, alice, tamperedHash));
        _execute(order, signature);
        assertFalse(router.isNonceUsed(alice, order.nonce));
    }

    function test_signedOrder_rejectsNonceReplayAcrossPayloads() public {
        EventMarket m = _defaultMarket();
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        IEventMarketRouter.EventOrder memory first =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 10);
        _execute(first, _sign(ALICE_KEY, first));

        IEventMarketRouter.EventOrder memory second =
            _eventOrder(alice, address(m), false, IEventMarketRouter.OrderIntent.BUY, 50e6, 0, 10);
        bytes memory secondSignature = _sign(ALICE_KEY, second);
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NonceAlreadyUsed.selector, alice, 10));
        _execute(second, secondSignature);
    }

    function test_signedOrder_cancelAndNonceFloor() public {
        EventMarket m = _defaultMarket();
        IEventMarketRouter.EventOrder memory cancelled =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 11);
        bytes memory cancelledSignature = _sign(ALICE_KEY, cancelled);
        vm.prank(alice);
        router.cancelOrder(cancelled);
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NonceAlreadyUsed.selector, alice, 11));
        _execute(cancelled, cancelledSignature);

        vm.prank(alice);
        router.invalidateNoncesBelow(20);
        assertEq(router.minimumValidNonce(alice), 20);
        IEventMarketRouter.EventOrder memory old =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 19);
        bytes memory oldSignature = _sign(ALICE_KEY, old);
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NonceInvalid.selector, alice, 19, 20));
        _execute(old, oldSignature);

        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NonceFloorNotIncreasing.selector, 20, 20));
        vm.prank(alice);
        router.invalidateNoncesBelow(20);

        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NonceFloorNotIncreasing.selector, 20, 12));
        vm.prank(alice);
        router.invalidateNoncesBelow(12);
    }

    function test_signedOrder_rejectsUnsetIntentAndZeroAmount() public {
        EventMarket m = _defaultMarket();
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.UNSET, 100e6, 0, 12);
        vm.expectRevert(
            abi.encodeWithSelector(IEventMarketRouter.InvalidOrderIntent.selector, IEventMarketRouter.OrderIntent.UNSET)
        );
        _execute(order, "");

        order.intent = IEventMarketRouter.OrderIntent.BUY;
        order.amountIn = 0;
        vm.expectRevert(IEventMarketRouter.AmountZero.selector);
        _execute(order, "");
    }

    function test_signedOrder_executesAtExactDeadline() public {
        EventMarket m = _defaultMarket();
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(alice, address(m), false, IEventMarketRouter.OrderIntent.BUY, 1e6, 0, 13);
        order.deadline = uint64(block.timestamp);
        bytes memory signature = _sign(ALICE_KEY, order);
        vm.prank(alice);
        usdc.approve(address(router), order.amountIn);

        uint256 shares = _execute(order, signature);
        assertGt(shares, 0, "exact deadline is valid");
        assertTrue(router.isNonceUsed(alice, order.nonce));
    }

    function test_cancelOrder_onlyTraderAndCannotCancelConsumedNonce() public {
        EventMarket m = _defaultMarket();
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 1e6, 0, 14);

        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.Unauthorized.selector, stranger));
        vm.prank(stranger);
        router.cancelOrder(order);

        vm.prank(alice);
        usdc.approve(address(router), order.amountIn);
        _execute(order, _sign(ALICE_KEY, order));

        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NonceAlreadyUsed.selector, alice, order.nonce));
        vm.prank(alice);
        router.cancelOrder(order);
    }

    function test_unsignedLegacySelectorsAlwaysRevert() public {
        EventMarket m = _defaultMarket();
        vm.startPrank(operatorKey);
        vm.expectRevert(IEventMarketRouter.SignedOrderRequired.selector);
        router.buyOutcomeFor(alice, address(m), true, 100e6, 0);
        vm.expectRevert(IEventMarketRouter.SignedOrderRequired.selector);
        router.sellOutcomeFor(alice, address(m), true, 1e18, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------
    // Access control — operator, signed executor, and factory market
    // ------------------------------------------------------------------------------------------

    function test_router_nonOperatorReverts() public {
        EventMarket m = _defaultMarket();
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 21);
        bytes memory signature = _sign(ALICE_KEY, order);
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NotOperator.selector, stranger));
        vm.prank(stranger);
        router.executeOrder(order, signature);
    }

    function test_router_removedOperatorReverts() public {
        EventMarket m = _defaultMarket();
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 22);
        bytes memory signature = _sign(ALICE_KEY, order);
        vm.prank(governance);
        router.removeOperator(operatorKey);
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NotOperator.selector, operatorKey));
        _execute(order, signature);
    }

    function test_router_rejectsExecutorMismatch() public {
        EventMarket m = _defaultMarket();
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 23);
        order.executor = stranger;
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.UnauthorizedExecutor.selector, stranger, operatorKey));
        _execute(order, "");
    }

    function test_router_rejectsExpiredOrder() public {
        EventMarket m = _defaultMarket();
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 24);
        order.deadline = uint64(block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.DeadlineExpired.selector, order.deadline));
        _execute(order, "");
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
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 25);
        bytes memory signature = _sign(ALICE_KEY, order);
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(EventMarket.NotOperator.selector, address(router)));
        _execute(order, signature);
    }

    function test_router_rejectsNonFactoryMarket() public {
        address fakeMarket = makeAddr("fakeMarket");
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(alice, fakeMarket, true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 26);
        bytes memory signature = _sign(ALICE_KEY, order);
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NotAMarket.selector, fakeMarket));
        _execute(order, signature);
    }

    function test_router_zeroTraderReverts() public {
        EventMarket m = _defaultMarket();
        IEventMarketRouter.EventOrder memory order =
            _eventOrder(address(0), address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 27);
        vm.expectRevert(IEventMarketRouter.ZeroTrader.selector);
        _execute(order, "");
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

    function test_signedBuy_afterResolveReverts() public {
        EventMarket m = _defaultMarket();
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
        IEventMarketRouter.EventOrder memory first =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 28);
        _execute(first, _sign(ALICE_KEY, first));

        // Resolve YES.
        uma.setLatestValue(uint256(IEventMarket.Outcome.YES), uint64(block.timestamp));
        m.settleResolution();

        IEventMarketRouter.EventOrder memory second =
            _eventOrder(alice, address(m), true, IEventMarketRouter.OrderIntent.BUY, 100e6, 0, 29);
        bytes memory signature = _sign(ALICE_KEY, second);
        vm.expectRevert("EventMarket: not open");
        _execute(second, signature);
    }

    // ------------------------------------------------------------------------------------------
    // Resolution proposal bond custody
    // ------------------------------------------------------------------------------------------

    function test_proposeResolution_usesExternalProposerBondAndPreservesMarketCollateral() public {
        EventMarket m = _defaultMarket();
        uint256 marketBalanceBefore = usdc.balanceOf(address(m));
        uint256 proposerBalanceBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        usdc.approve(address(m), UMA_BOND);
        m.proposeResolution(IEventMarket.Outcome.YES);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), proposerBalanceBefore - UMA_BOND, "proposer funds bond");
        assertEq(usdc.balanceOf(address(m)), marketBalanceBefore, "payout collateral unchanged");
        assertEq(usdc.balanceOf(address(uma)), UMA_BOND, "adapter mock holds forwarded bond");
        assertEq(uma.lastBondPayer(), address(m), "market is immediate adapter payer");
        assertEq(uma.lastAsserter(), alice, "proposer remains economic asserter");
        assertEq(uma.lastMetricId(), EVENT_ID, "event id binds assertion metric");
        assertTrue(uma.lastAssertionId() != bytes32(0), "assertion id recorded");
        assertEq(usdc.allowance(address(m), address(uma)), 0, "transient adapter approval cleared");
        assertEq(uint256(m.status()), uint256(IEventMarket.Status.PENDING_RESOLUTION), "pending resolution");
    }

    function test_proposeResolution_withoutProposerBondApprovalRevertsAtomically() public {
        EventMarket m = _defaultMarket();
        uint256 marketBalanceBefore = usdc.balanceOf(address(m));
        uint256 proposerBalanceBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectRevert();
        m.proposeResolution(IEventMarket.Outcome.YES);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), proposerBalanceBefore, "proposer balance unchanged");
        assertEq(usdc.balanceOf(address(m)), marketBalanceBefore, "market collateral unchanged");
        assertEq(usdc.balanceOf(address(uma)), 0, "no bond forwarded");
        assertEq(uint256(m.status()), uint256(IEventMarket.Status.OPEN), "market remains open");
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
