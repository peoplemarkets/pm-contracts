// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {ILPVault} from "../../src/core/ILPVault.sol";
import {LPVault} from "../../src/core/LPVault.sol";

import {EventMarket} from "../../src/events/EventMarket.sol";
import {EventMarketFactory} from "../../src/events/EventMarketFactory.sol";
import {IEventMarket} from "../../src/events/IEventMarket.sol";
import {LMSRMath} from "../../src/events/LMSRMath.sol";
import {IFeedbackController} from "../../src/feedback/IFeedbackController.sol";
import {UMAAdapter} from "../../src/oracle/UMAAdapter.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockFeedbackController, MockUMAAdapter} from "./mocks/MockEventDeps.sol";

/// @title EventNavArb — recoverable-value NAV: proves the redemption arb AND the deposit arb are both
///        closed, that settle produces zero NAV jump (YES/NO/VOID), that strict I1 and the NAV
///        identity hold with a live market, and that perp OI capacity (capTvl) is unaffected by
///        event funding.
/// @dev   Uses the REAL LPVault + REAL EventMarketFactory + REAL EventMarket clones (only the UMA
///        adapter and FeedbackController are mocked) so the fund → trade → resolve → settle path is
///        exercised end to end against the live NAV accounting.
contract EventNavArbTest is Test {
    LPVault internal vault;
    EventMarketFactory internal factory;
    EventMarket internal marketImpl;
    MockUSDC internal usdc;
    MockFeedbackController internal feedback;
    MockUMAAdapter internal uma;

    address internal governance = makeAddr("governance");
    address internal operator = makeAddr("operator");
    address internal perpEngine = makeAddr("perpEngine"); // EOA stand-in for the perp path
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal trader = makeAddr("trader");

    uint32 internal constant TIMELOCK = 1 days;
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant LMSR_B = 10_000e6;
    uint64 internal constant DEADLINE = 2_000_000_000;

    bytes32 internal constant SUBJECT_ID = keccak256("subject.drake");

    function setUp() public {
        vm.warp(1_900_000_000);

        usdc = new MockUSDC();

        // ---- Real LPVault behind a UUPS proxy ----
        LPVault vaultImpl = new LPVault();
        bytes memory vInit = abi.encodeCall(
            LPVault.initialize,
            (IERC20(address(usdc)), governance, operator, TIMELOCK, "People Markets LP USDC", "pmUSDC")
        );
        vault = LPVault(address(new ERC1967Proxy(address(vaultImpl), vInit)));

        // Wire a perpEngine EOA stand-in (so we can exercise the perp settle/liquidation path).
        vm.prank(governance);
        vault.proposeSetPerpEngine(perpEngine);
        vm.warp(block.timestamp + TIMELOCK);
        vault.activateSetPerpEngine();

        // ---- Event stack: mock feedback + UMA, real market impl + factory ----
        feedback = new MockFeedbackController();
        uma = new MockUMAAdapter();
        marketImpl = new EventMarket();

        EventMarketFactory factoryImpl = new EventMarketFactory();
        bytes memory fInit = abi.encodeCall(
            EventMarketFactory.initialize,
            (
                governance,
                TIMELOCK,
                ILPVault(address(vault)),
                IFeedbackController(address(feedback)),
                UMAAdapter(address(uma)),
                IERC20(address(usdc)),
                address(marketImpl)
            )
        );
        factory = EventMarketFactory(address(new ERC1967Proxy(address(factoryImpl), fInit)));

        // Wire the factory into the vault (timelocked).
        vm.prank(governance);
        vault.proposeSetEventMarketFactory(address(factory));
        vm.warp(block.timestamp + TIMELOCK);
        vault.activateSetEventMarketFactory();

        // Fund actors + approvals.
        address[4] memory people = [alice, bob, carol, trader];
        for (uint256 i; i < people.length; ++i) {
            usdc.mint(people[i], 20_000_000 * ONE_USDC);
            vm.prank(people[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _seed() internal pure returns (uint256) {
        return LMSRMath.cost(0, 0, LMSR_B);
    }

    function _createMarket(bytes32 eventId) internal returns (EventMarket m) {
        vm.prank(governance);
        address addr = factory.createMarket(SUBJECT_ID, eventId, uint8(1), "Q?", DEADLINE, 0, LMSR_B);
        m = EventMarket(addr);
    }

    function _buy(EventMarket m, address who, bool isYes, uint256 usdcAmount) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(m), usdcAmount);
        shares = m.buyOutcome(isYes, usdcAmount, 0);
        vm.stopPrank();
    }

    /// @dev Tolerant buy: LMSRMath can revert on extreme asymmetric states (e.g. a tiny buy into a
    ///      heavily-skewed book underflows the internal ln). For property tests we only need SOME
    ///      valid market state, so we swallow such reverts and continue.
    function _tryBuy(EventMarket m, address who, bool isYes, uint256 usdcAmount) internal {
        vm.startPrank(who);
        usdc.approve(address(m), usdcAmount);
        try m.buyOutcome(isYes, usdcAmount, 0) {} catch {}
        vm.stopPrank();
    }

    /// @dev Post an outcome to the UMA mock WITHOUT settling the market (the pre-settle "outcome
    ///      known" window that the redemption arb exploited).
    function _postOutcome(
        bytes32,
        /*eventId*/
        IEventMarket.Outcome o
    )
        internal
    {
        uma.setLatestValue(uint256(o), uint64(block.timestamp));
    }

    function _sumMarketBalances(EventMarket[] memory ms) internal view returns (uint256 s) {
        for (uint256 i; i < ms.length; ++i) {
            s += usdc.balanceOf(address(ms[i]));
        }
    }

    // ------------------------------------------------------------------------------------------
    // Funding continuity: NAV does not drop when a market is seeded (this is what breaks the
    // mark-to-zero PR #12 approach and enables its mirror deposit arb).
    // ------------------------------------------------------------------------------------------

    function test_fundingIsNavNeutral() public {
        vm.prank(alice);
        vault.deposit(1_000_000 * ONE_USDC, alice);

        uint256 navBefore = vault.totalAssets();
        uint256 freeBefore = vault.freeAssets();

        EventMarket m = _createMarket(keccak256("e.fund"));
        uint256 seed = _seed();

        // freeAssets dropped by the seed (it physically left the vault)...
        assertEq(vault.freeAssets(), freeBefore - seed, "freeAssets should drop by seed");
        // ...but NAV is unchanged: the fresh market is marked at its full recoverable (== its balance).
        assertEq(vault.totalAssets(), navBefore, "NAV must be continuous across funding");
        assertEq(m.currentRecoverable(), seed, "fresh market recoverable == seed");
        assertEq(vault.eventRecoverable(), seed, "eventRecoverable == seed");
    }

    // ------------------------------------------------------------------------------------------
    // ARB #1 — REDEMPTION ARB is closed.
    // A redeemer who exits after a LOSING outcome is KNOWN (UMA posted) but BEFORE settle can only
    // extract their fair (marked-down) pro-rata share — no socialized loss onto remaining LPs.
    // ------------------------------------------------------------------------------------------

    function test_redemptionArb_closed_losingOutcomeKnownPreSettle() public {
        // Two equal LPs.
        vm.prank(alice);
        vault.deposit(1_000_000 * ONE_USDC, alice);
        vm.prank(bob);
        vault.deposit(1_000_000 * ONE_USDC, bob);

        EventMarket m = _createMarket(keccak256("e.redeem"));

        // Trader buys YES heavily; if YES resolves true the LP must pay q1 > amountPaid → LP loss.
        _buy(m, trader, true, 200_000 * ONE_USDC);

        uint256 supply = vault.totalSupply();

        // STALE per-share value: what a redeemer would extract if the seed were still counted at full
        // cost in the denominator (the historical redemption-arb bug).
        uint256 stalePps = (vault.freeAssets() + vault.eventFundedSeed()) * 1e18 / supply;

        // UMA posts the LP-losing outcome (YES). Market NOT yet settled — the exploit window.
        _postOutcome(m.params().eventId, IEventMarket.Outcome.YES);

        // FAIR per-share value = marked NAV (already reflects the loss). Must be BELOW stale.
        uint256 fairPps = vault.totalAssets() * 1e18 / supply;
        assertLt(fairPps, stalePps, "marked NAV per share is below the stale full-cost value");

        // Alice redeems a slice she is permitted to (within the liquidity cap — a large LP cannot
        // fully exit while a market is live, which is the correct behaviour, not insolvency).
        uint256 slice = vault.maxRedeem(alice) / 2;
        assertGt(slice, 0, "alice has a redeemable slice");
        vm.prank(alice);
        uint256 aliceOut = vault.redeem(slice, alice, alice);
        uint256 alicePps = aliceOut * 1e18 / slice;

        // The redeemer gets NO better than fair marked NAV, and strictly less than the stale value.
        assertLe(alicePps, fairPps + 1, "pre-settle redeem price <= fair marked NAV");
        assertLt(alicePps, stalePps, "redeemer cannot capture stale-high value (arb closed)");
        console2.log("REDEMPTION ARB: stale pps (buggy) =", stalePps);
        console2.log("REDEMPTION ARB: fair marked pps    =", fairPps);
        console2.log("REDEMPTION ARB: alice realised pps =", alicePps);
        console2.log("REDEMPTION ARB: pps blocked (stale-fair) =", stalePps - fairPps);

        // Now settle for real (permissionless). NAV is continuous — recoverable drops to 0 exactly as
        // the balance rises by toReturn. Bob (the equal LP) redeems the same slice post-settle and
        // realises the same per-share price → no jump, so the pre-settle redeemer socialised nothing.
        m.settleResolution();
        vm.prank(bob);
        uint256 bobOut = vault.redeem(slice, bob, bob);
        uint256 bobPps = bobOut * 1e18 / slice;
        assertApproxEqRel(alicePps, bobPps, 1e12, "settle produced no per-share jump (no socialised loss)");
    }

    // ------------------------------------------------------------------------------------------
    // ARB #2 — DEPOSIT ARB is closed on a TRADED, SKEWED market (replaces the old untraded q1=q2=0
    // proving test, which was tautological: floor==exact so the settle snap was 0 by construction).
    // A depositor who sandwiches the UMA-resolution instant on the MINORITY (vault-favourable)
    // outcome cannot instantly skim the large floor→exact surplus — it lands in the receive-only
    // vesting bucket (excluded from NAV) and drips in over the vest window.
    // ------------------------------------------------------------------------------------------

    function test_depositArb_closed_tradedSkewed_minorityOutcome() public {
        // Alice is the incumbent LP.
        uint256 aliceIn = 1_000_000 * ONE_USDC;
        vm.prank(alice);
        vault.deposit(aliceIn, alice);

        EventMarket m = _createMarket(keccak256("e.deposit.skew"));
        assertEq(vault.totalAssets(), aliceIn, "NAV neutral at funding");

        // Heavy, one-sided YES book via REAL buys (q1 >> q2). If the MINORITY-share outcome (NO)
        // resolves, the vault pays only the smaller side but keeps the collected premium → a large
        // surplus σ = max(q1,q2) − min(q1,q2). This is the ~$370k floor→exact snap the old two-regime
        // mark leaked to a sandwiching depositor.
        _buy(m, trader, true, 300_000 * ONE_USDC);
        uint256 q1 = m.totalYesShares();
        uint256 q2 = m.totalNoShares();
        IEventMarket.Outcome minority = q1 >= q2 ? IEventMarket.Outcome.NO : IEventMarket.Outcome.YES;
        uint256 sigma = q1 >= q2 ? q1 - q2 : q2 - q1;
        assertGt(sigma, 300_000 * ONE_USDC, "market is heavily skewed (large would-be snap)");

        // Bob DEPOSITS during the live market (sandwich: in just before the UMA-resolution instant).
        uint256 bobIn = 1_000_000 * ONE_USDC;
        vm.prank(bob);
        uint256 bobShares = vault.deposit(bobIn, bob);
        uint256 bobValueAtEntry = vault.previewRedeem(bobShares);

        // Propose + finalize the MINORITY outcome. NAV must NOT move across this whole window: the
        // mark ignores UMA (no floor→exact snap), and the settle Δ is 0 to the wei.
        uint256 navBeforePropose = vault.totalAssets();
        vm.prank(trader);
        m.proposeResolution(minority);
        m.settleResolution();
        uint256 navAfterFinalize = vault.totalAssets();
        assertEq(navBeforePropose, navAfterFinalize, "NAV identical across UMA propose->finalize (no snap)");

        // The surplus σ = max(q1,q2) − min(q1,q2) sits in the vesting bucket, EXCLUDED from
        // totalAssets. This is the ~$370k-style would-be snap that is NOT skimmable.
        assertEq(vault.unvestedEventSurplus(), sigma, "sigma escrowed in the vesting bucket");
        assertEq(vault.liveEventMarketCount(), 0, "market de-registered");

        // Bob redeems IMMEDIATELY (same instant, pre-vesting): he nets <= dust. The σ was NOT skimmable.
        uint256 bobValueNow = vault.previewRedeem(bobShares);
        assertLe(bobValueNow, bobIn + 10, "late depositor cannot instantly skim the settle surplus");
        assertApproxEqAbs(bobValueNow, bobValueAtEntry, 10, "no instant NAV jump captured by the sandwich");
        console2.log("DEPOSIT ARB (skewed): sigma escrowed (q1-q2) =", sigma);
        console2.log("DEPOSIT ARB (skewed): bob in                 =", bobIn);
        console2.log("DEPOSIT ARB (skewed): bob value instantly    =", bobValueNow);
        console2.log("DEPOSIT ARB (skewed): instant skim (0=closed) =", bobValueNow > bobIn ? bobValueNow - bobIn : 0);

        // Past the FULL vest window, σ has dripped into NAV; bob earns only his fair pro-rata share
        // for HOLDING across the window (legitimate yield, not a timeable snap). (Vesting continues at
        // the fixed rate slightly past T until the floor-division dust is exhausted, so warp T + ε.)
        vm.warp(block.timestamp + 14 days + 1 hours);
        assertEq(vault.unvestedEventSurplus(), 0, "fully vested past the window");
        uint256 bobValueVested = vault.previewRedeem(bobShares);
        assertGt(bobValueVested, bobIn, "held-through-vesting LP earns pro-rata surplus (not an arb)");
        console2.log("DEPOSIT ARB (skewed): bob value after full vest =", bobValueVested);
    }

    // ------------------------------------------------------------------------------------------
    // Zero settle jump across every outcome (YES / NO / VOID), with trading.
    // ------------------------------------------------------------------------------------------

    function testFuzz_settleJumpIsZero(uint8 rawOutcome, uint256 buyAmt, bool buyYes) public {
        IEventMarket.Outcome o = IEventMarket.Outcome(uint8(bound(rawOutcome, 1, 3))); // YES / NO / VOID
        buyAmt = bound(buyAmt, ONE_USDC, 300_000 * ONE_USDC);

        vm.prank(alice);
        vault.deposit(2_000_000 * ONE_USDC, alice);

        EventMarket m = _createMarket(keccak256("e.jump"));
        _buy(m, trader, buyYes, buyAmt);

        // Post the outcome (pre-settle). NAV now uses the EXACT recoverable branch.
        _postOutcome(m.params().eventId, o);
        uint256 navBefore = vault.totalAssets();
        uint256 recoverableBefore = m.currentRecoverable();

        // Settle. Vault balance rises by toReturn; the market leaves the live set.
        m.settleResolution();
        uint256 navAfter = vault.totalAssets();

        // The mark exactly equalled what settle booked → NAV is continuous to the wei.
        assertEq(navBefore, navAfter, "settle must not move NAV");
        assertEq(vault.eventRecoverable(), 0, "no live markets after settle");
        // recoverableBefore was the pre-settle exact mark.
        assertGt(recoverableBefore + 1, 0);
    }

    // ------------------------------------------------------------------------------------------
    // Property: floor (unresolved) <= exact recoverable at EVERY outcome (never over-marks).
    // ------------------------------------------------------------------------------------------

    function testFuzz_floorLeExactAtEveryOutcome(uint256 buyYesAmt, uint256 buyNoAmt) public {
        buyYesAmt = bound(buyYesAmt, ONE_USDC, 30_000 * ONE_USDC);
        buyNoAmt = bound(buyNoAmt, ONE_USDC, 30_000 * ONE_USDC);

        vm.prank(alice);
        vault.deposit(2_000_000 * ONE_USDC, alice);

        EventMarket m = _createMarket(keccak256("e.floor"));
        _tryBuy(m, trader, true, buyYesAmt);
        _tryBuy(m, carol, false, buyNoAmt);
        bytes32 eventId = m.params().eventId;

        // Unresolved floor.
        uma.setLatestValue(0, 0);
        uint256 floorR = m.currentRecoverable();

        // Exact recoverable at each outcome must be >= the floor.
        _postOutcome(eventId, IEventMarket.Outcome.YES);
        assertGe(m.currentRecoverable(), floorR, "floor <= YES recoverable");
        _postOutcome(eventId, IEventMarket.Outcome.NO);
        assertGe(m.currentRecoverable(), floorR, "floor <= NO recoverable");
        _postOutcome(eventId, IEventMarket.Outcome.VOID);
        assertGe(m.currentRecoverable(), floorR, "floor <= VOID recoverable");

        // And the floor never over-marks this market's own cash.
        assertLe(floorR, usdc.balanceOf(address(m)), "floor <= market cash");
    }

    // ------------------------------------------------------------------------------------------
    // Property + concurrent markets: eventRecoverable() <= sum of market USDC balances, and the
    // registry marks every concurrently-live market.
    // ------------------------------------------------------------------------------------------

    function test_concurrentMarkets_neverOverMarkSystemCash() public {
        vm.prank(alice);
        vault.deposit(5_000_000 * ONE_USDC, alice);

        EventMarket[] memory ms = new EventMarket[](3);
        ms[0] = _createMarket(keccak256("e.c0"));
        ms[1] = _createMarket(keccak256("e.c1"));
        ms[2] = _createMarket(keccak256("e.c2"));
        assertEq(vault.liveEventMarketCount(), 3, "3 live markets");

        _buy(ms[0], trader, true, 120_000 * ONE_USDC);
        _buy(ms[1], carol, false, 40_000 * ONE_USDC);
        // Post a losing outcome on one, leave others unresolved (mixed windows).
        _postOutcome(ms[0].params().eventId, IEventMarket.Outcome.YES);

        uint256 recoverable = vault.eventRecoverable();
        uint256 sumCash = _sumMarketBalances(ms);
        assertLe(recoverable, sumCash, "eventRecoverable must not exceed system cash");

        // NAV identity holds.
        assertEq(vault.totalAssets(), vault.freeAssets() + recoverable, "NAV identity");

        // Settle one, the registry shrinks by exactly one via swap-pop, others still marked.
        ms[0].settleResolution();
        assertEq(vault.liveEventMarketCount(), 2, "one market removed");
        assertLe(vault.eventRecoverable(), _sumMarketBalances(ms), "still no over-mark after settle");
    }

    // ------------------------------------------------------------------------------------------
    // Strict I1 holds with a live market (the property Designs 2/3 fail): balance == freeAssets +
    // positionCollateral + insurance + accruedFees.
    // ------------------------------------------------------------------------------------------

    function test_strictI1_holdsWithLiveMarket() public {
        vm.prank(alice);
        vault.deposit(1_000_000 * ONE_USDC, alice);

        // Lock some perp collateral so the non-free buckets are non-zero too.
        usdc.mint(perpEngine, 100_000 * ONE_USDC);
        vm.prank(perpEngine);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(perpEngine);
        vault.lockCollateral(perpEngine, 100_000 * ONE_USDC);

        EventMarket m = _createMarket(keccak256("e.i1"));
        _buy(m, trader, true, 50_000 * ONE_USDC);

        uint256 bal = usdc.balanceOf(address(vault));
        uint256 sum =
            vault.freeAssets() + vault.positionCollateral() + vault.insuranceFundBalance() + vault.accruedFees();
        assertEq(bal, sum, "strict I1 must hold with a live market");

        // NAV strictly exceeds the liquid balance by the live recoverable.
        assertEq(vault.totalAssets(), vault.freeAssets() + vault.eventRecoverable(), "NAV identity with live market");
        assertGt(vault.totalAssets(), vault.freeAssets(), "NAV > liquid while a market is live");
    }

    // ------------------------------------------------------------------------------------------
    // Perp OI cap (capTvl) is invariant to event fund/settle, and profitable perp settle still
    // succeeds when liquid freeAssets covers the pnl.
    // ------------------------------------------------------------------------------------------

    function test_capTvl_invariantAcrossFundAndSettle() public {
        vm.prank(alice);
        vault.deposit(2_000_000 * ONE_USDC, alice);

        uint256 capBefore = vault.capTvl();

        EventMarket m = _createMarket(keccak256("e.cap"));
        assertEq(vault.capTvl(), capBefore, "capTvl invariant to funding");

        _buy(m, trader, true, 10_000 * ONE_USDC);
        _postOutcome(m.params().eventId, IEventMarket.Outcome.NO); // trader loses → seed grows
        m.settleResolution();

        // Event PnL flows to freeAssets; capTvl moves only by realised PnL, not by fund/settle bookkeeping.
        assertGe(vault.capTvl(), capBefore, "capTvl not reduced by fund/settle mechanics");
    }

    function test_perpSettle_stillSucceeds_withLiveMarket() public {
        vm.prank(alice);
        vault.deposit(1_000_000 * ONE_USDC, alice);

        // Open a perp position (lock collateral) via the perpEngine stand-in.
        usdc.mint(perpEngine, 500_000 * ONE_USDC);
        vm.prank(perpEngine);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(perpEngine);
        vault.lockCollateral(perpEngine, 100_000 * ONE_USDC);

        // Fund an event market so liquid freeAssets is reduced by the live seed.
        _createMarket(keccak256("e.perp"));

        // Profitable close: trader profit of $50k is covered by liquid freeAssets.
        uint256 freeBefore = vault.freeAssets();
        assertGt(freeBefore, 50_000 * ONE_USDC, "liquid covers the profit");
        vm.prank(perpEngine);
        vault.settlePosition(trader, 100_000 * ONE_USDC, int256(50_000 * ONE_USDC), 0, 0, 0);
        // freeAssets dropped by the paid profit; the call did not revert despite the live market.
        assertEq(vault.freeAssets(), freeBefore - 50_000 * ONE_USDC, "profit paid from liquid freeAssets");
    }

    // ------------------------------------------------------------------------------------------
    // fundEventMarket registry guards.
    // ------------------------------------------------------------------------------------------

    function test_fund_revertsOnDuplicateMarket() public {
        vm.prank(alice);
        vault.deposit(1_000_000 * ONE_USDC, alice);
        EventMarket m = _createMarket(keccak256("e.dup"));

        // Re-registering the same market from the factory address must revert.
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.MarketAlreadyLive.selector, address(m)));
        vault.fundEventMarket(address(m), 1);
    }

    function test_settle_revertsOnUnknownMarket() public {
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(ILPVault.MarketNotLive.selector, address(0xdead)));
        vault.settleEventMarket(address(0xdead), 1, 0, 0);
    }
}
