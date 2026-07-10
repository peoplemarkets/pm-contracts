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

    /// @notice Where a market's binary resolution comes from.
    /// @dev    APPEND-ONLY ENUM. `UMA == 0` is the zero value BY DESIGN: every legacy clone (and any
    ///         clone initialized under the pre-V2 impl) reads its appended `_resolution.source` slot
    ///         as all-zero and therefore transparently keeps the exact UMA path. NEVER reorder or
    ///         insert members — doing so would silently reinterpret the stored source on live clones.
    enum ResolutionSource {
        UMA, // 0 — subjective UMA optimistic-oracle assertion (default, unchanged path)
        ORACLE_ROUTER // 1 — objective numeric metric read via OracleRouter + comparator
    }

    /// @notice Numeric-to-binary comparator for the objective (ORACLE_ROUTER) resolution path.
    /// @dev    APPEND-ONLY. `value` is the feed reading (LHS); `threshold` is the config RHS.
    ///         GTE/LTE are the milestone-threshold norm; EQ is for DISCRETE metrics (e.g. exact
    ///         chart position) only — it will rarely be true on a noisy continuous feed.
    enum Comparator {
        GTE, // value >= threshold
        LTE, // value <= threshold
        GT, // value >  threshold
        LT, // value <  threshold
        EQ // value == threshold
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

    /// @notice Objective-resolution configuration captured at market creation. Stored in an APPENDED
    ///         trailing slot on the EventMarket clone (never widening `MarketParams`, which is the
    ///         positionally-consumed initializer arg). A zero-value config == `{source: UMA, ...}`,
    ///         which is exactly the legacy behaviour.
    /// @param  source          0 = UMA (subjective assertion path, default). 1 = ORACLE_ROUTER.
    /// @param  metricId        OracleRouter metricId for the objective read. Ignored for UMA (UMA
    ///                         uses `MarketParams.eventId`).
    /// @param  threshold       Comparator RHS, expressed in the metric's DOCUMENTED DECIMALS. The
    ///                         market does a pure integer compare — the caller/governance is
    ///                         responsible for matching the scale the adapter stores the value in.
    /// @param  comparator      Turns the numeric reading into YES/NO.
    /// @param  settleNotBefore Earliest timestamp an objective settle is allowed (typically ==
    ///                         `resolutionDeadline`). Guards against settling on an early/partial
    ///                         reading (mid-count vote total, intraday chart position).
    /// @param  oracleRouter    Router address captured at creation; immutable per market.
    struct ResolutionConfig {
        ResolutionSource source;
        bytes32 metricId;
        uint256 threshold;
        Comparator comparator;
        uint64 settleNotBefore;
        address oracleRouter;
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
    /// @notice Current USDC (1e6) the LPVault marks for this live market: the pure LMSR
    ///         worst-case-liability floor `balance − max(q1,q2)`, held UNCHANGED from funding through
    ///         resolution (it does NOT read UMA, so there is no floor→exact snap at the resolution
    ///         instant). The surplus above the floor is escrowed into the vault's receive-only
    ///         vesting bucket at settle, never snapped into NAV. Always ≥ 0; returns 0 once RESOLVED.
    ///         Never over-marks: the result never exceeds this market's own USDC balance.
    function currentRecoverable() external view returns (uint256);
    function priceOf(bool isYes) external view returns (uint256 price1e18);
    function totalYesShares() external view returns (uint256);
    function totalNoShares() external view returns (uint256);
    function status() external view returns (Status);
    function outcome() external view returns (Outcome);
    function params() external view returns (MarketParams memory);

    /// @notice The market's objective-resolution configuration. A zero-value struct (legacy clones
    ///         and any pre-V2 clone) reads as `{source: UMA, ...}` — i.e. the default UMA path.
    function resolutionConfig() external view returns (ResolutionConfig memory);

    /// @notice Thrown when a UMA-only entrypoint (`proposeResolution`) is called on a market whose
    ///         resolution source is ORACLE_ROUTER — objective markets have no bonded proposal step.
    error WrongResolutionSource();
}
