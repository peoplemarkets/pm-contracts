// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @notice Minimal Chainlink AggregatorV3 mock used by ChainlinkAdapter tests.
/// @dev    `setAnswer(int256, uint64)` sets the latest answer and `updatedAt`. Round-id /
///         answeredInRound are auto-managed but can be overridden via `setRound`. Decimals are
///         frozen at construction.
contract MockAggregatorV3 {
    uint8 public decimals;

    uint80 internal _roundId;
    int256 internal _answer;
    uint256 internal _startedAt;
    uint256 internal _updatedAt;
    uint80 internal _answeredInRound;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    /// @notice Convenience helper: set the answer + updatedAt, auto-increment roundId, set
    ///         answeredInRound = roundId, startedAt = updatedAt.
    function setAnswer(int256 answer, uint64 updatedAt) external {
        _roundId += 1;
        _answer = answer;
        _startedAt = updatedAt;
        _updatedAt = updatedAt;
        _answeredInRound = _roundId;
    }

    /// @notice Full-control round setter; used by edge-case tests.
    function setRound(
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    )
        external
    {
        _roundId = roundId_;
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = answeredInRound_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}
