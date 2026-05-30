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
    ) external returns (address);

    function getMarket(bytes32 eventId) external view returns (address);
    function onMarketResolved(bytes32 subjectId, bytes32 eventId, uint8 eventClass, int256 outcomeScore_e18, uint256 returnedAmount) external;
}
