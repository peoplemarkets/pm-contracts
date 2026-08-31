// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title  IFundingEngine — quote-denominated funding-index driver for People Markets perps.
/// @notice The FundingEngine sits between the OracleRouter (premium index source), the
///         PerpEngine (cumulative funding index sink), and the off-chain keeper that pokes
///         the rate forward. Two main external entry points:
///
///           - `pokeFunding(subjectId)` — permissionless. Reads the latest premium index +
///             OI + sentiment, computes the rate, integrates over elapsed time, and pushes
///             the new cumulative quote-per-base index to PerpEngine.
///           - `setSentimentScore(subjectId, score)` — sentiment writer only. Off-chain
///             aggregator pushes the [-1e18, 1e18] sentiment per subject.
///
/// @dev    The quote index has its own versioned namespace. The legacy dimensionless index is
///         retained only for upgrade compatibility and is never reinterpreted as quote value.
interface IFundingEngine {
    // ------------------------------------------------------------------------------------------
    // External — keeper
    // ------------------------------------------------------------------------------------------

    /// @notice Compute & push a fresh cumulative-funding index for `subjectId`.
    ///
    /// @dev    Permissionless: the rate math is deterministic from on-chain state and the
    ///         OracleRouter feed, so anyone can pay the gas. First poke for a subject (where
    ///         `lastFundingAt == 0` on the PerpEngine side) seeds the clock with rate = 0 —
    ///         this is how a freshly-registered subject gets a non-zero `lastFundingAt`
    ///         without an artificial mark on the index. Same-block double-pokes no-op.
    function pokeFunding(bytes32 subjectId) external;

    // ------------------------------------------------------------------------------------------
    // External — sentiment writer
    // ------------------------------------------------------------------------------------------

    /// @notice Set the sentiment score for `subjectId`. Bounded `[-1e18, 1e18]`. Subject must
    ///         be registered with this FundingEngine.
    function setSentimentScore(bytes32 subjectId, int256 score_e18) external;

    // ------------------------------------------------------------------------------------------
    // External — governance
    // ------------------------------------------------------------------------------------------

    /// @notice Bind `subjectId` to an OracleRouter `metricId` that yields the reference index.
    function registerSubject(bytes32 subjectId, bytes32 indexMetricId) external;

    /// @notice Remove the binding for `subjectId`. Sentiment score is cleared.
    function deregisterSubject(bytes32 subjectId) external;

    /// @notice Schedule a sentiment-writer add. Activates after `timelockDelay`.
    function proposeAddSentimentWriter(address writer) external;

    /// @notice Permissionless: activate a previously-proposed sentiment writer.
    function activateAddSentimentWriter(address writer) external;

    /// @notice Cancel a pending sentiment-writer add.
    function cancelAddSentimentWriter(address writer) external;

    /// @notice Revoke a sentiment writer. Immediate; no timelock — a compromised writer can be
    ///         cut off without delay.
    function removeSentimentWriter(address writer) external;

    /// @notice Update the funding-rate coefficients. Each is validated against its spec band.
    function setFundingCoefficients(
        int256 kPremium_e18,
        int256 kSentiment_e18,
        int256 kSkew_e18,
        int256 fMaxPerHour_e18
    )
        external;

    /// @notice Schedule a governance transfer. Activates after `timelockDelay`.
    function proposeGovernanceTransfer(address newGovernance) external;
    function activateGovernanceTransfer() external;
    function cancelGovernanceTransfer() external;

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    /// @notice Deprecated legacy dimensionless index. Frozen after quote-funding cutover.
    function cumulativeFundingIndex(bytes32 subjectId) external view returns (int256);
    /// @notice Deprecated legacy clock paired with `cumulativeFundingIndex`.
    function lastFundingAt(bytes32 subjectId) external view returns (uint64);
    /// @notice Canonical cumulative quote funding per base contract, signed 1e18.
    function cumulativeFundingQuoteIndex(bytes32 subjectId) external view returns (int256);
    /// @notice Timestamp of the latest canonical quote-index push.
    function lastQuoteFundingAt(bytes32 subjectId) external view returns (uint64);

    function sentimentScoreOf(bytes32 subjectId) external view returns (int256);
    function metricForSubject(bytes32 subjectId) external view returns (bytes32);
    function subjectForMetric(bytes32 metricId) external view returns (bytes32);

    function kPremium_e18() external view returns (int256);
    function kSentiment_e18() external view returns (int256);
    function kSkew_e18() external view returns (int256);
    function fMaxPerHour_e18() external view returns (int256);

    function governance() external view returns (address);
    function pendingGovernance() external view returns (address account, uint64 activatesAt);
    function timelockDelay() external view returns (uint32);
    function perpEngine() external view returns (address);
    function oracleRouter() external view returns (address);

    function isSentimentWriter(address account) external view returns (bool);
    function pendingSentimentWriterActivatesAt(address account) external view returns (uint64);

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event Initialized(address governance, address perpEngine, address oracleRouter);
    /// @notice Legacy dimensionless-index telemetry retained for historical log decoding.
    event FundingPoked(bytes32 indexed subjectId, int256 oldIndex, int256 newIndex, int256 rate, uint64 elapsed);
    event FundingQuotePoked(
        bytes32 indexed subjectId,
        int256 oldQuoteIndex1e18,
        int256 newQuoteIndex1e18,
        int256 rate1e18,
        uint256 markPrice1e18,
        uint64 elapsed
    );
    event SubjectRegistered(bytes32 indexed subjectId, bytes32 indexed metricId);
    event SubjectDeregistered(bytes32 indexed subjectId, bytes32 indexed metricId);
    event SentimentScoreSet(bytes32 indexed subjectId, int256 oldScore, int256 newScore, address indexed writer);
    event SentimentWriterProposed(address indexed writer, uint64 activatesAt);
    event SentimentWriterActivated(address indexed writer);
    event SentimentWriterCancelled(address indexed writer);
    event SentimentWriterRemoved(address indexed writer);
    event FundingCoefficientsSet(int256 kPremium, int256 kSentiment, int256 kSkew, int256 fMaxPerHour);
    event GovernanceTransferProposed(address indexed newGov, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGov, address indexed newGov);
    event GovernanceTransferCancelled(address indexed pendingGov);

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error Unauthorized(address caller);
    error OnlySentimentWriter(address caller);
    error InvalidConfig();

    error SubjectNotRegistered(bytes32 subjectId);
    error SubjectAlreadyRegistered(bytes32 subjectId);
    /// @dev Thrown by `registerSubject` when `indexMetricId` is already bound to another subject.
    ///      Prevents the silent reverse-lookup overwrite on the `metricToSubject` mapping.
    error MetricAlreadyBound(bytes32 metricId);

    error KPremiumOutOfRange(int256 value);
    error KSentimentOutOfRange(int256 value);
    error KSkewOutOfRange(int256 value);
    error FMaxOutOfRange(int256 value);
    error SentimentOutOfRange(int256 value);

    error PendingGovernanceTransferExists();
    error NoPendingGovernanceTransfer();
    error TimelockNotElapsed(uint64 readyAt);

    error PendingSentimentWriterExists();
    error NoPendingSentimentWriter();
    error SentimentWriterNotSet(address writer);
}
