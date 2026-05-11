// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IOracleRouter} from "./IOracleRouter.sol";

/// @notice Minimal read surface every oracle adapter implements.
/// @dev    OracleRouter dispatches to adapters via this interface. Adapters MUST return the latest
///         valid value for `metricId`. They do NOT enforce staleness — that is the router's job.
///         They DO enforce max-delta and any source-specific validation on writes.
interface IOracleAdapter {
    function readMetric(bytes32 metricId) external view returns (IOracleRouter.OracleReading memory);

    /// @notice Wall-clock timestamp at which the upstream source produced the last stored value.
    /// @dev    Used by `OracleRouter.markIfStale` for the cadence-based auto-degrade check, so the
    ///         router can avoid the cost (and degraded-routing footgun) of going through `readMetric`
    ///         for a metric whose only purpose is to check freshness. Returns 0 for unknown metrics.
    function latestTimestamp(bytes32 metricId) external view returns (uint64);
}
