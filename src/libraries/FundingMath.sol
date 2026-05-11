// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title  FundingMath — pure helpers for the People Markets funding-rate model.
///
/// @notice Implements the spec §2 funding-rate formula and the two derived primitives the
///         FundingEngine needs:
///
///           fundingRatePerHour_e18 = clamp(
///               kPremium   * premium
///             + kSentiment * sentimentScore
///             + kSkew      * skew,
///             -fMaxPerHour, +fMaxPerHour
///           )
///
///         where
///
///           premium = (mark - index) / index                 (signed, 1e18-scaled)
///           skew    = (longOI - shortOI) / (longOI + shortOI) (signed, 1e18-scaled)
///
///         The library is purely pure-math. Every k_*, fMax, and the produced rate live in 1e18
///         fixed point; the library does not enforce coefficient bounds (that responsibility lives
///         in the engine wrapper). Sentiment is expected to lie in `[-1e18, 1e18]` but again is
///         not enforced here — the engine is the single bottleneck for bounds enforcement so the
///         library stays composable for unit tests.
///
/// @dev    UNITS — read carefully; mismatched scales here propagate straight into the cumulative
///         funding index and silently distort every position's settled funding debt:
///
///         | Quantity                          | Unit                                     |
///         |-----------------------------------|------------------------------------------|
///         | mark, index                       | 1e18 fixed-point (uint256)               |
///         | sentimentScore                    | 1e18 fixed-point, signed (int256)        |
///         | longOi6, shortOi6                 | 6-decimal USDC (uint256) — OPENING notional |
///         | kPremium / kSentiment / kSkew     | 1e18 fixed-point, signed (int256)        |
///         | fMaxPerHour                       | 1e18 fixed-point, signed (int256)        |
///         | premium / skew / each component   | 1e18 fixed-point, signed (int256)        |
///         | totalRate (output)                | 1e18 fixed-point, signed (int256)        |
///         | elapsedSeconds                    | uint64 wall-clock seconds                |
///         | indexDelta (output)               | 1e18 fixed-point, signed (int256)        |
///         | size_1e6                          | 1e6-fixed contracts, signed (int256)     |
///         | debt6 (output)                    | 6-decimal USDC, signed (int256)          |
///
/// @dev    SIGN CONVENTIONS (worked example):
///         Take a "long-heavy book with mark above index" — say longOi = 6e6, shortOi = 4e6,
///         sentiment = +0.5e18, mark = 1.05e18, index = 1.00e18:
///
///           premium  = (1.05e18 - 1.00e18) / 1.00e18           = +0.05e18
///           skew     = (6e6 - 4e6) / 10e6                       = +0.20e18
///           rate     = kPremium*0.05 + kSentiment*0.5 + kSkew*0.20
///                                                              > 0
///           delta    = rate * elapsed / 3600                    > 0
///           newIndex = oldIndex + delta                         (cumulative index grows)
///
///         A long opened earlier with `entryFundingIndex = oldIndex` and `size > 0` pays funding:
///
///           debt6 = size × (newIndex - entryIndex) / 1e18       > 0
///
///         "Positive debt" means the trader owes funding to shorts on close. Shorts get a negative
///         debt on the same leg (paid to them). The math falls out automatically from signed-size
///         multiplication; see `computeFundingDebt` and its tests for the four-quadrant table.
library FundingMath {
    /// @dev 1e18 fixed-point unit for scale operations.
    int256 internal constant ONE_E18 = 1e18;

    /// @dev Seconds in one hour. The funding rate is quoted per hour; integrating over elapsed
    ///      time is just `rate × elapsed / 3600` (linear, no compounding within an interval).
    int256 internal constant SECONDS_PER_HOUR = 3600;

    // ------------------------------------------------------------------------------------------
    // Structs
    // ------------------------------------------------------------------------------------------

    /// @notice Decomposed output of `computeFundingRate`.
    /// @param  premiumComponent_e18   `kPremium * premium / 1e18`, signed 1e18.
    /// @param  sentimentComponent_e18 `kSentiment * sentimentScore / 1e18`, signed 1e18.
    /// @param  skewComponent_e18      `kSkew * skew / 1e18`, signed 1e18.
    /// @param  totalRate_e18          Sum of the three components, then clamped to `[-fMax, +fMax]`.
    /// @param  clamped                True iff the unclamped sum exceeded the symmetric envelope.
    ///                                Surfaced so the engine can emit a telemetry event if needed.
    struct FundingTerms {
        int256 premiumComponent_e18;
        int256 sentimentComponent_e18;
        int256 skewComponent_e18;
        int256 totalRate_e18;
        bool clamped;
    }

    // ------------------------------------------------------------------------------------------
    // computeFundingRate
    // ------------------------------------------------------------------------------------------

    /// @notice Compute the per-hour funding rate from the current market snapshot.
    ///
    /// @dev    Algorithm — performed in this exact order:
    ///
    ///           1. If `index1e18 == 0`: return an all-zero `FundingTerms` (no-op signal — the
    ///              engine treats this as "skip"). A missing or unconfigured index would otherwise
    ///              produce an infinite premium and immediately saturate the clamp.
    ///           2. `premium_e18    = (mark - index) * 1e18 / index`               (signed)
    ///           3. `premiumComp    = kPremium * premium_e18 / 1e18`               (signed)
    ///           4. `sentimentComp  = kSentiment * sentimentScore / 1e18`          (signed)
    ///           5. `totalOi6       = longOi6 + shortOi6`
    ///                  If 0:  skew = 0; else
    ///                         skew_e18 = (long6 - short6) * 1e18 / totalOi6        (signed)
    ///           6. `skewComp       = kSkew * skew_e18 / 1e18`                     (signed)
    ///           7. `unclamped      = premiumComp + sentimentComp + skewComp`
    ///           8. Clamp to `[-fMaxPerHour, +fMaxPerHour]`; set `clamped` if clamping happened.
    ///
    ///         The library does NOT enforce coefficient bounds, sentiment bounds, or `fMax > 0` —
    ///         every gate lives in the engine wrapper. Passing `fMax = 0` collapses the rate to 0
    ///         and sets `clamped = true` only if any component was non-zero; this is the documented
    ///         "kill switch" path.
    ///
    /// @param  mark1e18              Mark price in 1e18 fixed-point.
    /// @param  index1e18             Reference index (e.g. trailing TWAP) in 1e18 fixed-point.
    /// @param  sentimentScore_e18    Sentiment score, 1e18-scaled, expected in `[-1e18, 1e18]`.
    /// @param  longOi6               Long-side open interest at OPENING notional, 6-decimal USDC.
    /// @param  shortOi6              Short-side open interest at OPENING notional, 6-decimal USDC.
    /// @param  kPremium_e18          Premium-component coefficient, signed 1e18.
    /// @param  kSentiment_e18        Sentiment-component coefficient, signed 1e18.
    /// @param  kSkew_e18             Skew-component coefficient, signed 1e18.
    /// @param  fMaxPerHour_e18       Symmetric per-hour clamp envelope, signed 1e18. Conventionally
    ///                               positive; the library applies `±|fMax|` regardless of sign so
    ///                               a caller bug that passes a negative value still produces a
    ///                               sensible symmetric clamp.
    /// @return terms                 Decomposed funding terms + clamping flag.
    function computeFundingRate(
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
        internal
        pure
        returns (FundingTerms memory terms)
    {
        // Step 1 — `index == 0` short-circuits to all-zeros.
        if (index1e18 == 0) {
            return terms;
        }

        // Step 2 — signed premium = (mark - index) / index, scaled by 1e18.
        // Bounds: mark, index ≤ 1e36 (the PerpEngine MAX_MARK), so each cast fits in int256
        // (max ≈ 5.79e76). The numerator can be negative when mark < index (shorts dominant).
        int256 priceDelta = int256(mark1e18) - int256(index1e18);
        int256 premium_e18 = (priceDelta * ONE_E18) / int256(index1e18);

        // Step 3 — premium component.
        terms.premiumComponent_e18 = (kPremium_e18 * premium_e18) / ONE_E18;

        // Step 4 — sentiment component. Sentiment is passed through; no bounds enforcement here.
        terms.sentimentComponent_e18 = (kSentiment_e18 * sentimentScore_e18) / ONE_E18;

        // Step 5 — skew = (long - short) / total, scaled by 1e18. Zero OI ⇒ zero skew.
        if (longOi6 + shortOi6 != 0) {
            // Use signed subtraction so a short-heavy book produces a negative skew. Both sides fit
            // in int256: max practical OI is bounded by category caps (≤ 50% of TVL ≪ 1e36).
            int256 oiDelta = int256(longOi6) - int256(shortOi6);
            int256 totalOi_i = int256(longOi6 + shortOi6);
            int256 skew_e18 = (oiDelta * ONE_E18) / totalOi_i;
            terms.skewComponent_e18 = (kSkew_e18 * skew_e18) / ONE_E18;
        }
        // else: skewComponent_e18 stays at its zero-initialized default. No further work.

        // Step 7 — unclamped sum.
        int256 unclamped = terms.premiumComponent_e18 + terms.sentimentComponent_e18 + terms.skewComponent_e18;

        // Step 8 — symmetric clamp at ±|fMax|. Callers conventionally pass fMax > 0, but we apply
        // `|fMax|` so a negative or zero envelope still produces deterministic behavior.
        int256 fMaxAbs = fMaxPerHour_e18 >= 0 ? fMaxPerHour_e18 : -fMaxPerHour_e18;
        if (unclamped > fMaxAbs) {
            terms.totalRate_e18 = fMaxAbs;
            terms.clamped = true;
        } else if (unclamped < -fMaxAbs) {
            terms.totalRate_e18 = -fMaxAbs;
            terms.clamped = true;
        } else {
            terms.totalRate_e18 = unclamped;
        }
    }

    // ------------------------------------------------------------------------------------------
    // computeIndexDelta
    // ------------------------------------------------------------------------------------------

    /// @notice Integrate a per-hour rate over an elapsed window into a cumulative-index delta.
    ///
    /// @dev    `delta = rate * elapsed / 3600`. Linear, no compounding within a single interval —
    ///         each `pokeFunding` call captures the rate as constant across `[last, now]`, which
    ///         is the canonical perp-funding semantic (rates re-derive from the new mark/skew on
    ///         the next poke).
    ///
    ///         The cast `int256(uint256(elapsedSeconds))` is intentional. `uint64` widens losslessly
    ///         to `uint256` and then to `int256` (no sign-bit collision because max uint64 ≈ 1.84e19
    ///         is many orders of magnitude below int256 max). Going `uint64 → int256` directly is
    ///         a solc 0.8.x quirk that the compiler rejects under via-IR.
    ///
    /// @param  fundingRate_e18 Signed per-hour rate from `computeFundingRate`.
    /// @param  elapsedSeconds  Seconds since the last accrual. Zero is permitted and yields zero.
    /// @return delta_e18       Signed change to apply to the cumulative funding index.
    function computeIndexDelta(int256 fundingRate_e18, uint64 elapsedSeconds) internal pure returns (int256) {
        if (elapsedSeconds == 0 || fundingRate_e18 == 0) return 0;
        return (fundingRate_e18 * int256(uint256(elapsedSeconds))) / SECONDS_PER_HOUR;
    }

    // ------------------------------------------------------------------------------------------
    // computeFundingDebt
    // ------------------------------------------------------------------------------------------

    /// @notice Convert an index-growth delta plus a signed position size into a signed USDC debt.
    ///
    /// @dev    `debt6 = size_1e6 × (currentIndex_e18 - entryIndex_e18) / 1e18`
    ///
    ///         Sign table — verify against the worked example in the contract NatSpec:
    ///
    ///         | size | indexGrowth | debt6 | reading                                         |
    ///         |------|-------------|-------|-------------------------------------------------|
    ///         |  +   |     +       |  +    | long pays (cumulative grew while long-heavy)    |
    ///         |  +   |     -       |  -    | long receives (index shrank ⇒ shorts paid)      |
    ///         |  -   |     +       |  -    | short receives (longs paid them)                |
    ///         |  -   |     -       |  +    | short pays (rate flipped negative ⇒ longs paid) |
    ///
    ///         `debt6 > 0` means the trader OWES at close (deducted from collateral); `debt6 < 0`
    ///         is a credit added to the trader's payout. v0 does not consume this primitive yet
    ///         (per-position settle deferred to a later wave) but every off-chain settler and the
    ///         integration tests do, so the conversion lives here.
    ///
    /// @param  size_1e6         Signed position size in 1e6-fixed contracts (matches `LiquidationMath`).
    /// @param  currentIndex_e18 Cumulative funding index at the close moment, signed 1e18.
    /// @param  entryIndex_e18   Cumulative funding index snapshotted at position open, signed 1e18.
    /// @return debt6            Signed funding debt in 6-decimal USDC (positive = trader pays).
    function computeFundingDebt(
        int256 size_1e6,
        int256 currentIndex_e18,
        int256 entryIndex_e18
    )
        internal
        pure
        returns (int256 debt6)
    {
        if (size_1e6 == 0) return 0;
        int256 indexDelta = currentIndex_e18 - entryIndex_e18;
        if (indexDelta == 0) return 0;
        debt6 = (size_1e6 * indexDelta) / ONE_E18;
    }
}
