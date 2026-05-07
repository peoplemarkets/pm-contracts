// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @notice Source of truth for any external data a People Markets contract reads.
/// @dev Routing is per-metric. Each MetricConfig points at exactly one primary adapter and at most one
///      fallback adapter. Adapters store the actual values; OracleRouter only routes and gates.
interface IOracleRouter {
    enum SourceType {
        UNSET,
        CHAINLINK,
        UMA,
        SIGNED
    }

    /// @dev Read result. `value` is interpreted by the consumer per the metric's documented decimals.
    ///      `updatedAt` is the wall-clock timestamp the upstream source produced the value (NOT the
    ///      time it was relayed on-chain).
    struct OracleReading {
        uint256 value;
        uint64 updatedAt;
        bool degraded;
    }

    /// @dev Per-metric routing and safety envelope.
    ///      - `staleAfter` is enforced on read: a reading older than this reverts.
    ///      - `maxDeltaBps` is enforced on writes by adapters; OracleRouter does not write values.
    ///      - `degraded` flips the read path to `fallbackAdapter` if non-zero, else reverts.
    /// @dev `sourceType == UNSET` is the canonical "not registered" sentinel.
    struct MetricConfig {
        SourceType sourceType;
        address adapter;
        address fallbackAdapter;
        uint32 staleAfter;
        uint32 maxDeltaBps;
        bool degraded;
    }

    // -- Admin (governance, behind timelock) -------------------------------------------------------

    /// @notice Schedule a registration for `metricId`. Activates after the router timelock elapses.
    function proposeRegister(bytes32 metricId, MetricConfig calldata config) external;

    /// @notice Activate a previously proposed registration. Reverts if the timelock has not elapsed.
    function activateRegister(bytes32 metricId) external;

    /// @notice Cancel a pending proposal.
    function cancelProposal(bytes32 metricId) external;

    /// @notice Mark a metric as degraded; reads route to the fallback adapter (or revert if unset).
    ///         Designed for fast operator response — no timelock — but operator must be a separate
    ///         multi-sig from governance and emit an on-chain rationale.
    function setDegraded(bytes32 metricId, bool degraded, bytes32 reasonHash) external;

    /// @notice Replace the fallback adapter for an existing metric. Timelock-gated.
    function proposeSetFallback(bytes32 metricId, address fallbackAdapter) external;
    function activateSetFallback(bytes32 metricId) external;

    // -- Reads --------------------------------------------------------------------------------------

    /// @notice Read the current value for `metricId`. Reverts on stale, unregistered, or unrecoverable
    ///         degraded state. Consumers MUST check `degraded` and decide independently whether the
    ///         downstream operation should proceed.
    function read(bytes32 metricId) external view returns (OracleReading memory);

    /// @notice Read the live MetricConfig.
    function configOf(bytes32 metricId) external view returns (MetricConfig memory);

    // -- Events -------------------------------------------------------------------------------------

    event MetricProposed(bytes32 indexed metricId, MetricConfig config, uint64 activatesAt);
    event MetricActivated(bytes32 indexed metricId, MetricConfig config);
    event ProposalCancelled(bytes32 indexed metricId);
    event MetricDegraded(bytes32 indexed metricId, bool degraded, bytes32 reasonHash);
    event FallbackProposed(bytes32 indexed metricId, address fallbackAdapter, uint64 activatesAt);
    event FallbackActivated(bytes32 indexed metricId, address fallbackAdapter);

    // -- Errors -------------------------------------------------------------------------------------

    error MetricNotRegistered(bytes32 metricId);
    error MetricAlreadyRegistered(bytes32 metricId);
    error NoPendingProposal(bytes32 metricId);
    error TimelockNotElapsed(bytes32 metricId, uint64 readyAt);
    error InvalidConfig();
    error StaleReading(bytes32 metricId, uint64 updatedAt, uint64 staleAfter);
    error DegradedAndNoFallback(bytes32 metricId);
    error Unauthorized(address caller);
}
