// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

interface IEventMarket {
    enum Status {
        OPEN,
        PAUSED,
        PENDING_RESOLUTION,
        RESOLVED
    }
    enum Outcome {
        UNRESOLVED,
        YES,
        NO,
        VOID
    }

    struct MarketParams {
        bytes32 subjectId;
        bytes32 eventId;
        uint8 eventClass; // FeedbackController.EventClass
        string question;
        uint64 resolutionDeadline;
        uint256 initialLiquidity;
        uint256 lmsrB; // Liquidity parameter B (scaled to 1e6)
    }

    /// @notice Buy outcome shares for `msg.sender`. Reverts if the minted shares would be below
    ///         `minSharesOut` (slippage protection).
    function buyOutcome(bool isYes, uint256 usdcAmount, uint256 minSharesOut) external returns (uint256 shares);

    /// @notice Sell outcome shares held by `msg.sender`. Reverts if the USDC returned would be
    ///         below `minUsdcOut` (slippage protection).
    function sellOutcome(bool isYes, uint256 shares, uint256 minUsdcOut) external returns (uint256 usdcOut);

    /// @notice Operator-gated buy on behalf of `trader`. Only an allowlisted operator
    ///         (`factory.isOperator(msg.sender)`) may call. USDC is pulled from the caller (the
    ///         operator/router, which has already collected it from `trader`); shares are credited
    ///         to `trader` and the `SharesBought` event reports `trader` as the buyer.
    function buyOutcomeFor(
        address trader,
        bool isYes,
        uint256 usdcAmount,
        uint256 minSharesOut
    )
        external
        returns (uint256 shares);

    /// @notice Operator-gated sell on behalf of `trader`. Only an allowlisted operator may call.
    ///         Shares are burned from `trader`'s balance and the USDC proceeds are sent directly to
    ///         `trader`; the `SharesSold` event reports `trader` as the seller.
    function sellOutcomeFor(
        address trader,
        bool isYes,
        uint256 shares,
        uint256 minUsdcOut
    )
        external
        returns (uint256 usdcOut);

    /// @notice Redeem winnings after resolution
    function redeemWinnings() external returns (uint256 usdcOut);

    /// @notice Initiate resolution process by asserting truth to UMA
    /// @param proposedOutcome The outcome being proposed (YES, NO, or VOID)
    function proposeResolution(Outcome proposedOutcome) external;

    /// @notice Settle UMA assertion and finalize market
    function settleResolution() external;

    // Views
    function priceOf(bool isYes) external view returns (uint256 price1e18);
    function totalYesShares() external view returns (uint256);
    function totalNoShares() external view returns (uint256);
    function status() external view returns (Status);
    function outcome() external view returns (Outcome);
    function params() external view returns (MarketParams memory);
}
