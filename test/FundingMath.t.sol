// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {FundingMath} from "../src/libraries/FundingMath.sol";

/// @dev External harness exposing each internal pure of `FundingMath` at external-pure visibility.
///      Matches the pattern from `test/LiquidationMath.t.sol` so the call depth exceeds the
///      cheatcode frame and `vm.expectRevert` / equality checks land correctly.
contract Harness {
    function rate(
        uint256 mark1e18,
        uint256 index1e18,
        int256 sentimentScore_e18,
        uint256 longOi6,
        uint256 shortOi6,
        int256 kPremium_e18,
        int256 kSentiment_e18,
        int256 kSkew_e18,
        int256 fMaxPerHour_e18
    )
        external
        pure
        returns (FundingMath.FundingTerms memory)
    {
        return FundingMath.computeFundingRate(
            mark1e18,
            index1e18,
            sentimentScore_e18,
            longOi6,
            shortOi6,
            kPremium_e18,
            kSentiment_e18,
            kSkew_e18,
            fMaxPerHour_e18
        );
    }

    function delta(int256 fundingRate_e18, uint64 elapsedSeconds) external pure returns (int256) {
        return FundingMath.computeIndexDelta(fundingRate_e18, elapsedSeconds);
    }

    function debt(int256 size_1e6, int256 currentIndex_e18, int256 entryIndex_e18) external pure returns (int256) {
        return FundingMath.computeFundingDebt(size_1e6, currentIndex_e18, entryIndex_e18);
    }
}

