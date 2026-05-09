// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title PositionMath — pure helpers for perp position arithmetic.
/// @notice All values use 1e18 fixed-point. `size` is signed (positive = long, negative = short).
///         `entryPrice`, `mark`, `collateral`, and `notional` are unsigned 1e18 USDC. `unrealizedPnl`
///         and `equity` are signed.
///
/// @dev    Library is stateless and side-effect free. Operates on primitives rather than the
///         Position struct so it is reusable across views and tests without a storage import.
///         All arithmetic uses checked solidity 0.8 semantics — auditable, no via-IR-specific
///         tricks, no `unchecked` blocks.
///
/// @dev    Math sketch (where ONE = 1e18):
///           notional        = |size| × mark / ONE
///           unrealizedPnl   = size × (mark − entry) / ONE        // signed
///           equity          = collateral + unrealizedPnl         // signed
///           marginRatioBps  = max(equity, 0) × 10_000 / notional
///           leverageBps     = notional × 10_000 / collateral
library PositionMath {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    error MarkNotPositive();
    error EntryPriceNotPositive();
    error CollateralNotPositive();

    /// @notice Absolute notional value of a position at the given mark.
    /// @dev    `size == 0` returns 0 (open-position view friendliness). Reverts on `mark == 0` —
    ///         a non-positive mark is a misconfiguration, not a recoverable runtime state.
    function notional(int256 size, uint256 mark) internal pure returns (uint256) {
        if (mark == 0) revert MarkNotPositive();
        if (size == 0) return 0;
        uint256 absSize = size > 0 ? uint256(size) : uint256(-size);
        return (absSize * mark) / ONE;
    }

    /// @notice Signed unrealized PnL.
    /// @dev    Long (size > 0) profits when `mark > entry`; short (size < 0) profits when
    ///         `mark < entry`. Multiplication by signed `size` preserves the sign correctly.
    function unrealizedPnl(int256 size, uint256 entryPrice, uint256 mark) internal pure returns (int256) {
        if (entryPrice == 0) revert EntryPriceNotPositive();
        if (mark == 0) revert MarkNotPositive();
        if (size == 0) return 0;
        // Both fit in int256: max practical value is ~1e36, well under int256 max (~5.79e76).
        int256 priceDelta = int256(mark) - int256(entryPrice);
        return (size * priceDelta) / int256(ONE);
    }

    /// @notice Equity = collateral + unrealized PnL.
    /// @dev    Returns signed because a position's PnL can exceed collateral (insolvent before
    ///         liquidation). Callers route insolvent equity through the liquidation path; v0
    ///         PerpEngine refuses voluntary close into negative equity.
    function equity(uint256 collateral, int256 uPnL) internal pure returns (int256) {
        return int256(collateral) + uPnL;
    }

    /// @notice Margin ratio in basis points: max(equity, 0) × 10_000 / notional.
    /// @dev    Returns 0 for non-positive equity OR zero notional. Caller compares against the
    ///         configured initial / maintenance threshold.
    function marginRatioBps(int256 eq, uint256 notional_) internal pure returns (uint256) {
        if (notional_ == 0) return 0;
        if (eq <= 0) return 0;
        return (uint256(eq) * BPS_DENOMINATOR) / notional_;
    }

    /// @notice Leverage in basis points: notional × 10_000 / collateral.
    /// @dev    Reverts on `collateral == 0`. PerpEngine pre-checks initial-margin so production
    ///         calls never hit this branch; tests exercise it explicitly.
    function leverageBps(uint256 notional_, uint256 collateral) internal pure returns (uint256) {
        if (collateral == 0) revert CollateralNotPositive();
        return (notional_ * BPS_DENOMINATOR) / collateral;
    }
}
