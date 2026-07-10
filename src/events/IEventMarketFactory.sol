// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IEventMarket} from "./IEventMarket.sol";

interface IEventMarketFactory {
    /// @notice Create a UMA-resolved market (default path). Reverts `MetricNotReady(eventId)` if the
    ///         UMA metric for `eventId` is not yet registered (Fix D readiness gate).
    function createMarket(
        bytes32 subjectId,
        bytes32 eventId,
        uint8 eventClass,
        string calldata question,
        uint64 resolutionDeadline,
        uint256 initialLiquidity,
        uint256 lmsrB
    )
        external
        returns (address);

    /// @notice Create a market with an explicit resolution source (`rc.source`): UMA (subjective,
    ///         other `rc` fields ignored) or ORACLE_ROUTER (objective metric + threshold +
    ///         comparator). Reverts `MetricNotReady` if the declared metric is not registered/active.
    function createMarketWithResolution(
        bytes32 subjectId,
        bytes32 eventId,
        uint8 eventClass,
        string calldata question,
        uint64 resolutionDeadline,
        uint256 initialLiquidity,
        uint256 lmsrB,
        IEventMarket.ResolutionConfig calldata rc
    )
        external
        returns (address);

    function getMarket(bytes32 eventId) external view returns (address);
    function onMarketResolved(
        bytes32 subjectId,
        bytes32 eventId,
        uint8 eventClass,
        int256 outcomeScore_e18,
        uint256 returnedAmount,
        uint256 lockedSurplus
    )
        external;

    // ------------------------------------------------------------------------------------------
    // Operator allowlist (engine-relayed `*For` path). Single source of truth; markets query
    // `isOperator(msg.sender)` to gate their operator entrypoints. Governance-managed with a
    // timelocked add / immediate remove (kill switch), mirroring the perp router allowlist.
    // ------------------------------------------------------------------------------------------

    /// @notice True if `account` is an allowlisted operator trusted to act on a trader's behalf.
    function isOperator(address account) external view returns (bool);

    /// @notice True if `account` is a market clone created by this factory.
    function isMarket(address account) external view returns (bool);

    /// @notice Propose adding an operator. Takes effect after the timelock via `activateAddOperator`.
    function proposeAddOperator(address operator) external;

    /// @notice Activate a previously proposed operator once its timelock has elapsed. Permissionless.
    function activateAddOperator(address operator) external;

    /// @notice Cancel a pending operator proposal before activation.
    function cancelAddOperator(address operator) external;

    /// @notice Immediately remove an operator (governance kill switch, no timelock).
    function removeOperator(address operator) external;

    /// @notice Timestamp at which a pending operator proposal becomes activatable (0 if none).
    function pendingOperatorActivatesAt(address operator) external view returns (uint64);

    // ------------------------------------------------------------------------------------------
    // Market implementation setter (governance-timelocked). `marketImplementation` is the template
    // every future market clone runs, so it is installed via the same two-step propose/activate
    // timelock as operator adds. Existing clones are frozen and unaffected.
    // ------------------------------------------------------------------------------------------

    /// @notice The EventMarket template cloned by `createMarket`.
    function marketImplementation() external view returns (address);

    /// @notice Market implementation pending activation (0 if none).
    function pendingMarketImplementation() external view returns (address);

    /// @notice Timestamp at which the pending market implementation becomes activatable (0 if none).
    function pendingMarketImplementationActivatesAt() external view returns (uint64);

    /// @notice Propose a new market implementation. Takes effect after the timelock via
    ///         `activateSetMarketImplementation`. Reverts if `newImpl` is zero, has no code, or a
    ///         proposal is already pending.
    function proposeSetMarketImplementation(address newImpl) external;

    /// @notice Activate a previously proposed market implementation once its timelock has elapsed.
    ///         Permissionless.
    function activateSetMarketImplementation() external;

    /// @notice Cancel a pending market implementation proposal before activation.
    function cancelSetMarketImplementation() external;
}