/// @dev Tests target 100% line + branch coverage on src/libraries/FundingMath.sol.
///
///      Spec midpoints (mechanismdesign.md §2 lines 70-77):
///        - kPremium   = 1.25e16  (1.25%)
///        - kSentiment = 4e15     (0.4%)
///        - kSkew      = 3e15     (0.3%)
///        - fMaxPerHour = 7.5e14  (0.075%/h)
contract FundingMathTest is Test {
    Harness internal h;

    int256 internal constant ONE_E18 = 1e18;
    uint256 internal constant ONE_E18_U = 1e18;
    int256 internal constant ONE_E6 = 1e6;

    // Spec midpoints.
    int256 internal constant K_PREMIUM = 1.25e16;
    int256 internal constant K_SENTIMENT = 4e15;
    int256 internal constant K_SKEW = 3e15;
    int256 internal constant F_MAX = 7.5e14;

    function setUp() public {
        h = new Harness();
    }

    // ------------------------------------------------------------------------------------------
    // computeFundingRate — zero / boundary inputs
    // ------------------------------------------------------------------------------------------

    /// @dev Branch 1: `index1e18 == 0` short-circuits to all-zero `FundingTerms`. Every field
    ///      MUST be zero including `clamped` — a kill-switch caller treats this as "skip".
    function test_Rate_IndexZeroReturnsAllZeros() public view {
        FundingMath.FundingTerms memory t =
            h.rate(100 * ONE_E18_U, 0, 0.5e18, 1_000_000, 500_000, K_PREMIUM, K_SENTIMENT, K_SKEW, F_MAX);
        assertEq(t.premiumComponent_e18, 0);
        assertEq(t.sentimentComponent_e18, 0);
        assertEq(t.skewComponent_e18, 0);
        assertEq(t.totalRate_e18, 0);
        assertFalse(t.clamped);
    }

    /// @dev All zero inputs (besides `index`) produce a zero rate. Useful smoke test for the
    ///      additive-identity behavior of each component.
    function test_Rate_AllZeroExceptIndexIsZero() public view {
        FundingMath.FundingTerms memory t = h.rate(100 * ONE_E18_U, 100 * ONE_E18_U, 0, 0, 0, 0, 0, 0, F_MAX);
        assertEq(t.totalRate_e18, 0);
        assertFalse(t.clamped);
        assertEq(t.premiumComponent_e18, 0);
        assertEq(t.sentimentComponent_e18, 0);
        assertEq(t.skewComponent_e18, 0);
    }

    /// @dev `mark == index` collapses the premium term to 0 even if `kPremium` is non-zero.
    function test_Rate_MarkEqualsIndexPremiumIsZero() public view {
        FundingMath.FundingTerms memory t =
            h.rate(100 * ONE_E18_U, 100 * ONE_E18_U, 0, 1_000_000, 1_000_000, K_PREMIUM, K_SENTIMENT, K_SKEW, F_MAX);
        assertEq(t.premiumComponent_e18, 0);
        assertEq(t.skewComponent_e18, 0); // balanced book ⇒ zero skew
        assertEq(t.totalRate_e18, 0);
        assertFalse(t.clamped);
    }

    // ------------------------------------------------------------------------------------------
    // computeFundingRate — premium component
    // ------------------------------------------------------------------------------------------

    /// @dev Positive premium (mark > index) produces a positive premium component scaled by k.
    ///      mark=1.05e18, index=1.00e18 ⇒ premium = 0.05e18 ⇒ comp = 1.25e16 × 0.05 = 6.25e14.
    function test_Rate_PremiumPositive() public view {
        FundingMath.FundingTerms memory t = h.rate(1.05e18, 1.0e18, 0, 0, 0, K_PREMIUM, 0, 0, F_MAX);
        // 1.25e16 * 0.05e18 / 1e18 = 6.25e14
        assertEq(t.premiumComponent_e18, 6.25e14);
        assertEq(t.sentimentComponent_e18, 0);
        assertEq(t.skewComponent_e18, 0);
        assertEq(t.totalRate_e18, 6.25e14);
        assertFalse(t.clamped);
    }

    /// @dev Negative premium (mark < index) produces a negative premium component.
    function test_Rate_PremiumNegative() public view {
        FundingMath.FundingTerms memory t = h.rate(0.95e18, 1.0e18, 0, 0, 0, K_PREMIUM, 0, 0, F_MAX);
        // 1.25e16 * (-0.05e18) / 1e18 = -6.25e14
        assertEq(t.premiumComponent_e18, -6.25e14);
        assertEq(t.totalRate_e18, -6.25e14);
        assertFalse(t.clamped);
    }

    /// @dev Negative `kPremium` flips the sign of the component for a positive premium. The
    ///      library does not police coefficient signs — the engine bounds enforcement does.
    function test_Rate_PremiumWithNegativeKPremium() public view {
        FundingMath.FundingTerms memory t = h.rate(1.05e18, 1.0e18, 0, 0, 0, -K_PREMIUM, 0, 0, F_MAX);
        assertEq(t.premiumComponent_e18, -6.25e14);
        assertEq(t.totalRate_e18, -6.25e14);
    }

    // ------------------------------------------------------------------------------------------
    // computeFundingRate — sentiment component
    // ------------------------------------------------------------------------------------------

    /// @dev Sentiment +1e18 (maximum bullish) at the midpoint k yields the full sentiment band.
    ///      4e15 × 1e18 / 1e18 = 4e15.
    function test_Rate_SentimentPositiveMax() public view {
        FundingMath.FundingTerms memory t = h.rate(1e18, 1e18, ONE_E18, 0, 0, 0, K_SENTIMENT, 0, 1e18);
        assertEq(t.sentimentComponent_e18, K_SENTIMENT);
        assertEq(t.totalRate_e18, K_SENTIMENT);
        assertFalse(t.clamped);
    }

    /// @dev Sentiment -1e18 (maximum bearish) flips the sign.
    function test_Rate_SentimentNegativeMax() public view {
        FundingMath.FundingTerms memory t = h.rate(1e18, 1e18, -ONE_E18, 0, 0, 0, K_SENTIMENT, 0, 1e18);
        assertEq(t.sentimentComponent_e18, -K_SENTIMENT);
        assertEq(t.totalRate_e18, -K_SENTIMENT);
    }

    /// @dev Sentiment is passed through — values outside [-1e18, 1e18] are NOT enforced here.
    ///      Test asserts the library accepts +2e18 (engine prevents this in practice).
    function test_Rate_SentimentOutOfRangeUnenforced() public view {
        FundingMath.FundingTerms memory t = h.rate(1e18, 1e18, 2e18, 0, 0, 0, K_SENTIMENT, 0, 1e18);
        // 4e15 * 2e18 / 1e18 = 8e15
        assertEq(t.sentimentComponent_e18, 8e15);
    }

    // ------------------------------------------------------------------------------------------
    // computeFundingRate — skew component
    // ------------------------------------------------------------------------------------------

    /// @dev Long-heavy book ⇒ positive skew. longOi=6e6, shortOi=4e6 ⇒ skew = +0.2e18 ⇒ comp = 6e14.
    function test_Rate_SkewLongHeavy() public view {
        FundingMath.FundingTerms memory t = h.rate(1e18, 1e18, 0, 6_000_000, 4_000_000, 0, 0, K_SKEW, F_MAX);
        // 3e15 * 0.2e18 / 1e18 = 6e14
        assertEq(t.skewComponent_e18, 6e14);
        assertEq(t.totalRate_e18, 6e14);
        assertFalse(t.clamped);
    }

    /// @dev Short-heavy book ⇒ negative skew.
    function test_Rate_SkewShortHeavy() public view {
        FundingMath.FundingTerms memory t = h.rate(1e18, 1e18, 0, 4_000_000, 6_000_000, 0, 0, K_SKEW, F_MAX);
        assertEq(t.skewComponent_e18, -6e14);
        assertEq(t.totalRate_e18, -6e14);
    }

    /// @dev Balanced book ⇒ skew == 0 even with non-zero kSkew.
    function test_Rate_SkewBalancedIsZero() public view {
        FundingMath.FundingTerms memory t = h.rate(1e18, 1e18, 0, 5_000_000, 5_000_000, 0, 0, K_SKEW, F_MAX);
        assertEq(t.skewComponent_e18, 0);
    }

    /// @dev Zero total OI ⇒ skew bypasses the divide-by-zero branch and stays at 0.
    function test_Rate_SkewZeroTotalOiNoDivByZero() public view {
        FundingMath.FundingTerms memory t = h.rate(1e18, 1e18, 0, 0, 0, 0, 0, K_SKEW, F_MAX);
        assertEq(t.skewComponent_e18, 0);
        assertEq(t.totalRate_e18, 0);
    }

    /// @dev One side zero — skew saturates. longOi=10e6, shortOi=0 ⇒ skew = +1e18 ⇒ comp = kSkew.
    function test_Rate_SkewOneSidedLongs() public view {
        FundingMath.FundingTerms memory t = h.rate(1e18, 1e18, 0, 10_000_000, 0, 0, 0, K_SKEW, F_MAX);
        assertEq(t.skewComponent_e18, K_SKEW);
    }

    function test_Rate_SkewOneSidedShorts() public view {
        FundingMath.FundingTerms memory t = h.rate(1e18, 1e18, 0, 0, 10_000_000, 0, 0, K_SKEW, F_MAX);
        assertEq(t.skewComponent_e18, -K_SKEW);
    }

    // ------------------------------------------------------------------------------------------
    // computeFundingRate — composite (all three components together)
    // ------------------------------------------------------------------------------------------

    /// @dev Worked example from the library's contract-level NatSpec. All three terms positive,
    ///      total within the F_MAX envelope.
    ///        premium    = (1.05 - 1.00) / 1.00            = 0.05e18
    ///        premiumComp= 1.25e16 * 0.05e18 / 1e18         = 6.25e14
    ///        sentiment  = +0.5e18
    ///        sentComp   = 4e15 * 0.5e18 / 1e18             = 2e15
    ///        skew       = (6 - 4) / 10                     = 0.2e18
    ///        skewComp   = 3e15 * 0.2e18 / 1e18             = 6e14
    ///        sum        = 6.25e14 + 2e15 + 6e14            = 3.225e15
    ///
    ///      F_MAX (7.5e14) would clamp this, so use a wider envelope here (1e16) so the worked
    ///      example demonstrates the unclamped path.
    function test_Rate_LongHeavyMarkAboveIndexAllPositive() public view {
        FundingMath.FundingTerms memory t = h.rate(
            1.05e18,
            1.0e18,
            0.5e18,
            6_000_000,
            4_000_000,
            K_PREMIUM,
            K_SENTIMENT,
            K_SKEW,
            1e16 // wider envelope to avoid clamping
        );
        assertEq(t.premiumComponent_e18, 6.25e14);
        assertEq(t.sentimentComponent_e18, 2e15);
        assertEq(t.skewComponent_e18, 6e14);
        assertEq(t.totalRate_e18, 6.25e14 + 2e15 + 6e14);
        assertFalse(t.clamped);
        assertGt(t.totalRate_e18, 0);
    }

    /// @dev Mirror of the long-heavy case with the signs flipped: short-heavy book, mark below
    ///      index, bearish sentiment. The total is the additive inverse of the prior test.
    function test_Rate_ShortHeavyMarkBelowIndexAllNegative() public view {
        FundingMath.FundingTerms memory t =
            h.rate(0.95e18, 1.0e18, -0.5e18, 4_000_000, 6_000_000, K_PREMIUM, K_SENTIMENT, K_SKEW, 1e16);
        assertEq(t.premiumComponent_e18, -6.25e14);
        assertEq(t.sentimentComponent_e18, -2e15);
        assertEq(t.skewComponent_e18, -6e14);
        assertEq(t.totalRate_e18, -(6.25e14 + 2e15 + 6e14));
        assertFalse(t.clamped);
        assertLt(t.totalRate_e18, 0);
    }

    // ------------------------------------------------------------------------------------------
    // computeFundingRate — clamping
    // ------------------------------------------------------------------------------------------

    /// @dev Extreme positive premium pushes the unclamped sum above F_MAX.
    ///        mark = 2.0e18, index = 1.0e18 ⇒ premium = 1.0e18 ⇒ premiumComp = 1.25e16.
    ///        With F_MAX = 7.5e14, the result clamps to +F_MAX with `clamped = true`.
    function test_Rate_ClampUpper() public view {
        FundingMath.FundingTerms memory t = h.rate(2e18, 1e18, 0, 0, 0, K_PREMIUM, 0, 0, F_MAX);
        assertEq(t.totalRate_e18, F_MAX);
        assertTrue(t.clamped);
    }

    /// @dev Extreme negative premium clamps at the lower bound.
    function test_Rate_ClampLower() public view {
        FundingMath.FundingTerms memory t = h.rate(0.1e18, 1e18, 0, 0, 0, K_PREMIUM, 0, 0, F_MAX);
        assertEq(t.totalRate_e18, -F_MAX);
        assertTrue(t.clamped);
    }

    /// @dev Exactly at the upper bound — must NOT set `clamped`. Sum is `+F_MAX`, no clamping.
    function test_Rate_AtUpperBoundNotClamped() public view {
        // Construct a sum exactly equal to F_MAX. Use a single component for clarity:
        // kPremium × premium / 1e18 = F_MAX ⇒ premium = F_MAX × 1e18 / kPremium = 7.5e14 × 1e18 / 1.25e16 = 6e16.
        // Choose mark/index so (mark - index) * 1e18 / index = 6e16 ⇒ mark = index + 0.06 * index = 1.06e18.
        FundingMath.FundingTerms memory t = h.rate(1.06e18, 1e18, 0, 0, 0, K_PREMIUM, 0, 0, F_MAX);
        assertEq(t.totalRate_e18, F_MAX);
        assertFalse(t.clamped);
    }

    /// @dev Exactly at the lower bound — same logic, no clamping flag.
    function test_Rate_AtLowerBoundNotClamped() public view {
        FundingMath.FundingTerms memory t = h.rate(0.94e18, 1e18, 0, 0, 0, K_PREMIUM, 0, 0, F_MAX);
        assertEq(t.totalRate_e18, -F_MAX);
        assertFalse(t.clamped);
    }

    /// @dev Negative fMaxPerHour input — library treats `|fMax|` as the symmetric envelope, so a
    ///      negative value behaves the same as its positive counterpart. Documented in NatSpec.
    function test_Rate_NegativeFMaxBehavesAsAbs() public view {
        FundingMath.FundingTerms memory t = h.rate(2e18, 1e18, 0, 0, 0, K_PREMIUM, 0, 0, -F_MAX);
        assertEq(t.totalRate_e18, F_MAX);
        assertTrue(t.clamped);
    }

    /// @dev `fMax == 0` collapses every rate to zero and flags `clamped` only when there's
    ///      something to clamp (premium is non-zero).
    function test_Rate_ZeroFMaxKillsRate() public view {
        FundingMath.FundingTerms memory t = h.rate(1.05e18, 1e18, 0, 0, 0, K_PREMIUM, 0, 0, 0);
        assertEq(t.totalRate_e18, 0);
        assertTrue(t.clamped);
    }

    /// @dev `fMax == 0` with no non-zero components yields zero AND `clamped == false`
    ///      (unclamped == 0 is within [0, 0]).
    function test_Rate_ZeroFMaxAndZeroComponentsNotClamped() public view {
        FundingMath.FundingTerms memory t = h.rate(1e18, 1e18, 0, 0, 0, K_PREMIUM, K_SENTIMENT, K_SKEW, 0);
        assertEq(t.totalRate_e18, 0);
        assertFalse(t.clamped);
    }

    // ------------------------------------------------------------------------------------------
    // computeIndexDelta
    // ------------------------------------------------------------------------------------------

    /// @dev delta over exactly one hour returns the rate verbatim.
    function test_Delta_OneHourReturnsRate() public view {
        assertEq(h.delta(F_MAX, 3600), F_MAX);
    }

    /// @dev Half-hour returns half the rate.
    function test_Delta_HalfHour() public view {
        assertEq(h.delta(F_MAX, 1800), F_MAX / 2);
    }

    /// @dev Two hours returns twice the rate.
    function test_Delta_TwoHours() public view {
        assertEq(h.delta(F_MAX, 7200), F_MAX * 2);
    }

    /// @dev Negative rate produces negative delta with the same magnitude semantics.
    function test_Delta_NegativeRate() public view {
        assertEq(h.delta(-F_MAX, 3600), -F_MAX);
        assertEq(h.delta(-F_MAX, 1800), -F_MAX / 2);
    }

    /// @dev Zero elapsed ⇒ zero delta, regardless of rate.
    function test_Delta_ZeroElapsedIsZero() public view {
        assertEq(h.delta(F_MAX, 0), 0);
        assertEq(h.delta(-F_MAX, 0), 0);
    }

    /// @dev Zero rate ⇒ zero delta, regardless of elapsed.
    function test_Delta_ZeroRateIsZero() public view {
        assertEq(h.delta(0, 3600), 0);
        assertEq(h.delta(0, 0), 0);
    }

    /// @dev Sub-hour fractions truncate. 1 second of F_MAX at 1e18 scale = F_MAX / 3600.
    function test_Delta_OneSecond() public view {
        assertEq(h.delta(F_MAX, 1), F_MAX / 3600);
    }

    // ------------------------------------------------------------------------------------------
    // computeFundingDebt — sign-quadrant table
    // ------------------------------------------------------------------------------------------

    /// @dev Long with positive index growth pays funding. size = +10e6 (10 contracts), entry=0,
    ///      current=+1e15 ⇒ debt6 = 10e6 × 1e15 / 1e18 = 10_000 (positive, paid).
    function test_Debt_LongPaysOnPositiveGrowth() public view {
        int256 debt = h.debt(int256(10) * ONE_E6, 1e15, 0);
        assertEq(debt, 10_000);
        assertGt(debt, 0);
    }

    /// @dev Long with negative index growth receives funding (negative debt).
    function test_Debt_LongReceivesOnNegativeGrowth() public view {
        int256 debt = h.debt(int256(10) * ONE_E6, -1e15, 0);
        assertEq(debt, -10_000);
        assertLt(debt, 0);
    }

    /// @dev Short with positive growth receives funding.
    function test_Debt_ShortReceivesOnPositiveGrowth() public view {
        int256 debt = h.debt(-int256(10) * ONE_E6, 1e15, 0);
        assertEq(debt, -10_000);
        assertLt(debt, 0);
    }

    /// @dev Short with negative growth pays funding.
    function test_Debt_ShortPaysOnNegativeGrowth() public view {
        int256 debt = h.debt(-int256(10) * ONE_E6, -1e15, 0);
        assertEq(debt, 10_000);
        assertGt(debt, 0);
    }

    /// @dev Zero size ⇒ zero debt.
    function test_Debt_ZeroSize() public view {
        assertEq(h.debt(0, 1e15, 0), 0);
    }

    /// @dev Entry == current ⇒ zero debt regardless of size.
    function test_Debt_EntryEqualsCurrent() public view {
        assertEq(h.debt(int256(10) * ONE_E6, 1e15, 1e15), 0);
        assertEq(h.debt(-int256(10) * ONE_E6, -1e15, -1e15), 0);
    }

    /// @dev Non-zero entry: debt should be size × (current - entry) / 1e18.
    ///      size = +5e6, entry = 1e15, current = 3e15 ⇒ growth = 2e15
    ///      ⇒ debt = 5e6 × 2e15 / 1e18 = 10_000.
    function test_Debt_NonZeroEntry() public view {
        assertEq(h.debt(int256(5) * ONE_E6, 3e15, 1e15), 10_000);
    }

    /// @dev Realistic perp scale: 1 contract = 1e6, position $10K notional at $100 mark ⇒
    ///      size = $10K * 1e18 / $100 = 1e20, but in 1e6 units that's 100e6. Index moves
    ///      0.001e18 = 1e15 over the holding window. debt6 = 100e6 × 1e15 / 1e18 = 100_000
    ///      = $0.10 per the funding rate. Sanity check the order of magnitude.
    function test_Debt_RealisticScale() public view {
        int256 size = int256(100) * ONE_E6;
        int256 currentIdx = 1e15;
        int256 entryIdx = 0;
        // 100e6 × 1e15 / 1e18 = 100_000 (6-dec USDC = $0.10).
        assertEq(h.debt(size, currentIdx, entryIdx), 100_000);
    }

    // ------------------------------------------------------------------------------------------
    // Composite sanity — wire all three primitives end-to-end
    // ------------------------------------------------------------------------------------------

    /// @dev "Long-heavy book with mark above index ⇒ positive rate ⇒ cumulative index grows ⇒
    ///       longs pay shorts ⇒ longs see positive funding debt at close."
    ///
    ///      Verifies all three library primitives compose correctly with consistent sign
    ///      conventions. This is the load-bearing test for the worked example in the contract
    ///      NatSpec.
    function test_Composite_LongHeavyAboveIndexCascadesToPositiveDebt() public view {
        // Step A: compute the rate. Use the wider envelope so we get the unclamped value.
        FundingMath.FundingTerms memory terms =
            h.rate(1.05e18, 1.0e18, 0.5e18, 6_000_000, 4_000_000, K_PREMIUM, K_SENTIMENT, K_SKEW, 1e16);
        assertGt(terms.totalRate_e18, 0);

        // Step B: integrate over 1 hour to get the index delta.
        int256 indexDelta = h.delta(terms.totalRate_e18, 3600);
        assertGt(indexDelta, 0);
        // Sanity: delta == rate over exactly one hour.
        assertEq(indexDelta, terms.totalRate_e18);

        // Step C: a long that opened with `entryFundingIndex = 0` and held through the hour
        // pays funding (positive debt).
        int256 longDebt = h.debt(int256(10) * ONE_E6, indexDelta, 0);
        assertGt(longDebt, 0);

        // Step D: symmetrically, a short of equal magnitude receives funding.
        int256 shortDebt = h.debt(-int256(10) * ONE_E6, indexDelta, 0);
        assertLt(shortDebt, 0);
        assertEq(longDebt, -shortDebt);
    }
}
