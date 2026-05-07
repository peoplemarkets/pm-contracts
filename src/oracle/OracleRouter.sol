// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {OracleStorage} from "../libraries/StorageLib.sol";
import {IOracleAdapter} from "./IOracleAdapter.sol";
import {IOracleRouter} from "./IOracleRouter.sol";

/// @title OracleRouter — single point of truth for external data reads.
/// @notice Every contract that needs an external value (mark, index component, event resolution,
///         sentiment) reads through this router. Adapters store the raw values; the router routes,
///         enforces staleness, exposes the safety envelope (max-delta cap configured per metric),
///         and gates all config changes behind a governance timelock.
///
/// @dev    Two roles, distinct multi-sigs:
///         - `governance` — slow lever. All config (register / fallback / staleAfter / maxDeltaBps)
///           changes timelock-gated. 48h baseline per spec.
///         - `operator`   — fast lever. ONLY `setDegraded`. No timelock. Required to be a separate
///           multi-sig from governance. Each toggle is logged with a `reasonHash` so the rationale
///           is auditable on-chain.
///
/// @dev    UUPS upgradeable. State lives in the `OracleStorage` namespace so the implementation can
///         be swapped without storage layout collisions.
contract OracleRouter is Initializable, UUPSUpgradeable, IOracleRouter {
    /// @dev Hard floor on staleAfter. Configs with staleAfter < this are rejected.
    ///      Spec §1: marks must be no older than 30s; oracle metrics are typically much slower
    ///      (hourly–daily). 1s is the absolute minimum to make config errors obvious; in practice
    ///      governance sets per-metric values from the catalog table in spec §4.
    uint32 public constant MIN_STALE_AFTER = 1;

    /// @dev Hard cap on staleAfter. Prevents accidental "infinite staleness" footguns.
    uint32 public constant MAX_STALE_AFTER = 30 days;

    /// @dev Cap on the per-refresh max-delta. 100% of value (10_000 bps) is the practical ceiling;
    ///      anything higher means "no cap" and the cap is a safety primitive, not a setting.
    uint32 public constant MAX_DELTA_BPS_CEILING = 10_000;

    /// @dev Governance timelock bounds. Spec baseline 48h. We enforce a floor (no instant changes,
    ///      ever) and a ceiling (so a misconfigured timelock can be repaired).
    uint32 public constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 public constant MAX_TIMELOCK_DELAY = 30 days;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize router state. Called once via the proxy on deployment.
    /// @param governance_ Multi-sig that proposes/activates config changes; subject to timelock.
    /// @param operator_   Multi-sig that may toggle the `degraded` flag with no timelock.
    /// @param timelockDelay_ Seconds. Must be in [MIN_TIMELOCK_DELAY, MAX_TIMELOCK_DELAY].
    function initialize(address governance_, address operator_, uint32 timelockDelay_) external initializer {
        if (governance_ == address(0) || operator_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();
        OracleStorage.Layout storage s = OracleStorage.load();
        s.governance = governance_;
        s.operator = operator_;
        s.timelockDelay = timelockDelay_;
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != OracleStorage.load().governance) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != OracleStorage.load().operator) revert Unauthorized(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // Governance: register / replace metric config (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleRouter
    function proposeRegister(bytes32 metricId, MetricConfig calldata config) external onlyGovernance {
        _validateConfig(config);
        OracleStorage.Layout storage s = OracleStorage.load();
        // We allow proposeRegister for both NEW registration AND replacement of an existing config.
        // The only invariant: at most one pending proposal per metricId. To replace a pending
        // proposal, governance must cancel first.
        if (s.pending[metricId].exists) revert MetricAlreadyRegistered(metricId);

        uint64 activatesAt = uint64(block.timestamp) + uint64(s.timelockDelay);
        s.pending[metricId] = OracleStorage.PendingChange({config: config, activatesAt: activatesAt, exists: true});
        emit MetricProposed(metricId, config, activatesAt);
    }

    /// @inheritdoc IOracleRouter
    function activateRegister(bytes32 metricId) external {
        OracleStorage.Layout storage s = OracleStorage.load();
        OracleStorage.PendingChange storage p = s.pending[metricId];
        if (!p.exists) revert NoPendingProposal(metricId);
        if (block.timestamp < p.activatesAt) revert TimelockNotElapsed(metricId, p.activatesAt);

        MetricConfig memory cfg = p.config;
        s.configs[metricId] = cfg;
        delete s.pending[metricId];
        emit MetricActivated(metricId, cfg);
    }

    /// @inheritdoc IOracleRouter
    function cancelProposal(bytes32 metricId) external onlyGovernance {
        OracleStorage.Layout storage s = OracleStorage.load();
        if (!s.pending[metricId].exists) revert NoPendingProposal(metricId);
        delete s.pending[metricId];
        emit ProposalCancelled(metricId);
    }

    // ------------------------------------------------------------------------------------------
    // Operator: degraded flag (no timelock; logged)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleRouter
    function setDegraded(bytes32 metricId, bool degraded, bytes32 reasonHash) external onlyOperator {
        OracleStorage.Layout storage s = OracleStorage.load();
        MetricConfig storage c = s.configs[metricId];
        if (c.sourceType == SourceType.UNSET) revert MetricNotRegistered(metricId);
        c.degraded = degraded;
        emit MetricDegraded(metricId, degraded, reasonHash);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: fallback adapter (timelocked, narrower than full config replace)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleRouter
    function proposeSetFallback(bytes32 metricId, address fallbackAdapter) external onlyGovernance {
        OracleStorage.Layout storage s = OracleStorage.load();
        if (s.configs[metricId].sourceType == SourceType.UNSET) revert MetricNotRegistered(metricId);
        // address(0) IS a valid fallback target — it explicitly removes the fallback. The router
        // will revert any read that hits the degraded-with-no-fallback branch, which is the desired
        // behavior (better to halt than to silently read from a bad adapter).
        uint64 activatesAt = uint64(block.timestamp) + uint64(s.timelockDelay);
        s.pendingFallback[metricId] = fallbackAdapter;
        s.pendingFallbackActivatesAt[metricId] = activatesAt;
        emit FallbackProposed(metricId, fallbackAdapter, activatesAt);
    }

    /// @inheritdoc IOracleRouter
    function activateSetFallback(bytes32 metricId) external {
        OracleStorage.Layout storage s = OracleStorage.load();
        uint64 readyAt = s.pendingFallbackActivatesAt[metricId];
        if (readyAt == 0) revert NoPendingProposal(metricId);
        if (block.timestamp < readyAt) revert TimelockNotElapsed(metricId, readyAt);

        address newFallback = s.pendingFallback[metricId];
        s.configs[metricId].fallbackAdapter = newFallback;
        delete s.pendingFallback[metricId];
        delete s.pendingFallbackActivatesAt[metricId];
        emit FallbackActivated(metricId, newFallback);
    }

    // ------------------------------------------------------------------------------------------
    // Reads
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleRouter
    function read(bytes32 metricId) external view returns (OracleReading memory reading) {
        OracleStorage.Layout storage s = OracleStorage.load();
        MetricConfig memory cfg = s.configs[metricId];
        if (cfg.sourceType == SourceType.UNSET) revert MetricNotRegistered(metricId);

        address adapter;
        if (cfg.degraded) {
            if (cfg.fallbackAdapter == address(0)) revert DegradedAndNoFallback(metricId);
            adapter = cfg.fallbackAdapter;
        } else {
            adapter = cfg.adapter;
        }

        reading = IOracleAdapter(adapter).readMetric(metricId);
        if (uint64(block.timestamp) > reading.updatedAt + uint64(cfg.staleAfter)) {
            revert StaleReading(metricId, reading.updatedAt, cfg.staleAfter);
        }
        // surface the degraded flag to consumers so they can decide whether to halt downstream
        reading.degraded = cfg.degraded;
    }

    /// @inheritdoc IOracleRouter
    function configOf(bytes32 metricId) external view returns (MetricConfig memory) {
        return OracleStorage.load().configs[metricId];
    }

    function pendingOf(bytes32 metricId) external view returns (OracleStorage.PendingChange memory) {
        return OracleStorage.load().pending[metricId];
    }

    function pendingFallbackOf(bytes32 metricId) external view returns (address adapter, uint64 activatesAt) {
        OracleStorage.Layout storage s = OracleStorage.load();
        return (s.pendingFallback[metricId], s.pendingFallbackActivatesAt[metricId]);
    }

    function governance() external view returns (address) {
        return OracleStorage.load().governance;
    }

    function operator() external view returns (address) {
        return OracleStorage.load().operator;
    }

    function timelockDelay() external view returns (uint32) {
        return OracleStorage.load().timelockDelay;
    }

    // ------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------

    function _validateConfig(MetricConfig calldata config) internal pure {
        if (config.sourceType == SourceType.UNSET) revert InvalidConfig();
        if (config.adapter == address(0)) revert InvalidConfig();
        if (config.staleAfter < MIN_STALE_AFTER || config.staleAfter > MAX_STALE_AFTER) {
            revert InvalidConfig();
        }
        if (config.maxDeltaBps == 0 || config.maxDeltaBps > MAX_DELTA_BPS_CEILING) revert InvalidConfig();
        // `degraded` may be either; setting it true at registration is a valid pre-staging move.
        // `fallbackAdapter == address(0)` is allowed; reads will revert if degraded is true and no
        // fallback is configured, which is the conservative fail-closed behavior.
    }

    /// @dev UUPS authorization. Upgrades are governance-gated; the timelock is enforced by the
    ///      governance multi-sig executing through its own timelock contract. We do NOT add a
    ///      second timelock here — defense in depth is fine but a double-locked upgrade path makes
    ///      emergency response on a bricked upgrade harder than it needs to be.
    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
