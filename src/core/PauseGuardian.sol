// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {PauseGuardianStorage} from "../libraries/StorageLib.sol";
import {ISubjectRegistry} from "../registry/ISubjectRegistry.sol";

import {IPerpEngine} from "./IPerpEngine.sol";

/// @title PauseGuardian — on-chain circuit-breaker detection.
/// @notice Watches each subject's mark series and trips the `SubjectRegistry` pause tiers when a
///         price move exceeds spec-defined thresholds:
///           - 5%  move over 30s     →  `AUTO_PAUSED` (auto-resume after 30s)
///           - 10% move over 30min   →  `COOLDOWN`    (admin review)
///           - 20% move over 60min   →  `FROZEN`      (admin review)
///         These are spec §3 lines 165–176. The PauseGuardian automates the trigger decision; the
///         actual pause-state flip and unpause flow stay in `SubjectRegistry`.
///
/// @dev    Pull model. PerpEngine never calls into the guardian on the mark-push hot path. Instead,
///         a permissionless `observe(subjectId)` reads the latest `(mark, timestamp)` from PerpEngine
///         and appends to a per-subject ring buffer. Keeper bots (or any caller) can drive the cadence;
///         storage spam is bounded by a 5-second minimum interval per subject.
///
/// @dev    The contract holds **two** registry roles:
///           - `PAUSE_GUARDIAN` — needed to call `setAutoPaused` / `setCooldown`
///           - `SUBJECT_ADMIN`  — needed to call `setFrozen` (spec keeps the 20% trigger behind admin
///                                review; the guardian still automates the *detection*, but a
///                                misconfigured admin grant would weaken the review property —
///                                document this in deployment runbooks).
///         Both roles are granted by `SubjectRegistry.activateRoleChange` after the timelock.
///
/// @dev    Worst-tier-wins. When a single observation breaches multiple thresholds simultaneously,
///         the guardian picks the highest tier (FROZEN > COOLDOWN > AUTO_PAUSED) and skips the
///         lower-tier calls. Lower tiers must still be entered from ACTIVE per the registry's
///         transition rules; chaining auto→cooldown→frozen would obscure the audit trail.
///
/// @dev    Idempotency: if the subject is already in a pause tier (any of AUTO_PAUSED / COOLDOWN /
///         FROZEN / DEATH_PENDING / DELISTING / DELISTED), the guardian no-ops. Re-pausing requires
///         the registry to be back at ACTIVE.
///
/// @dev    UUPS upgradeable. Storage namespaced via `PauseGuardianStorage`.
contract PauseGuardian is Initializable, UUPSUpgradeable {
    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Hard floor: at least 5 seconds between observations of the same subject. Defeats
    ///      same-block storage spam without blocking legitimate high-cadence keepers (mark pushes
    ///      under spec §1 are ~30s; this leaves 6× headroom).
    uint32 public constant MIN_OBSERVATION_INTERVAL_SECONDS = 5;

    uint32 public constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 public constant MAX_TIMELOCK_DELAY = 30 days;

    /// @dev Threshold bounds (basis points). Each tier in [10, 5000] bps i.e. 0.1%–50%. Below 10bps
    ///      would trip on rounding noise; above 50% is meaningless given a single mark push is
    ///      capped at 50% (PerpEngine `MAX_MARK_MAX_DELTA_BPS`).
    uint16 public constant MIN_THRESHOLD_BPS = 10;
    uint16 public constant MAX_THRESHOLD_BPS = 5_000;

    /// @dev Window bounds (seconds). Lower bound matches the rate-limit floor; upper bound is one
    ///      day (any longer and ring-buffer coverage becomes unreliable).
    uint32 public constant MIN_WINDOW_SECONDS = 5;
    uint32 public constant MAX_WINDOW_SECONDS = 1 days;

    /// @dev Reason codes passed through to `SubjectRegistry.PauseTriggered`. Matches the spec's three
    ///      breaker tiers. `0` is reserved for "manual / unknown" external pauses; the guardian never
    ///      emits 0.
    uint8 public constant REASON_5PCT_30S = 1;
    uint8 public constant REASON_10PCT_30M = 2;
    uint8 public constant REASON_20PCT_60M = 3;

    /// @dev Tier identifiers used in the `BreakerTriggered` event. Mirrors the registry's pause-tier
    ///      ordering with FROZEN being the worst tier.
    uint8 internal constant TIER_NONE = 0;
    uint8 internal constant TIER_AUTO_PAUSED = 1;
    uint8 internal constant TIER_COOLDOWN = 2;
    uint8 internal constant TIER_FROZEN = 3;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ------------------------------------------------------------------------------------------
    // Initializer
    // ------------------------------------------------------------------------------------------

    /// @notice Initialize the guardian. One-time, called via the proxy.
    /// @param  governance_      Multi-sig that proposes/activates threshold changes and upgrades.
    /// @param  perpEngine_      The PerpEngine the guardian reads marks from.
    /// @param  subjectRegistry_ The SubjectRegistry the guardian flips pause tiers on.
    /// @param  timelockDelay_   Governance timelock delay in seconds (bounds: 1h .. 30d).
    function initialize(
        address governance_,
        address perpEngine_,
        address subjectRegistry_,
        uint32 timelockDelay_
    )
        external
        initializer
    {
        if (governance_ == address(0) || perpEngine_ == address(0) || subjectRegistry_ == address(0)) {
            revert InvalidConfig();
        }
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();

        PauseGuardianStorage.Layout storage s = PauseGuardianStorage.load();
        s.governance = governance_;
        s.perpEngine = perpEngine_;
        s.subjectRegistry = subjectRegistry_;
        s.timelockDelay = timelockDelay_;

        // Spec §3 line 169–171 defaults.
        s.auto5MinBps = 500; // 5%
        s.cooldown30MinBps = 1_000; // 10%
        s.frozen60MinBps = 2_000; // 20%
        s.auto5WindowSeconds = 30;
        s.cooldown30WindowSeconds = 30 minutes;
        s.frozen60WindowSeconds = 1 hours;
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != PauseGuardianStorage.load().governance) revert Unauthorized(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // Observation entrypoint
    // ------------------------------------------------------------------------------------------

    /// @notice Record a fresh mark observation for a subject and run breaker checks.
    /// @dev    Permissionless. Reads the latest `(mark, updatedAt)` from PerpEngine. Skips append +
    ///         check if (a) the minimum interval since the last recorded observation has not
    ///         elapsed, (b) the mark has never been pushed, or (c) the new observation is older
    ///         than the most recent one already recorded (PerpEngine pushes monotonically so this
    ///         only happens if the latest push was already recorded). After append, runs
    ///         `_checkBreakers` which trips the worst-tier breach (if any).
    /// @param  subjectId The subject to observe.
    function observe(bytes32 subjectId) external {
        PauseGuardianStorage.Layout storage s = PauseGuardianStorage.load();
        (uint256 mark, uint64 updatedAt) = IPerpEngine(s.perpEngine).markOf(subjectId);
        if (mark == 0) revert MarkNotSet(subjectId);

        PauseGuardianStorage.Ring storage ring = s.rings[subjectId];

        // If we already have observations, enforce the rate-limit AND require the new push to be
        // newer (or equal-and-different) than the last recorded one. Recording the same `updatedAt`
        // twice would write a duplicate observation that consumes a buffer slot without adding
        // information — skip silently with an informational event.
        if (ring.length != 0) {
            uint16 lastIdx = _prevIndex(ring.head);
            PauseGuardianStorage.Observation memory last = ring.entries[lastIdx];
            uint64 nextEligible = last.timestamp + uint64(MIN_OBSERVATION_INTERVAL_SECONDS);
            if (uint64(block.timestamp) < nextEligible) {
                revert IntervalNotElapsed(subjectId, last.timestamp, nextEligible);
            }
            if (updatedAt <= last.timestamp) {
                // PerpEngine has not pushed a fresher mark since the last observation. Skip without
                // reverting — keepers must be able to call repeatedly without per-call book-keeping.
                emit MarkUnchangedNoBreach(subjectId, last.timestamp, updatedAt);
                return;
            }
        }

        // Append.
        ring.entries[ring.head] =
            PauseGuardianStorage.Observation({mark: uint192(mark), timestamp: uint64(updatedAt)});
        ring.head = _nextIndex(ring.head);
        if (ring.length < PauseGuardianStorage.RING_SIZE) {
            ring.length += 1;
        }
        emit ObservationRecorded(subjectId, mark, uint64(updatedAt));

        _checkBreakers(s, subjectId, ring, uint192(mark));
    }

    // ------------------------------------------------------------------------------------------
    // Breaker evaluation
    // ------------------------------------------------------------------------------------------

    /// @dev Walks the ring from newest to oldest, tracking the worst-percentage move against the
    ///      *current* mark within each of the three windows. Picks the highest tier whose threshold
    ///      is breached and (if higher than the subject's current pause status) calls the matching
    ///      registry setter.
    function _checkBreakers(
        PauseGuardianStorage.Layout storage s,
        bytes32 subjectId,
        PauseGuardianStorage.Ring storage ring,
        uint192 currentMark
    )
        internal
    {
        // Read current registry status: if the subject is already in an equal-or-worse pause tier
        // (or in a terminal/non-pausable state) we no-op. Cheaper than three setX reverts.
        ISubjectRegistry registry = ISubjectRegistry(s.subjectRegistry);
        ISubjectRegistry.SubjectStatus status = registry.statusOf(subjectId);

        // Pauses move from ACTIVE only (per `SubjectRegistry._setPause`). If the subject is already
        // paused, terminating, delisted, or death-pending, there is nothing to do.
        if (status != ISubjectRegistry.SubjectStatus.ACTIVE) return;

        uint64 nowTs = uint64(block.timestamp);
        uint16 auto5Bps = s.auto5MinBps;
        uint16 cd30Bps = s.cooldown30MinBps;
        uint16 fz60Bps = s.frozen60MinBps;
        uint64 auto5From = nowTs - uint64(s.auto5WindowSeconds);
        uint64 cd30From = nowTs - uint64(s.cooldown30WindowSeconds);
        uint64 fz60From = nowTs - uint64(s.frozen60WindowSeconds);

        // Track the maximum |currentMark − pastMark| × 10_000 / pastMark over each window. The
        // past mark is the denominator so a 5% move from $100 → $105 reads as 500 bps regardless
        // of direction (matches the spec §3 "5% mark move" framing — percentage moves are quoted
        // relative to the prior reference price, not the new price).
        uint256 maxBpsAuto5 = 0;
        uint256 maxBpsCd30 = 0;
        uint256 maxBpsFz60 = 0;

        uint16 head = ring.head;
        uint16 len = ring.length;
        uint16 idx = head;
        for (uint16 i = 0; i < len; ++i) {
            idx = _prevIndex(idx);
            PauseGuardianStorage.Observation memory o = ring.entries[idx];
            // Once we walk past the longest window, the rest of the buffer is irrelevant.
            if (o.timestamp < fz60From) break;
            // Reference-price denominator. Spec §3 "5% mark move in 30s" reads naturally as
            // |new − old| / old, so the past observation's mark is the reference. Skip entries
            // with mark == 0 defensively (should never happen — observations are only appended
            // with a positive PerpEngine mark — but a zero would otherwise divide-by-zero).
            if (o.mark == 0) continue;

            uint256 diff = currentMark >= o.mark
                ? uint256(currentMark) - uint256(o.mark)
                : uint256(o.mark) - uint256(currentMark);
            uint256 moveBps = (diff * uint256(BPS_DENOMINATOR)) / uint256(o.mark);

            if (o.timestamp >= auto5From && moveBps > maxBpsAuto5) maxBpsAuto5 = moveBps;
            if (o.timestamp >= cd30From && moveBps > maxBpsCd30) maxBpsCd30 = moveBps;
            if (moveBps > maxBpsFz60) maxBpsFz60 = moveBps;
        }

        // Worst-tier-wins. Highest-precedence breach is evaluated first so we never enter a lower
        // tier when a higher one applies. Cap the observed bps at uint16 max for the event field —
        // any value above 65_535 bps (655%) is sensational enough that the cap doesn't lose info.
        if (maxBpsFz60 >= fz60Bps) {
            emit BreakerTriggered(subjectId, TIER_FROZEN, _capBps(maxBpsFz60), fz60Bps);
            registry.setFrozen(subjectId, REASON_20PCT_60M);
            return;
        }
        if (maxBpsCd30 >= cd30Bps) {
            emit BreakerTriggered(subjectId, TIER_COOLDOWN, _capBps(maxBpsCd30), cd30Bps);
            registry.setCooldown(subjectId, REASON_10PCT_30M);
            return;
        }
        if (maxBpsAuto5 >= auto5Bps) {
            emit BreakerTriggered(subjectId, TIER_AUTO_PAUSED, _capBps(maxBpsAuto5), auto5Bps);
            registry.setAutoPaused(subjectId, REASON_5PCT_30S);
            return;
        }
    }

    function _capBps(uint256 bps) internal pure returns (uint16) {
        return bps > type(uint16).max ? type(uint16).max : uint16(bps);
    }

    function _nextIndex(uint16 idx) internal pure returns (uint16) {
        unchecked {
            uint16 next = idx + 1;
            return next == PauseGuardianStorage.RING_SIZE ? 0 : next;
        }
    }

    function _prevIndex(uint16 idx) internal pure returns (uint16) {
        unchecked {
            return idx == 0 ? PauseGuardianStorage.RING_SIZE - 1 : idx - 1;
        }
    }

    // ------------------------------------------------------------------------------------------
    // Governance: threshold/window changes (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @notice Propose a new set of breaker thresholds and windows. Single in-flight proposal.
    /// @dev    All three tiers move together: a misordered breaker schedule (e.g. cooldown threshold
    ///         below auto-pause threshold) is harder to spot in slice-by-slice updates. Ordering is
    ///         enforced: `auto5 < cd30 < fz60` (bps and windows both monotone non-decreasing).
    /// @param  auto5Bps         New 5%/30s threshold (bps).
    /// @param  cd30Bps          New 10%/30m threshold (bps).
    /// @param  fz60Bps          New 20%/60m threshold (bps).
    /// @param  auto5Window      New 30s window (seconds).
    /// @param  cd30Window       New 30m window (seconds).
    /// @param  fz60Window       New 60m window (seconds).
    function proposeSetThresholds(
        uint16 auto5Bps,
        uint16 cd30Bps,
        uint16 fz60Bps,
        uint32 auto5Window,
        uint32 cd30Window,
        uint32 fz60Window
    )
        external
        onlyGovernance
    {
        _validateThresholds(auto5Bps, cd30Bps, fz60Bps, auto5Window, cd30Window, fz60Window);
        PauseGuardianStorage.Layout storage s = PauseGuardianStorage.load();
        if (s.pendingThresholds.exists) revert PendingThresholdsExist();
        uint64 activatesAt = uint64(block.timestamp) + uint64(s.timelockDelay);
        s.pendingThresholds = PauseGuardianStorage.PendingThresholds({
            auto5MinBps: auto5Bps,
            cooldown30MinBps: cd30Bps,
            frozen60MinBps: fz60Bps,
            auto5WindowSeconds: auto5Window,
            cooldown30WindowSeconds: cd30Window,
            frozen60WindowSeconds: fz60Window,
            activatesAt: activatesAt,
            exists: true
        });
        emit ThresholdsProposed(auto5Bps, cd30Bps, fz60Bps, auto5Window, cd30Window, fz60Window, activatesAt);
    }

    /// @notice Activate the pending threshold proposal once the timelock has elapsed.
    /// @dev    Permissionless — anyone can trigger activation after the delay (matches the
    ///         OracleRouter and SubjectRegistry pattern).
    function activateSetThresholds() external {
        PauseGuardianStorage.Layout storage s = PauseGuardianStorage.load();
        PauseGuardianStorage.PendingThresholds memory p = s.pendingThresholds;
        if (!p.exists) revert NoPendingThresholds();
        if (block.timestamp < p.activatesAt) revert TimelockNotElapsed(p.activatesAt);
        s.auto5MinBps = p.auto5MinBps;
        s.cooldown30MinBps = p.cooldown30MinBps;
        s.frozen60MinBps = p.frozen60MinBps;
        s.auto5WindowSeconds = p.auto5WindowSeconds;
        s.cooldown30WindowSeconds = p.cooldown30WindowSeconds;
        s.frozen60WindowSeconds = p.frozen60WindowSeconds;
        delete s.pendingThresholds;
        emit ThresholdsActivated(
            p.auto5MinBps,
            p.cooldown30MinBps,
            p.frozen60MinBps,
            p.auto5WindowSeconds,
            p.cooldown30WindowSeconds,
            p.frozen60WindowSeconds
        );
    }

    /// @notice Cancel the pending threshold proposal. Governance only.
    function cancelSetThresholds() external onlyGovernance {
        PauseGuardianStorage.Layout storage s = PauseGuardianStorage.load();
        if (!s.pendingThresholds.exists) revert NoPendingThresholds();
        delete s.pendingThresholds;
        emit ThresholdsCancelled();
    }

    function _validateThresholds(
        uint16 auto5Bps,
        uint16 cd30Bps,
        uint16 fz60Bps,
        uint32 auto5Window,
        uint32 cd30Window,
        uint32 fz60Window
    )
        internal
        pure
    {
        if (auto5Bps < MIN_THRESHOLD_BPS || auto5Bps > MAX_THRESHOLD_BPS) revert ThresholdOutOfRange(auto5Bps);
        if (cd30Bps < MIN_THRESHOLD_BPS || cd30Bps > MAX_THRESHOLD_BPS) revert ThresholdOutOfRange(cd30Bps);
        if (fz60Bps < MIN_THRESHOLD_BPS || fz60Bps > MAX_THRESHOLD_BPS) revert ThresholdOutOfRange(fz60Bps);
        // Each higher tier must require a strictly larger move OR a strictly longer window — in
        // practice both. Equal-or-decreasing tiers would let a 60-minute breach trip COOLDOWN
        // before FROZEN.
        if (cd30Bps <= auto5Bps) revert ThresholdOutOfRange(cd30Bps);
        if (fz60Bps <= cd30Bps) revert ThresholdOutOfRange(fz60Bps);
        if (auto5Window < MIN_WINDOW_SECONDS || auto5Window > MAX_WINDOW_SECONDS) revert WindowOutOfRange(auto5Window);
        if (cd30Window < MIN_WINDOW_SECONDS || cd30Window > MAX_WINDOW_SECONDS) revert WindowOutOfRange(cd30Window);
        if (fz60Window < MIN_WINDOW_SECONDS || fz60Window > MAX_WINDOW_SECONDS) revert WindowOutOfRange(fz60Window);
        if (cd30Window <= auto5Window) revert WindowOutOfRange(cd30Window);
        if (fz60Window <= cd30Window) revert WindowOutOfRange(fz60Window);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @notice Propose a governance handover. Single in-flight; matches the OracleRouter pattern.
    function proposeGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidConfig();
        PauseGuardianStorage.Layout storage s = PauseGuardianStorage.load();
        if (s.pendingGovernanceActivatesAt != 0) revert PendingGovernanceExists();
        uint64 activatesAt = uint64(block.timestamp) + uint64(s.timelockDelay);
        s.pendingGovernance = newGovernance;
        s.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGovernance, activatesAt);
    }

    /// @notice Activate the pending governance transfer once the timelock has elapsed.
    /// @dev    Permissionless after the delay.
    function activateGovernanceTransfer() external {
        PauseGuardianStorage.Layout storage s = PauseGuardianStorage.load();
        uint64 readyAt = s.pendingGovernanceActivatesAt;
        if (readyAt == 0) revert NoPendingGovernance();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldGov = s.governance;
        address newGov = s.pendingGovernance;
        s.governance = newGov;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferActivated(oldGov, newGov);
    }

    /// @notice Cancel the pending governance transfer. Governance only.
    function cancelGovernanceTransfer() external onlyGovernance {
        PauseGuardianStorage.Layout storage s = PauseGuardianStorage.load();
        if (s.pendingGovernanceActivatesAt == 0) revert NoPendingGovernance();
        address pending = s.pendingGovernance;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    /// @notice Address of the PerpEngine the guardian reads marks from.
    function perpEngine() external view returns (address) {
        return PauseGuardianStorage.load().perpEngine;
    }

    /// @notice Address of the SubjectRegistry the guardian flips pause tiers on.
    function subjectRegistry() external view returns (address) {
        return PauseGuardianStorage.load().subjectRegistry;
    }

    /// @notice Current governance multi-sig.
    function governance() external view returns (address) {
        return PauseGuardianStorage.load().governance;
    }

    /// @notice Governance timelock delay (seconds).
    function timelockDelay() external view returns (uint32) {
        return PauseGuardianStorage.load().timelockDelay;
    }

    /// @notice Current breaker thresholds (basis points).
    /// @return auto5Bps  5%/30s tier threshold.
    /// @return cd30Bps   10%/30m tier threshold.
    /// @return fz60Bps   20%/60m tier threshold.
    function thresholds() external view returns (uint16 auto5Bps, uint16 cd30Bps, uint16 fz60Bps) {
        PauseGuardianStorage.Layout storage s = PauseGuardianStorage.load();
        return (s.auto5MinBps, s.cooldown30MinBps, s.frozen60MinBps);
    }

    /// @notice Current breaker windows (seconds).
    /// @return auto5Window 5%/30s tier window.
    /// @return cd30Window  10%/30m tier window.
    /// @return fz60Window  20%/60m tier window.
    function windows() external view returns (uint32 auto5Window, uint32 cd30Window, uint32 fz60Window) {
        PauseGuardianStorage.Layout storage s = PauseGuardianStorage.load();
        return (s.auto5WindowSeconds, s.cooldown30WindowSeconds, s.frozen60WindowSeconds);
    }

    /// @notice Pending threshold proposal (if any).
    function pendingThresholds() external view returns (PauseGuardianStorage.PendingThresholds memory) {
        return PauseGuardianStorage.load().pendingThresholds;
    }

    /// @notice Pending governance handover (if any).
    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        PauseGuardianStorage.Layout storage s = PauseGuardianStorage.load();
        return (s.pendingGovernance, s.pendingGovernanceActivatesAt);
    }

    /// @notice Number of observations currently buffered for `subjectId`.
    function observationCount(bytes32 subjectId) external view returns (uint16) {
        return PauseGuardianStorage.load().rings[subjectId].length;
    }

    /// @notice Most recent observation for `subjectId`, or `(0, 0)` if none.
    function lastObservation(bytes32 subjectId) external view returns (uint192 mark, uint64 timestamp) {
        PauseGuardianStorage.Ring storage ring = PauseGuardianStorage.load().rings[subjectId];
        if (ring.length == 0) return (0, 0);
        PauseGuardianStorage.Observation memory o = ring.entries[_prevIndex(ring.head)];
        return (o.mark, o.timestamp);
    }

    /// @notice The N-th most-recent observation for `subjectId` (0 = newest, 1 = second-newest, …).
    /// @dev    Reverts if `n >= observationCount(subjectId)`.
    function observationAt(bytes32 subjectId, uint16 n) external view returns (uint192 mark, uint64 timestamp) {
        PauseGuardianStorage.Ring storage ring = PauseGuardianStorage.load().rings[subjectId];
        if (n >= ring.length) revert ObservationOutOfRange(n, ring.length);
        uint16 idx = ring.head;
        for (uint16 i = 0; i <= n; ++i) {
            idx = _prevIndex(idx);
        }
        PauseGuardianStorage.Observation memory o = ring.entries[idx];
        return (o.mark, o.timestamp);
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    /// @dev UUPS authorization. Upgrades are governance-gated; the timelock is enforced by the
    ///      governance multi-sig executing through its own timelock contract. Same posture as
    ///      OracleRouter / SubjectRegistry — no second in-contract timelock.
    function _authorizeUpgrade(address) internal override onlyGovernance {}

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event ObservationRecorded(bytes32 indexed subjectId, uint256 mark, uint64 timestamp);
    event MarkUnchangedNoBreach(bytes32 indexed subjectId, uint64 lastTimestamp, uint64 latestTimestamp);
    event BreakerTriggered(bytes32 indexed subjectId, uint8 tier, uint16 observedBps, uint16 thresholdBps);
    event ThresholdsProposed(
        uint16 auto5Bps,
        uint16 cd30Bps,
        uint16 fz60Bps,
        uint32 auto5Window,
        uint32 cd30Window,
        uint32 fz60Window,
        uint64 activatesAt
    );
    event ThresholdsActivated(
        uint16 auto5Bps,
        uint16 cd30Bps,
        uint16 fz60Bps,
        uint32 auto5Window,
        uint32 cd30Window,
        uint32 fz60Window
    );
    event ThresholdsCancelled();
    event GovernanceTransferProposed(address indexed newGovernance, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceTransferCancelled(address indexed pendingGovernance);

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error Unauthorized(address caller);
    error InvalidConfig();
    error MarkNotSet(bytes32 subjectId);
    error IntervalNotElapsed(bytes32 subjectId, uint64 lastObservation, uint64 nextEligible);
    error ThresholdOutOfRange(uint16 bps);
    error WindowOutOfRange(uint32 secondsValue);
    error PendingThresholdsExist();
    error NoPendingThresholds();
    error PendingGovernanceExists();
    error NoPendingGovernance();
    error TimelockNotElapsed(uint64 readyAt);
    error ObservationOutOfRange(uint16 requested, uint16 length);
}
