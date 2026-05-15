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
    ///      - `expectedCadenceSeconds` is the expected refresh interval for the upstream source.
    ///        The permissionless `markIfStale` poke uses `3 * expectedCadenceSeconds` as the
    ///        auto-degrade threshold per mechanismdesign.md §4 (Stage 1 auto-degraded detection).
    /// @dev `sourceType == UNSET` is the canonical "not registered" sentinel.
    struct MetricConfig {
        SourceType sourceType;
        address adapter;
        address fallbackAdapter;
        uint32 staleAfter;
        uint32 maxDeltaBps;
        bool degraded;
        uint32 expectedCadenceSeconds;
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

    /// @notice Read the configured cadence (`expectedCadenceSeconds`) for `metricId`.
    /// @dev    Returns zero for unregistered metrics. The `3 × cadence` auto-degrade window for
    ///         `markIfStale` is derived from this value.
    function cadenceOf(bytes32 metricId) external view returns (uint32);

    // -- Stage 1 auto-degraded detection (3× cadence) ----------------------------------------------

    /// @notice Permissionless poke: flip `metricId` to degraded if its upstream adapter has not
    ///         produced a fresh value for more than `3 × expectedCadenceSeconds`.
    /// @dev    Per mechanismdesign.md §4, the cadence half of Stage 1 auto-degraded detection is
    ///         a missed-refresh trigger. The deviation half (3-source median) is handled by a
    ///         separate component and not implemented here.
    function markIfStale(bytes32 metricId) external;

    // -- Governance transfer (timelocked) + operator rotation (immediate) --------------------------

    /// @notice Schedule a governance transfer. Activates after `timelockDelay`.
    function proposeGovernanceTransfer(address newGov) external;

    /// @notice Permissionless: activate a previously-proposed governance transfer once the
    ///         timelock has elapsed. Anyone can pay the gas; the handoff is fully gated by the
    ///         original propose call and the elapsed timelock.
    function activateGovernanceTransfer() external;

    /// @notice Cancel a pending governance transfer.
    function cancelGovernanceTransfer() external;

    /// @notice Rotate the operator address. Governance only, NO timelock — the operator's
    ///         narrow scope (only `setDegraded`) means fast cut-off is the right emergency
    ///         response when the operator multi-sig is compromised. Matches `LPVault.setOperator`.
    function setOperator(address newOperator) external;

    /// @notice Read the current pending governance transfer (zero address + zero timestamp when none).
    function pendingGovernance() external view returns (address account, uint64 activatesAt);

    // -- Events -------------------------------------------------------------------------------------

    event MetricProposed(bytes32 indexed metricId, MetricConfig config, uint64 activatesAt);
    event MetricActivated(bytes32 indexed metricId, MetricConfig config);
    event ProposalCancelled(bytes32 indexed metricId);
    event MetricDegraded(bytes32 indexed metricId, bool degraded, bytes32 reasonHash);
    event FallbackProposed(bytes32 indexed metricId, address fallbackAdapter, uint64 activatesAt);
    event FallbackActivated(bytes32 indexed metricId, address fallbackAdapter);
    /// @notice Emitted when `markIfStale` flips a metric to degraded because the adapter's last
    ///         `valueTimestamp` is older than `3 × cadence` seconds.
    event AutoDegraded(bytes32 indexed metricId, uint64 valueTimestamp, uint32 cadence, address triggerer);
    /// @notice Emitted by the governance-transfer timelock dance.
    event GovernanceTransferProposed(address indexed newGov, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGov, address indexed newGov);
    event GovernanceTransferCancelled(address indexed pendingGov);
    /// @notice Emitted on `setOperator`. The operator multi-sig may toggle the degraded flag
    ///         (no timelock); rotation is governance-only with immediate effect.
    event OperatorSet(address indexed oldOperator, address indexed newOperator);

    // -- Errors -------------------------------------------------------------------------------------

    error MetricNotRegistered(bytes32 metricId);
    error MetricAlreadyRegistered(bytes32 metricId);
    error NoPendingProposal(bytes32 metricId);
    error TimelockNotElapsed(bytes32 metricId, uint64 readyAt);
    error InvalidConfig();
    error StaleReading(bytes32 metricId, uint64 updatedAt, uint64 staleAfter);
    error DegradedAndNoFallback(bytes32 metricId);
    error Unauthorized(address caller);
    /// @dev Thrown by `proposeRegister` when `expectedCadenceSeconds` is out of [60, 86400].
    error CadenceOutOfRange(uint32 value);
    /// @dev Thrown by `markIfStale` when the metric is already degraded. Auto-degrade is a
    ///      one-shot trip — reusing it on an already-degraded metric is a caller bug.
    error MetricAlreadyDegraded(bytes32 metricId);
    /// @dev Thrown by `markIfStale` when the metric has refreshed inside its 3×cadence window.
    error MetricNotStale(bytes32 metricId, uint64 valueTimestamp, uint64 staleAfter);

    // -- Wave 7 audit Fix #3 — governance transfer + operator rotation -----------------------------

    /// @dev Thrown by `proposeGovernanceTransfer` when a transfer is already in flight.
    error PendingGovernanceTransferExists();
    /// @dev Thrown by `activateGovernanceTransfer` / `cancelGovernanceTransfer` when there is
    ///      no pending transfer.
    error NoPendingGovernanceTransfer();
    /// @dev Thrown by `activateGovernanceTransfer` before the timelock has elapsed.
    error GovernanceTimelockNotElapsed(uint64 readyAt);
}
