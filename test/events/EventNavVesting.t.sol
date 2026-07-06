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

/// @title EventNavVesting — Design 2 (floor mark + receive-only vesting bucket).
/// @notice Non-tautological tests on TRADED, SKEWED markets proving BOTH the redemption and deposit
///         residuals are small/bounded and un-timeable, that settle produces zero NAV jump to the
///         wei, that the settle surplus σ is escrowed (excluded from NAV) and vests monotonically,
///         and that the perp OI cap (capTvl) is byte-identical to the pre-refactor formula.
contract EventNavVestingTest is Test {
    LPVault internal vault;
    EventMarketFactory internal factory;
    EventMarket internal marketImpl;
    MockUSDC internal usdc;
    MockFeedbackController internal feedback;
    MockUMAAdapter internal uma;

    address internal governance = makeAddr("governance");
    address internal operator = makeAddr("operator");
    address internal perpEngine = makeAddr("perpEngine");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal trader = makeAddr("trader");

    uint32 internal constant TIMELOCK = 1 days;
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant LMSR_B = 10_000e6;
    uint64 internal constant DEADLINE = 2_000_000_000;
    uint256 internal constant VEST = 7 days; // DEFAULT_EVENT_SURPLUS_VEST_WINDOW
    uint256 internal constant DUST = 10; // 1e-5 USDC tolerance for round-trip residuals

    bytes32 internal constant SUBJECT_ID = keccak256("subject.drake");

    function setUp() public {
        vm.warp(1_900_000_000);
        usdc = new MockUSDC();

        LPVault vaultImpl = new LPVault();
        bytes memory vInit = abi.encodeCall(
            LPVault.initialize,
            (IERC20(address(usdc)), governance, operator, TIMELOCK, "People Markets LP USDC", "pmUSDC")
        );
        vault = LPVault(address(new ERC1967Proxy(address(vaultImpl), vInit)));

        vm.prank(governance);
        vault.proposeSetPerpEngine(perpEngine);
        vm.warp(block.timestamp + TIMELOCK);
        vault.activateSetPerpEngine();

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

        vm.prank(governance);
        vault.proposeSetEventMarketFactory(address(factory));
        vm.warp(block.timestamp + TIMELOCK);
        vault.activateSetEventMarketFactory();

        address[4] memory people = [alice, bob, carol, trader];
        for (uint256 i; i < people.length; ++i) {
            usdc.mint(people[i], 30_000_000 * ONE_USDC);
            vm.prank(people[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _createMarket(bytes32 eventId) internal returns (EventMarket m) {
        vm.prank(governance);
        m = EventMarket(factory.createMarket(SUBJECT_ID, eventId, uint8(1), "Q?", DEADLINE, 0, LMSR_B));
    }

    function _buy(EventMarket m, address who, bool isYes, uint256 amt) internal {
        vm.startPrank(who);
        usdc.approve(address(m), amt);
        try m.buyOutcome(isYes, amt, 0) {} catch {}
        vm.stopPrank();
    }

    function _liquidRaw() internal view returns (uint256) {
        return usdc.balanceOf(address(vault)) - vault.positionCollateral() - vault.insuranceFundBalance()
            - vault.accruedFees();
    }

    /// @dev The MINORITY-share outcome is the vault-favourable one: resolving it means the AMM pays
    ///      only the smaller `min(q1,q2)`, keeping the spread `σ = max(q1,q2) − min(q1,q2)`.
    ///      NOTE: in LMSR the CHEAP side buys far more shares per USDC, so which of q1/q2 is larger is
    ///      not simply "which got more USDC" — we read the realised share counts and pick dynamically.
    function _minorityOutcomeAndSigma(EventMarket m)
        internal
        view
        returns (IEventMarket.Outcome minority, uint256 sigma)
    {
        uint256 q1 = m.totalYesShares();
        uint256 q2 = m.totalNoShares();
        if (q1 >= q2) {
            minority = IEventMarket.Outcome.NO; // NO has fewer shares → liability q2 = min
            sigma = q1 - q2;
        } else {
            minority = IEventMarket.Outcome.YES; // YES has fewer shares → liability q1 = min
            sigma = q2 - q1;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // (a) SKEWED-TRADED no-snap: NAV(before UMA propose) == NAV(after finalize) to the wei; a
    //     deposit-before-settle / redeem-after-settle round trip nets <= dust; σ ≈ (max−min) sits in
    //     eventSurplusPrincipal and is EXCLUDED from totalAssets.
    // ---------------------------------------------------------------------------------------------

    function test_a_skewedTraded_noSnap_surplusEscrowedAndExcluded() public {
        vm.prank(alice);
        vault.deposit(2_000_000 * ONE_USDC, alice);

        EventMarket m = _createMarket(keccak256("v.a"));
        // REAL, heavily one-sided YES book (q1 >> q2): this is the skewed market whose floor→exact
        // surplus was the ~$370k depositor windfall under the old two-regime mark.
        _buy(m, trader, true, 400_000 * ONE_USDC);
        (IEventMarket.Outcome minority, uint256 sigma) = _minorityOutcomeAndSigma(m);
        assertGt(sigma, 350_000 * ONE_USDC, "large trade-induced spread (the would-be windfall)");

        // Round-trip depositor: in before settle, out after settle.
        uint256 bobIn = 1_000_000 * ONE_USDC;
        vm.prank(bob);
        uint256 bobShares = vault.deposit(bobIn, bob);

        uint256 navBeforePropose = vault.totalAssets();

        // Propose + finalize the MINORITY (vault-favourable) outcome → σ = |q1 − q2| escrowed.
        vm.prank(trader);
        m.proposeResolution(minority);
        m.settleResolution();

        // Mark ignores UMA and settle Δ == 0 → NAV identical to the wei across the whole window.
        assertEq(vault.totalAssets(), navBeforePropose, "no NAV snap across UMA propose->finalize");

        // σ escrowed in the vesting bucket and EXCLUDED from totalAssets.
        assertEq(vault.unvestedEventSurplus(), sigma, "sigma in eventSurplusPrincipal");
        // totalAssets == freeAssets + eventRecoverable(=0 now), and freeAssets excludes the unvested σ.
        assertEq(vault.totalAssets(), vault.freeAssets(), "surplus excluded from NAV (no live markets)");
        assertEq(_liquidRaw(), vault.freeAssets() + sigma, "liquidRaw = freeAssets + unvested (5th bucket)");

        // Round trip nets <= dust immediately (before any vesting).
        uint256 bobValue = vault.previewRedeem(bobShares);
        assertLe(bobValue, bobIn + DUST, "round-trip depositor nets <= dust (deposit arb closed)");
        console2.log("(a) sigma escrowed (q1-q2)      =", sigma);
        console2.log("(a) bob round-trip in           =", bobIn);
        console2.log("(a) bob value immediately after =", bobValue);
    }

    // ---------------------------------------------------------------------------------------------
    // (b) Informed-redeemer bound: with the MAJORITY (LP-losing) outcome known during UMA liveness,
    //     an informed pre-settle redeemer extracts <= dust vs a post-settle redeemer — the floor mark
    //     (<= realized in every state) gives no timing edge. Extraction asserted == 0.
    // ---------------------------------------------------------------------------------------------

    function test_b_informedRedeemer_majorityKnown_extractsZero() public {
        // Two equal LPs: alice (informed, redeems pre-settle) and bob (control, values post-settle).
        vm.prank(alice);
        vault.deposit(1_000_000 * ONE_USDC, alice);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(1_000_000 * ONE_USDC, bob);

        EventMarket m = _createMarket(keccak256("v.b"));
        // Heavy one-sided YES buy: the MAJORITY-share outcome (YES) is LP-losing. If it resolves the
        // AMM pays q1 == max(q1,q2) → σ == 0 and floor == realized exactly, so knowing it gives no edge.
        _buy(m, trader, true, 250_000 * ONE_USDC);
        assertEq(m.totalNoShares(), 0, "one-sided book: YES is the majority outcome");

        // MAJORITY (LP-losing) outcome becomes known during UMA liveness.
        uma.setLatestValue(uint256(IEventMarket.Outcome.YES), uint64(block.timestamp));

        // Informed alice redeems her max liquid slice PRE-settle (mark == floor, ignores the known UMA).
        uint256 slice = vault.maxRedeem(alice);
        assertGt(slice, 0, "alice has a redeemable slice");
        vm.prank(alice);
        uint256 aliceOut = vault.redeem(slice, alice, alice);
        uint256 alicePps = aliceOut * 1e18 / slice;

        // Settle for real. Majority YES → liability == q1 == max(q1,q2) → σ == 0, nothing escrowed.
        m.settleResolution();
        assertEq(vault.unvestedEventSurplus(), 0, "no surplus on a majority (LP-losing) outcome");

        // Control: bob's fair post-settle per-share (NAV-based, no liquidity cap). The informed
        // pre-settle redeemer got NO better than this: the floor mark was <= realized in every state.
        uint256 bobPps = vault.previewRedeem(bobShares) * 1e18 / bobShares;
        assertLe(alicePps, bobPps + 1, "informed pre-settle redeemer has no edge (floor <= realized)");
        uint256 extraction = alicePps > bobPps ? alicePps - bobPps : 0;
        assertEq(extraction, 0, "informed-redeemer extraction == 0");
        console2.log("(b) informed alice pps  =", alicePps);
        console2.log("(b) control  bob   pps  =", bobPps);
        console2.log("(b) extraction (0=none) =", extraction);
    }

    // ---------------------------------------------------------------------------------------------
    // (d) Settle-continuity fuzz: random skew × outcome ⇒ |Δ totalAssets across the settle tx| == 0
    //     (to the wei), and σ == the floor→exact surplus lands in the vesting bucket.
    // ---------------------------------------------------------------------------------------------

    function testFuzz_d_settleContinuity(uint8 rawOutcome, uint256 yesAmt, uint256 noAmt) public {
        IEventMarket.Outcome o = IEventMarket.Outcome(uint8(bound(rawOutcome, 1, 3))); // YES/NO/VOID
        yesAmt = bound(yesAmt, ONE_USDC, 500_000 * ONE_USDC);
        noAmt = bound(noAmt, ONE_USDC, 500_000 * ONE_USDC);

        vm.prank(alice);
        vault.deposit(3_000_000 * ONE_USDC, alice);

        EventMarket m = _createMarket(keccak256("v.d"));
        _buy(m, trader, true, yesAmt);
        _buy(m, carol, false, noAmt);
        uint256 q1 = m.totalYesShares();
        uint256 q2 = m.totalNoShares();

        uint256 unvestedBefore = vault.unvestedEventSurplus();
        uint256 navBefore = vault.totalAssets();

        uma.setLatestValue(uint256(o), uint64(block.timestamp));
        m.settleResolution();

        // |Δ totalAssets| across the settle tx is 0 to the wei.
        assertEq(vault.totalAssets(), navBefore, "settle must not move NAV (any skew, any outcome)");

        // σ landed in the bucket = max(q1,q2) − liability(outcome).
        uint256 maxQ = q1 > q2 ? q1 : q2;
        uint256 liab = o == IEventMarket.Outcome.YES ? q1 : o == IEventMarket.Outcome.NO ? q2 : (q1 + q2) / 2;
        uint256 sigma = maxQ - liab;
        assertEq(vault.unvestedEventSurplus(), unvestedBefore + sigma, "sigma escrowed == floor->exact surplus");
    }

    // ---------------------------------------------------------------------------------------------
    // (e) Monotone drip: unvested strictly non-increasing between settles; no single-tx NAV jump >
    //     dust; per-interval Δ NAV <= (P/T)·Δt.
    // ---------------------------------------------------------------------------------------------

    function test_e_monotoneDrip_boundedByRate() public {
        vm.prank(alice);
        vault.deposit(2_000_000 * ONE_USDC, alice);

        EventMarket m = _createMarket(keccak256("v.e"));
        _buy(m, trader, true, 400_000 * ONE_USDC); // heavily one-sided → large σ to drip
        (IEventMarket.Outcome minority, uint256 sigma) = _minorityOutcomeAndSigma(m);
        assertGt(sigma, 350_000 * ONE_USDC, "large surplus to drip");

        uma.setLatestValue(uint256(minority), uint64(block.timestamp));
        m.settleResolution();

        assertEq(vault.unvestedEventSurplus(), sigma, "full sigma unvested at settle");
        uint256 rate = sigma / VEST; // r = P / T

        uint256 prevUnvested = vault.unvestedEventSurplus();
        uint256 prevNav = vault.totalAssets();
        uint256 step = 12 hours;
        for (uint256 i; i < 15; ++i) {
            vm.warp(block.timestamp + step);
            uint256 u = vault.unvestedEventSurplus();
            uint256 nav = vault.totalAssets();
            // Unvested strictly non-increasing.
            assertLe(u, prevUnvested, "unvested non-increasing between settles");
            // Per-interval NAV gain is bounded by rate*Δt (+1 wei rounding) and never a big jump.
            uint256 dNav = nav - prevNav;
            assertLe(dNav, rate * step + 1, "per-interval dNAV <= (P/T)*dt");
            prevUnvested = u;
            prevNav = nav;
        }
        // Eventually fully vested.
        vm.warp(block.timestamp + VEST);
        assertEq(vault.unvestedEventSurplus(), 0, "fully vested");
    }

    // ---------------------------------------------------------------------------------------------
    // (f) capTvl byte-identical: capTvl() == _liquidRaw + eventFundedSeed across fund/settle, i.e.
    //     UNCHANGED by the freeAssets refactor (it does NOT subtract the unvested surplus).
    // ---------------------------------------------------------------------------------------------

    function test_f_capTvl_byteIdentical_acrossFundAndSettle() public {
        vm.prank(alice);
        vault.deposit(2_000_000 * ONE_USDC, alice);

        // Old formula == new: capTvl == (balance - buckets) + eventFundedSeed at every step.
        assertEq(vault.capTvl(), _liquidRaw() + vault.eventFundedSeed(), "capTvl == liquidRaw + seed (pre-fund)");

        EventMarket m = _createMarket(keccak256("v.f"));
        assertEq(vault.capTvl(), _liquidRaw() + vault.eventFundedSeed(), "capTvl == liquidRaw + seed (funded)");

        _buy(m, trader, true, 400_000 * ONE_USDC);
        _buy(m, carol, false, 20_000 * ONE_USDC);
        (IEventMarket.Outcome minority,) = _minorityOutcomeAndSigma(m);

        uma.setLatestValue(uint256(minority), uint64(block.timestamp));
        m.settleResolution();

        // Post-settle a large σ is unvested; capTvl must NOT be reduced by it (perp OI capacity intact).
        assertGt(vault.unvestedEventSurplus(), 0, "surplus is unvested");
        assertEq(vault.capTvl(), _liquidRaw() + vault.eventFundedSeed(), "capTvl == liquidRaw + seed (post-settle)");
        assertEq(
            vault.capTvl(),
            vault.freeAssets() + vault.unvestedEventSurplus() + vault.eventFundedSeed(),
            "capTvl includes the unvested surplus (freeAssets does not)"
        );
    }
}
