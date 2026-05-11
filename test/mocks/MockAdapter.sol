// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IOracleAdapter} from "../../src/oracle/IOracleAdapter.sol";
import {IOracleRouter} from "../../src/oracle/IOracleRouter.sol";

/// @notice Minimal in-test adapter. Per-metric stored reading; arbitrary writes via `set`.
contract MockAdapter is IOracleAdapter {
    mapping(bytes32 => IOracleRouter.OracleReading) public readings;

    function set(bytes32 metricId, uint256 value, uint64 updatedAt) external {
        readings[metricId] = IOracleRouter.OracleReading({value: value, updatedAt: updatedAt, degraded: false});
    }

    function readMetric(bytes32 metricId) external view override returns (IOracleRouter.OracleReading memory) {
        return readings[metricId];
    }

    function latestTimestamp(bytes32 metricId) external view override returns (uint64) {
        return readings[metricId].updatedAt;
    }
}
