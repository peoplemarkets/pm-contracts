// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

interface IEventMarketFactory {
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

    function getMarket(bytes32 eventId) external view returns (address);
    function onMarketResolved(
        bytes32 subjectId,
        bytes32 eventId,
        uint8 eventClass,
        int256 outcomeScore_e18,
        uint256 returnedAmount
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
}
