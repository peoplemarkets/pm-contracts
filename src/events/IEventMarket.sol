// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

interface IEventMarket {
    enum Status { OPEN, PAUSED, PENDING_RESOLUTION, RESOLVED }
    enum Outcome { UNRESOLVED, YES, NO, VOID }

    struct MarketParams {
        bytes32 subjectId;
        bytes32 eventId;
        uint8 eventClass; // FeedbackController.EventClass
        string question;
        uint64 resolutionDeadline;
        uint256 initialLiquidity;
        uint256 lmsrB; // Liquidity parameter B (scaled to 1e6)
    }

    /// @notice Buy outcome shares
    function buyOutcome(bool isYes, uint256 usdcAmount) external returns (uint256 shares);

    /// @notice Sell outcome shares
    function sellOutcome(bool isYes, uint256 shares) external returns (uint256 usdcOut);

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
