// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  LiquidationMath — pure helpers for the 5-tier liquidation waterfall (Tiers 1, 2 and 5).
///
/// @notice Implements the math for:
///           * Tier 1 — partial liquidation increments (computePartialIncrement)
///           * Tier 2 — full liquidation closeout (computeFullLiquidation)
///           * Tier 5 — ADL ranking key (adlPriority)
///         plus two health predicates used by the liquidation engine to gate Tier 1/2 entry
///         (isUnderMaintenance, isUnderLiquidationBuffer).
///
/// @dev    UNITS — read this carefully; the prior agent's bug was a missing /1e18 in the notional
///         conversion that blew values up by a factor of 10^12.
///
///         | Quantity                          | Unit                          |
///         |-----------------------------------|-------------------------------|
///         | Collateral, notional, bounty      | 6-decimal USDC (uint256)      |
///         | Realized / unrealized PnL         | 6-decimal USDC, signed (int256)|
///         | Mark / entry price                | 1e18 fixed-point (uint256)    |
///         | Size                              | signed 1e6-fixed contracts (int256) — a $1,000 long at $100 mark is `+10_000_000` (10 contracts × 1e6) |
///         | Bps params (MM, bounty, buffer)   | 1e4 denominator (uint16)      |
///         | Leverage scaling factor (internal)| 1e6 denominator (uint256)     |
///
///         The CRITICAL conversion is:
///             notional6 = |size| × markPrice / 1e18
///         which lands in 6-decimal USDC because size is 1e6-fixed and mark is 1e18-fixed and
///         the 1e18 in the mark cancels out exactly.
///
///         Likewise for signed PnL on a slice or whole position:
///             pnl6 = size × (mark − entry) / 1e18
///
///         All bps multiplications use `/10_000` and bps params are bounded to `uint16` so the
///         max value is 65_535 — callers must enforce `bps <= 10_000` upstream when that matters.
///
/// @dev    OVERFLOW SAFETY — `|size| × mark` can exceed uint256 max for absurd inputs:
///         max int256 ≈ 5.79e76, mark ≈ 1e18 ⇒ product 5.79e94, blows past 1.16e77. We use
///         OpenZeppelin's `Math.mulDiv` which performs the multiplication in 512-bit space and
///         only requires the final quotient to fit in 256 bits — i.e. the same constraint as
///         "the result is representable as a 256-bit USDC value", which is the actual operational
///         constraint anyway.
library LiquidationMath {
    /// @dev Basis-point denominator: `bps / 10_000` ⇒ fractional weight.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev 1e18 fixed-point unit for price scaling.
    uint256 internal constant ONE_E18 = 1e18;

    /// @dev Leverage scaling factor: 5× leverage encoded as 5_000_000.
    uint256 internal constant LEVERAGE_SCALE = 1e6;

    // ------------------------------------------------------------------------------------------
    // Structs
    // ------------------------------------------------------------------------------------------

    /// @notice Output of `computePartialIncrement`.
    /// @param  reducedSize           Signed reduction in position size (same sign as `currentSize`,
    ///                               magnitude = `|currentSize| × partialIncrementBps / 10_000`).
    /// @param  collateralFreed       6-decimal USDC RETURNED to the position holder. May be 0 if
    ///                               the slice's realized loss exceeds its collateral share or if
    ///                               the remaining position needs the entire freed pool as a top-up.
    /// @param  bountyToLiquidator    6-decimal USDC paid to the liquidator. Capped by what the
    ///                               slice's collateral + PnL can actually fund.
    /// @param  markPrice             Echoed input — convenient for callers and event-emission.
    struct PartialResult {
        int256 reducedSize;
        uint256 collateralFreed;
        uint256 bountyToLiquidator;
        uint256 markPrice;
    }

    /// @notice Output of `computeFullLiquidation`.
    /// @param  closedSize            Always equal to `currentSize`.
    /// @param  collateralReturned    6-decimal USDC sent back to the holder. Zero unless equity
    ///                               strictly exceeds the bounty target (case A).
    /// @param  bountyToLiquidator    6-decimal USDC paid to the liquidator. Equal to the target
    ///                               when equity covers it; otherwise the entire surviving equity
    ///                               (cases B/C).
    /// @param  shortfall             6-decimal USDC the insurance fund (Tier 3) must source.
    ///                               Positive only when equity could not fund the full bounty.
    /// @param  markPrice             Echoed input.
    struct FullResult {
        int256 closedSize;
        uint256 collateralReturned;
        uint256 bountyToLiquidator;
        int256 shortfall;
        uint256 markPrice;
    }

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    /// @dev Reverts if `markPrice == 0` — a non-positive mark is a configuration bug.
    error MarkNotPositive();

    /// @dev Reverts if `entryPrice == 0` — same rationale.
    error EntryPriceNotPositive();

    /// @dev Reverts if a bps parameter exceeds `BPS_DENOMINATOR` (10_000). Bps params represent
    ///      fractions in `[0, 1]`; anything above 100% is nonsense.
    error BpsOutOfRange();

    /// @dev Reverts if `currentSize == 0` — there is nothing to liquidate.
    error ZeroSize();

    // ------------------------------------------------------------------------------------------
    // Partial liquidation
    // ------------------------------------------------------------------------------------------

    /// @notice Compute the outcome of a Tier-1 partial-liquidation slice.
    ///
    /// @dev    Algorithm — performed in this exact order:
    ///           1. `reducedSizeAbs = |currentSize| × partialIncrementBps / 10_000`.
    ///           2. `reducedSize` is signed with the same sign as `currentSize`.
    ///           3. `reducedNotional6 = reducedSizeAbs × markPrice / 1e18`.
    ///           4. `bountyToLiquidator = reducedNotional6 × liquidatorBountyBps / 10_000`.
    ///           5. `pnlOnSlice6 = reducedSize × (mark − entry) / 1e18` (signed; long+mark>entry
    ///              → profit; short+mark>entry → loss).
    ///           6. `slice's collateral share = currentCollateral × partialIncrementBps / 10_000`.
    ///           7. `freedPool = sliceCollateral + pnlOnSlice − bounty` (signed).
    ///           8. If `freedPool <= 0`: trader gets 0; bounty is capped at
    ///              `max(sliceCollateral + pnl, 0)`. Caller's responsibility to handle any
    ///              implicit shortfall (the prior agent's design assumes Tier-3 absorbs it).
    ///           9. Else: `collateralFreed = freedPool`.
    ///
    ///         If `partialIncrementBps == 10_000` this collapses to a "full close via the partial
    ///         path" — `remainingSizeAbs = 0`, no MM-restore step.
    ///
    ///         Otherwise we ALSO check the remaining position has enough collateral to clear
    ///         maintenance margin plus the configured restore buffer. If not, we redirect freed
    ///         collateral back into the remaining position. If the freed pool can't cover the
    ///         top-up, `collateralFreed = 0` and the caller should escalate (try a larger slice
    ///         or jump to full liquidation).
    ///
    /// @param  currentSize           Signed position size in 1e6-fixed contract units.
    /// @param  currentCollateral     Posted collateral in 6-decimal USDC.
    /// @param  markPrice             Current mark in 1e18 fixed-point.
    /// @param  entryPrice            Entry mark in 1e18 fixed-point.
    /// @param  partialIncrementBps   Fractional slice in bps (e.g. 2_500 = 25%).
    /// @param  liquidatorBountyBps   Bounty fraction of slice notional, in bps.
    /// @param  maintenanceMarginBps  Maintenance-margin requirement on remaining notional, in bps.
    /// @param  mmRestoreBufferBps    Extra buffer above MM the remaining position must clear, in bps.
    function computePartialIncrement(
        int256 currentSize,
        uint256 currentCollateral,
        uint256 markPrice,
        uint256 entryPrice,
        uint16 partialIncrementBps,
        uint16 liquidatorBountyBps,
        uint16 maintenanceMarginBps,
        uint16 mmRestoreBufferBps
    )
        internal
        pure
        returns (PartialResult memory result)
    {
        if (markPrice == 0) revert MarkNotPositive();
        if (entryPrice == 0) revert EntryPriceNotPositive();
        if (currentSize == 0) revert ZeroSize();
        if (
            partialIncrementBps == 0 || partialIncrementBps > BPS_DENOMINATOR || liquidatorBountyBps > BPS_DENOMINATOR
                || maintenanceMarginBps > BPS_DENOMINATOR || mmRestoreBufferBps > BPS_DENOMINATOR
        ) {
            revert BpsOutOfRange();
        }

        result.markPrice = markPrice;

        // Step 1 — reducedSizeAbs (uint256, in contract units × 1e6).
        uint256 absSize = currentSize > 0 ? uint256(currentSize) : uint256(-currentSize);
        uint256 reducedSizeAbs = (absSize * uint256(partialIncrementBps)) / BPS_DENOMINATOR;

        // Step 2 — signed reducedSize, sign-matched to currentSize.
        result.reducedSize = currentSize > 0 ? int256(reducedSizeAbs) : -int256(reducedSizeAbs);

        // Step 3 — slice notional in 6-decimal USDC. Use mulDiv against the 1e18 mark scaling.
        uint256 reducedNotional6 = Math.mulDiv(reducedSizeAbs, markPrice, ONE_E18);

        // Step 4 — bounty target sized to the slice notional.
        uint256 bountyTarget = (reducedNotional6 * uint256(liquidatorBountyBps)) / BPS_DENOMINATOR;

        // Step 5 — slice's signed realized PnL in 6-decimal USDC.
        // size × (mark − entry) / 1e18; the sign falls out of the signed size automatically.
        int256 priceDelta = int256(markPrice) - int256(entryPrice);
        int256 pnlOnSlice6 = (result.reducedSize * priceDelta) / int256(ONE_E18);

        // Step 6 — slice's share of posted collateral. Bps-proportional, same denominator as size.
        uint256 collateralAllocatedToSlice = (currentCollateral * uint256(partialIncrementBps)) / BPS_DENOMINATOR;

        // Step 7 — what's left after paying PnL and bounty out of the slice.
        int256 freedPoolInt = int256(collateralAllocatedToSlice) + pnlOnSlice6 - int256(bountyTarget);

        if (freedPoolInt <= 0) {
            // Step 8 — bounty capped at sliceCollateral + pnl (≥0). Caller eats any remaining gap.
            int256 fundable = int256(collateralAllocatedToSlice) + pnlOnSlice6;
            result.bountyToLiquidator = fundable > 0 ? uint256(fundable) : 0;
            result.collateralFreed = 0;
        } else {
            // Step 9 — bounty fully funded; the residue is the slice's payout to the trader.
            result.bountyToLiquidator = bountyTarget;
            result.collateralFreed = uint256(freedPoolInt);
        }

        // ----- Remaining-position MM-restore check (only when this is a true partial). -----
        if (partialIncrementBps < BPS_DENOMINATOR) {
            uint256 remainingSizeAbs = absSize - reducedSizeAbs;
            uint256 remainingNotional6 = Math.mulDiv(remainingSizeAbs, markPrice, ONE_E18);
            uint256 totalReqBps = uint256(maintenanceMarginBps) + uint256(mmRestoreBufferBps);
            uint256 remainingRequired6 = (remainingNotional6 * totalReqBps) / BPS_DENOMINATOR;
            uint256 remainingAvailable6 = currentCollateral - collateralAllocatedToSlice;

            if (remainingAvailable6 < remainingRequired6) {
                uint256 topUp = remainingRequired6 - remainingAvailable6;
                if (result.collateralFreed >= topUp) {
                    result.collateralFreed -= topUp;
                } else {
                    // Slice's freed pool cannot top up the remaining position — caller must
                    // escalate. We zero `collateralFreed` to signal "insufficient" and leave the
                    // bounty alone (the liquidator still earned it; the engine decides whether to
                    // retry with a bigger slice or jump to Tier-2).
                    result.collateralFreed = 0;
                }
            }
        }
    }

    // ------------------------------------------------------------------------------------------
    // Full liquidation
    // ------------------------------------------------------------------------------------------

    /// @notice Compute the outcome of a Tier-2 full close at `markPrice`.
    ///
    /// @dev    Algorithm:
    ///           1. `notional6 = |currentSize| × markPrice / 1e18`.
    ///           2. `pnl6 = currentSize × (mark − entry) / 1e18` (signed).
    ///           3. `bountyTarget = notional6 × fullLiquidationBountyBps / 10_000`.
    ///           4. `equity6 = collateral + pnl6` (signed).
    ///           5. Branch:
    ///                A. `equity > bountyTarget`        → solvent: bounty = target, return rest.
    ///                B. `0 < equity ≤ bountyTarget`    → bounty = equity, trader = 0,
    ///                                                    shortfall = bountyTarget − equity.
    ///                C. `equity ≤ 0`                   → wipeout: bounty = 0, trader = 0,
    ///                                                    shortfall = bountyTarget − equity
    ///                                                    (= bountyTarget + |equity|).
    ///
    ///         Boundary: at `equity == bountyTarget` we land in B, so the trader strictly receives
    ///         a positive payout only when equity STRICTLY exceeds the bounty target.
    function computeFullLiquidation(
        int256 currentSize,
        uint256 currentCollateral,
        uint256 markPrice,
        uint256 entryPrice,
        uint16 fullLiquidationBountyBps
    )
        internal
        pure
        returns (FullResult memory result)
    {
        if (markPrice == 0) revert MarkNotPositive();
        if (entryPrice == 0) revert EntryPriceNotPositive();
        if (currentSize == 0) revert ZeroSize();
        if (fullLiquidationBountyBps > BPS_DENOMINATOR) revert BpsOutOfRange();

        result.markPrice = markPrice;
        result.closedSize = currentSize;

        uint256 absSize = currentSize > 0 ? uint256(currentSize) : uint256(-currentSize);
        uint256 notional6 = Math.mulDiv(absSize, markPrice, ONE_E18);

        int256 priceDelta = int256(markPrice) - int256(entryPrice);
        int256 pnl6 = (currentSize * priceDelta) / int256(ONE_E18);

        uint256 bountyTarget = (notional6 * uint256(fullLiquidationBountyBps)) / BPS_DENOMINATOR;
        int256 equity6Int = int256(currentCollateral) + pnl6;

        if (equity6Int > int256(bountyTarget)) {
            // Case A — fully solvent.
            result.bountyToLiquidator = bountyTarget;
            result.collateralReturned = uint256(equity6Int) - bountyTarget;
            result.shortfall = 0;
        } else if (equity6Int > 0) {
            // Case B — equity covers part (or all) of bounty; trader gets 0.
            result.bountyToLiquidator = uint256(equity6Int);
            result.collateralReturned = 0;
            result.shortfall = int256(bountyTarget) - equity6Int;
        } else {
            // Case C — wipeout. Subtracting a non-positive equity6Int adds its magnitude.
            result.bountyToLiquidator = 0;
            result.collateralReturned = 0;
            result.shortfall = int256(bountyTarget) - equity6Int;
        }
    }

    // ------------------------------------------------------------------------------------------
    // ADL priority
    // ------------------------------------------------------------------------------------------

    /// @notice Ranking key for the Tier-5 ADL queue. Caller sorts descending — higher key wins.
    ///
    /// @dev    Returns `|uPnL6| × leverage_x1e6 / 1e6`, where:
    ///           uPnL6        = size × (mark − entry) / 1e18  (signed 6-decimal USDC)
    ///           leverage_x1e6= notional6 × 1e6 / collateral  (5× ⇒ 5_000_000)
    ///         The unit cancels out — the key is dimensionless. We use `Math.mulDiv` on the final
    ///         product so the implicit `uPnL × leverage` fits in 512 bits before the /1e6 divide.
    ///
    ///         Zero-collateral guard: a position with no posted collateral is effectively infinite
    ///         leverage and must be cleared first; return `type(uint256).max`.
    function adlPriority(
        int256 size,
        uint256 entryPrice,
        uint256 markPrice,
        uint256 currentCollateral
    )
        internal
        pure
        returns (uint256)
    {
        if (markPrice == 0) revert MarkNotPositive();
        if (entryPrice == 0) revert EntryPriceNotPositive();
        if (size == 0) return 0;
        if (currentCollateral == 0) return type(uint256).max;

        uint256 absSize = size > 0 ? uint256(size) : uint256(-size);
        uint256 notional6 = Math.mulDiv(absSize, markPrice, ONE_E18);

        int256 priceDelta = int256(markPrice) - int256(entryPrice);
        int256 upnl6 = (size * priceDelta) / int256(ONE_E18);
        uint256 upnl6Abs = upnl6 >= 0 ? uint256(upnl6) : uint256(-upnl6);

        // leverage scaled by 1e6 — 5× leverage is 5_000_000.
        uint256 leverageX1e6 = (notional6 * LEVERAGE_SCALE) / currentCollateral;

        return Math.mulDiv(upnl6Abs, leverageX1e6, LEVERAGE_SCALE);
    }

    // ------------------------------------------------------------------------------------------
    // Health checks
    // ------------------------------------------------------------------------------------------

    /// @notice STRICT under-maintenance predicate: `equity6 < notional6 × MM / 10_000`.
    ///
    /// @dev    At equity == mm we return `false` — the position is on the boundary, NOT yet in
    ///         the danger zone. The prior agent had this flipped; the convention matches the
    ///         exchange's "MM is the minimum acceptable" framing.
    ///
    ///         Short positions are handled by signed PnL automatically: `size < 0` and
    ///         `mark > entry` ⇒ `size × (mark − entry) < 0` ⇒ equity drops ⇒ likely returns true.
    function isUnderMaintenance(
        int256 size,
        uint256 collateral,
        uint256 markPrice,
        uint256 entryPrice,
        uint16 maintenanceMarginBps
    )
        internal
        pure
        returns (bool)
    {
        if (markPrice == 0) revert MarkNotPositive();
        if (entryPrice == 0) revert EntryPriceNotPositive();
        if (maintenanceMarginBps > BPS_DENOMINATOR) revert BpsOutOfRange();
        if (size == 0) return false;

        uint256 absSize = size > 0 ? uint256(size) : uint256(-size);
        uint256 notional6 = Math.mulDiv(absSize, markPrice, ONE_E18);
        int256 priceDelta = int256(markPrice) - int256(entryPrice);
        int256 pnl6 = (size * priceDelta) / int256(ONE_E18);
        int256 equity6Int = int256(collateral) + pnl6;
        uint256 mm6 = (notional6 * uint256(maintenanceMarginBps)) / BPS_DENOMINATOR;
        return equity6Int < int256(mm6);
    }

    /// @notice STRICT under-liquidation-buffer predicate. Shape mirrors `isUnderMaintenance` but
    ///         the threshold is `(maintenanceMarginBps + liquidationBufferBps)` of notional.
    function isUnderLiquidationBuffer(
        int256 size,
        uint256 collateral,
        uint256 markPrice,
        uint256 entryPrice,
        uint16 maintenanceMarginBps,
        uint16 liquidationBufferBps
    )
        internal
        pure
        returns (bool)
    {
        if (markPrice == 0) revert MarkNotPositive();
        if (entryPrice == 0) revert EntryPriceNotPositive();
        if (maintenanceMarginBps > BPS_DENOMINATOR || liquidationBufferBps > BPS_DENOMINATOR) {
            revert BpsOutOfRange();
        }
        if (uint256(maintenanceMarginBps) + uint256(liquidationBufferBps) > BPS_DENOMINATOR) {
            revert BpsOutOfRange();
        }
        if (size == 0) return false;

        uint256 absSize = size > 0 ? uint256(size) : uint256(-size);
        uint256 notional6 = Math.mulDiv(absSize, markPrice, ONE_E18);
        int256 priceDelta = int256(markPrice) - int256(entryPrice);
        int256 pnl6 = (size * priceDelta) / int256(ONE_E18);
        int256 equity6Int = int256(collateral) + pnl6;
        uint256 thresholdBps = uint256(maintenanceMarginBps) + uint256(liquidationBufferBps);
        uint256 threshold6 = (notional6 * thresholdBps) / BPS_DENOMINATOR;
        return equity6Int < int256(threshold6);
    }
}
