// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {FundingMath} from "../libraries/FundingMath.sol";
import {IOracleRouter} from "../oracle/IOracleRouter.sol";

import {IFundingEngine} from "./IFundingEngine.sol";
import {IPerpEngine} from "./IPerpEngine.sol";

/// @title  FundingEngine — cumulative-funding-index driver for People Markets perps.
/// @notice Pulls premium index + OI + sentiment from the upstream oracles + PerpEngine, computes
///         the per-hour funding rate via `FundingMath`, integrates over elapsed time, and pushes
///         the new cumulative index to PerpEngine.
///
/// @dev    v0 ships ONLY the index driver. Per-position settle (multiplying the index delta by
///         signed size at close and applying it to collateral) is deferred to a later wave. This
///         contract is the single source of truth for the cumulative index; PerpEngine snapshots
///         it on open via `entryFundingIndex` so the position struct stays forward-compatible.
///
/// @dev    Namespaced storage at `keccak256("people.markets.fundingengine.v1")`. The legacy
///         `FundingStorage` namespace (in `StorageLib.sol`) is RESERVED — this contract does NOT
///         use it. The cumulative index lives in the existing `FundingStorage` slot on PerpEngine
///         (written via `pushFundingIndex`); this engine's own slot stores governance, dependency
///         addresses, subject<>metric bindings, sentiment scores, and the rate coefficients.
///
/// @dev    Roles:
///           - `governance` — slow lever, timelocked. Subject registry, sentiment-writer adds,
///             coefficient changes, governance transfer.
///           - `sentimentWriters` — push-only set. Off-chain sentiment aggregator pushes a
///             score in `[-1e18, 1e18]` per registered subject.
///         Sentiment-writer revokes are NOT timelocked (immediate) to match the PerpEngine /
///         SubjectRegistry "compromised key cut-off" pattern.
contract FundingEngine is Initializable, UUPSUpgradeable, ReentrancyGuard, IFundingEngine {
    // ------------------------------------------------------------------------------------------
    // Storage namespace
    // ------------------------------------------------------------------------------------------

    /// @dev FundingEngine v1 namespace. See `StorageLib.sol` for the convention. The legacy
    ///      `FundingStorage` namespace is RESERVED — this engine has its own slot so the
    ///      coefficient bounds + writer rotation pattern can land without touching PerpEngine's
    ///      storage layout.
    bytes32 internal constant FUNDING_ENGINE_SLOT = keccak256("people.markets.fundingengine.v1");

    /// @custom:storage-location erc7201:people.markets.fundingengine.v1
    struct Layout {
        // governance + timelock
        address governance;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        uint32 timelockDelay;
        // dependencies — set at init, immutable thereafter
        address perpEngine;
        address oracleRouter;
        // subject ↔ metric bindings + reverse lookup
        mapping(bytes32 subjectId => bytes32) subjectIndexMetric;
        mapping(bytes32 metricId => bytes32) metricToSubject;
        // sentiment scores per subject (1e18-scaled, signed)
        mapping(bytes32 subjectId => int256) sentimentScore_e18;
        // sentiment-writer set + pending adds (timelocked)
        mapping(address writer => bool) sentimentWriters;
        mapping(address writer => uint64) pendingSentimentWriterActivatesAt;
        // funding coefficients (signed, 1e18)
        int256 kPremium_e18;
        int256 kSentiment_e18;
        int256 kSkew_e18;
        int256 fMaxPerHour_e18;
    }

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = FUNDING_ENGINE_SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    // ------------------------------------------------------------------------------------------
    // Constants — bounds
    // ------------------------------------------------------------------------------------------

    uint32 internal constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 internal constant MAX_TIMELOCK_DELAY = 30 days;

    int256 internal constant ONE_E18_INT = 1e18;

    /// @dev Spec §2 default coefficients (line 70-77 midpoints).
    int256 internal constant DEFAULT_K_PREMIUM = 1.25e16; // 1.25%
    int256 internal constant DEFAULT_K_SENTIMENT = 4e15; // 0.4%
    int256 internal constant DEFAULT_K_SKEW = 3e15; // 0.3%
    int256 internal constant DEFAULT_F_MAX_PER_HOUR = 7.5e14; // 0.075%/h

    /// @dev Spec §2 coefficient bands. Each coefficient is bounded so a single governance call
    ///      cannot wedge the funding model into nonsensical territory.
    int256 internal constant MIN_K_PREMIUM = 5e15;
    int256 internal constant MAX_K_PREMIUM = 2.5e16;
    int256 internal constant MIN_K_SENTIMENT = 1e15;
    int256 internal constant MAX_K_SENTIMENT = 1e16;
    int256 internal constant MIN_K_SKEW = 1e15;
    int256 internal constant MAX_K_SKEW = 8e15;
    int256 internal constant MIN_F_MAX_PER_HOUR = 5e14;
    int256 internal constant MAX_F_MAX_PER_HOUR = 1.5e15;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ------------------------------------------------------------------------------------------
    // Initializer
    // ------------------------------------------------------------------------------------------

    /// @notice Initialize the engine. One-time, called via the proxy.
    /// @param  governance_     Multi-sig that proposes/activates config changes; timelocked.
    /// @param  perpEngine_     PerpEngine address. The engine writes the cumulative index via
    ///                         `pushFundingIndex` and reads mark + OI + last-funding timestamp.
    /// @param  oracleRouter_   OracleRouter address. Source for the per-subject reference index.
    /// @param  timelockDelay_  Seconds. Must lie in [MIN_TIMELOCK_DELAY, MAX_TIMELOCK_DELAY].
    function initialize(
        address governance_,
        address perpEngine_,
        address oracleRouter_,
        uint32 timelockDelay_
    )
        external
        initializer
    {
        if (governance_ == address(0)) revert InvalidConfig();
        if (perpEngine_ == address(0) || oracleRouter_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();

        Layout storage s = _s();
        s.governance = governance_;
        s.perpEngine = perpEngine_;
        s.oracleRouter = oracleRouter_;
        s.timelockDelay = timelockDelay_;
        s.kPremium_e18 = DEFAULT_K_PREMIUM;
        s.kSentiment_e18 = DEFAULT_K_SENTIMENT;
        s.kSkew_e18 = DEFAULT_K_SKEW;
        s.fMaxPerHour_e18 = DEFAULT_F_MAX_PER_HOUR;

        emit Initialized(governance_, perpEngine_, oracleRouter_);
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != _s().governance) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlySentimentWriter() {
        if (!_s().sentimentWriters[msg.sender]) revert OnlySentimentWriter(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // pokeFunding — the load-bearing entry point
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IFundingEngine
    /// @dev Algorithm (matches spec §2):
    ///       1. Validate the subject is registered with this engine.
    ///       2. Read the reference index from the OracleRouter (router handles degraded/stale).
    ///       3. Read mark + longOI + shortOI from PerpEngine.
    ///       4. Read sentiment from local storage.
    ///       5. Compute `FundingTerms` via the pure library (no state writes here yet).
    ///       6. If this is the first poke (`lastFundingAt == 0`): seed the clock with a rate=0
    ///          push so subsequent pokes can compute an honest `elapsed`. Skip the math entirely
    ///          to avoid an artificial first-hour rate.
    ///       7. Same-block re-poke (`elapsed == 0`): no-op return — saves gas + avoids a 0-delta
    ///          push that would only emit telemetry noise.
    ///       8. `delta = computeIndexDelta(rate, elapsed)`; `newIndex = oldIndex + delta`.
    ///       9. Push to PerpEngine (which routes through `requireTradeable`, so a paused
    ///          subject's poke reverts here — the lever for spec §2 line 66 "pauses freeze
    ///          funding").
    ///
    ///      Permissionless. The reentrancy guard exists out of an abundance of caution — every
    ///      external call is to a trusted in-protocol contract, but the `nonReentrant` budget
    ///      is cheap and locks the door against an unexpected upgrade path.
    function pokeFunding(bytes32 subjectId) external nonReentrant {
        Layout storage s = _s();
        bytes32 metricId = s.subjectIndexMetric[subjectId];
        if (metricId == bytes32(0)) revert SubjectNotRegistered(subjectId);

        // Step 2 — reference index from the router. Router reverts on stale or degraded-no-fallback.
        IOracleRouter.OracleReading memory r = IOracleRouter(s.oracleRouter).read(metricId);
        uint256 index1e18 = r.value;

        // Step 3 — mark + OI from PerpEngine.
        IPerpEngine perp = IPerpEngine(s.perpEngine);
        (uint256 mark1e18,) = perp.markOf(subjectId);
        (uint256 longOi, uint256 shortOi) = perp.openInterestOf(subjectId);

        // Step 4 — sentiment.
        int256 sentiment = s.sentimentScore_e18[subjectId];

        // Step 5 — pure math, no state.
        FundingMath.FundingTerms memory terms = FundingMath.computeFundingRate(
            mark1e18,
            index1e18,
            sentiment,
            longOi,
            shortOi,
            s.kPremium_e18,
            s.kSentiment_e18,
            s.kSkew_e18,
            s.fMaxPerHour_e18
        );

        int256 currentIndex = perp.cumulativeFundingIndex(subjectId);
        uint64 last = perp.lastFundingAt(subjectId);

        // Step 6 — first poke seeds the clock with rate=0.
        if (last == 0) {
            perp.pushFundingIndex(subjectId, currentIndex, 0);
            emit FundingPoked(subjectId, currentIndex, currentIndex, 0, 0);
            return;
        }

        // Step 7 — same-block re-poke.
        if (block.timestamp == uint256(last)) {
            return;
        }
        uint64 elapsed = uint64(block.timestamp) - last;

        // Step 8 — integrate rate over elapsed into a cumulative-index delta.
        int256 delta = FundingMath.computeIndexDelta(terms.totalRate_e18, elapsed);
        int256 newIndex = currentIndex + delta;

        // Step 9 — push. Pause-aware via `requireTradeable` inside PerpEngine.
        perp.pushFundingIndex(subjectId, newIndex, terms.totalRate_e18);
        emit FundingPoked(subjectId, currentIndex, newIndex, terms.totalRate_e18, elapsed);
    }

    // ------------------------------------------------------------------------------------------
    // Sentiment writer entry point
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IFundingEngine
    function setSentimentScore(bytes32 subjectId, int256 score_e18) external onlySentimentWriter {
        if (score_e18 > ONE_E18_INT || score_e18 < -ONE_E18_INT) revert SentimentOutOfRange(score_e18);
        Layout storage s = _s();
        if (s.subjectIndexMetric[subjectId] == bytes32(0)) revert SubjectNotRegistered(subjectId);
        int256 oldScore = s.sentimentScore_e18[subjectId];
        s.sentimentScore_e18[subjectId] = score_e18;
        emit SentimentScoreSet(subjectId, oldScore, score_e18, msg.sender);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: subject registry
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IFundingEngine
    function registerSubject(bytes32 subjectId, bytes32 indexMetricId) external onlyGovernance {
        if (subjectId == bytes32(0) || indexMetricId == bytes32(0)) revert InvalidConfig();
        Layout storage s = _s();
        if (s.subjectIndexMetric[subjectId] != bytes32(0)) revert SubjectAlreadyRegistered(subjectId);
        s.subjectIndexMetric[subjectId] = indexMetricId;
        s.metricToSubject[indexMetricId] = subjectId;
        emit SubjectRegistered(subjectId, indexMetricId);
    }

    /// @inheritdoc IFundingEngine
    function deregisterSubject(bytes32 subjectId) external onlyGovernance {
        Layout storage s = _s();
        bytes32 metricId = s.subjectIndexMetric[subjectId];
        if (metricId == bytes32(0)) revert SubjectNotRegistered(subjectId);
        delete s.subjectIndexMetric[subjectId];
        delete s.metricToSubject[metricId];
        delete s.sentimentScore_e18[subjectId];
        emit SubjectDeregistered(subjectId, metricId);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: sentiment-writer rotation
    //
    // Adds are timelocked; removes are immediate. Same shape as PerpEngine.markWriters.
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IFundingEngine
    function proposeAddSentimentWriter(address writer) external onlyGovernance {
        if (writer == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        if (s.sentimentWriters[writer]) revert InvalidConfig();
        if (s.pendingSentimentWriterActivatesAt[writer] != 0) revert PendingSentimentWriterExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingSentimentWriterActivatesAt[writer] = activatesAt;
        emit SentimentWriterProposed(writer, activatesAt);
    }

    /// @inheritdoc IFundingEngine
    /// @dev Permissionless: anyone can pay the gas to flip a fully-timelocked, governance-approved
    ///      writer into the active set. Mirrors `activateAddMarkWriter` on PerpEngine.
    function activateAddSentimentWriter(address writer) external {
        Layout storage s = _s();
        uint64 readyAt = s.pendingSentimentWriterActivatesAt[writer];
        if (readyAt == 0) revert NoPendingSentimentWriter();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        delete s.pendingSentimentWriterActivatesAt[writer];
        s.sentimentWriters[writer] = true;
        emit SentimentWriterActivated(writer);
    }

    /// @inheritdoc IFundingEngine
    function cancelAddSentimentWriter(address writer) external onlyGovernance {
        Layout storage s = _s();
        if (s.pendingSentimentWriterActivatesAt[writer] == 0) revert NoPendingSentimentWriter();
        delete s.pendingSentimentWriterActivatesAt[writer];
        emit SentimentWriterCancelled(writer);
    }

    /// @inheritdoc IFundingEngine
    function removeSentimentWriter(address writer) external onlyGovernance {
        Layout storage s = _s();
        if (!s.sentimentWriters[writer]) revert SentimentWriterNotSet(writer);
        delete s.sentimentWriters[writer];
        emit SentimentWriterRemoved(writer);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: coefficients
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IFundingEngine
    /// @dev Each coefficient is validated against its spec band. The per-field error variants make
    ///      it obvious from a revert trace which value is out of range — important when an off-chain
    ///      governance proposal touches all four at once.
    function setFundingCoefficients(
        int256 kPremium_e18_,
        int256 kSentiment_e18_,
        int256 kSkew_e18_,
        int256 fMaxPerHour_e18_
    )
        external
        onlyGovernance
    {
        if (kPremium_e18_ < MIN_K_PREMIUM || kPremium_e18_ > MAX_K_PREMIUM) revert KPremiumOutOfRange(kPremium_e18_);
        if (kSentiment_e18_ < MIN_K_SENTIMENT || kSentiment_e18_ > MAX_K_SENTIMENT) {
            revert KSentimentOutOfRange(kSentiment_e18_);
        }
        if (kSkew_e18_ < MIN_K_SKEW || kSkew_e18_ > MAX_K_SKEW) revert KSkewOutOfRange(kSkew_e18_);
        if (fMaxPerHour_e18_ < MIN_F_MAX_PER_HOUR || fMaxPerHour_e18_ > MAX_F_MAX_PER_HOUR) {
            revert FMaxOutOfRange(fMaxPerHour_e18_);
        }

        Layout storage s = _s();
        s.kPremium_e18 = kPremium_e18_;
        s.kSentiment_e18 = kSentiment_e18_;
        s.kSkew_e18 = kSkew_e18_;
        s.fMaxPerHour_e18 = fMaxPerHour_e18_;
        emit FundingCoefficientsSet(kPremium_e18_, kSentiment_e18_, kSkew_e18_, fMaxPerHour_e18_);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IFundingEngine
    function proposeGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        if (s.pendingGovernanceActivatesAt != 0) revert PendingGovernanceTransferExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingGovernance = newGovernance;
        s.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGovernance, activatesAt);
    }

    /// @inheritdoc IFundingEngine
    function activateGovernanceTransfer() external {
        Layout storage s = _s();
        uint64 readyAt = s.pendingGovernanceActivatesAt;
        if (readyAt == 0) revert NoPendingGovernanceTransfer();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldGov = s.governance;
        address newGov = s.pendingGovernance;
        s.governance = newGov;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferActivated(oldGov, newGov);
    }

    /// @inheritdoc IFundingEngine
    function cancelGovernanceTransfer() external onlyGovernance {
        Layout storage s = _s();
        if (s.pendingGovernanceActivatesAt == 0) revert NoPendingGovernanceTransfer();
        address pending = s.pendingGovernance;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IFundingEngine
    function cumulativeFundingIndex(bytes32 subjectId) external view returns (int256) {
        return IPerpEngine(_s().perpEngine).cumulativeFundingIndex(subjectId);
    }

    /// @inheritdoc IFundingEngine
    function lastFundingAt(bytes32 subjectId) external view returns (uint64) {
        return IPerpEngine(_s().perpEngine).lastFundingAt(subjectId);
    }

    /// @inheritdoc IFundingEngine
    function sentimentScoreOf(bytes32 subjectId) external view returns (int256) {
        return _s().sentimentScore_e18[subjectId];
    }

    /// @inheritdoc IFundingEngine
    function metricForSubject(bytes32 subjectId) external view returns (bytes32) {
        return _s().subjectIndexMetric[subjectId];
    }

    /// @inheritdoc IFundingEngine
    function subjectForMetric(bytes32 metricId) external view returns (bytes32) {
        return _s().metricToSubject[metricId];
    }

    /// @inheritdoc IFundingEngine
    function kPremium_e18() external view returns (int256) {
        return _s().kPremium_e18;
    }

    /// @inheritdoc IFundingEngine
    function kSentiment_e18() external view returns (int256) {
        return _s().kSentiment_e18;
    }

    /// @inheritdoc IFundingEngine
    function kSkew_e18() external view returns (int256) {
        return _s().kSkew_e18;
    }

    /// @inheritdoc IFundingEngine
    function fMaxPerHour_e18() external view returns (int256) {
        return _s().fMaxPerHour_e18;
    }

    /// @inheritdoc IFundingEngine
    function governance() external view returns (address) {
        return _s().governance;
    }

    /// @inheritdoc IFundingEngine
    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        Layout storage s = _s();
        return (s.pendingGovernance, s.pendingGovernanceActivatesAt);
    }

    /// @inheritdoc IFundingEngine
    function timelockDelay() external view returns (uint32) {
        return _s().timelockDelay;
    }

    /// @inheritdoc IFundingEngine
    function perpEngine() external view returns (address) {
        return _s().perpEngine;
    }

    /// @inheritdoc IFundingEngine
    function oracleRouter() external view returns (address) {
        return _s().oracleRouter;
    }

    /// @inheritdoc IFundingEngine
    function isSentimentWriter(address account) external view returns (bool) {
        return _s().sentimentWriters[account];
    }

    /// @inheritdoc IFundingEngine
    function pendingSentimentWriterActivatesAt(address account) external view returns (uint64) {
        return _s().pendingSentimentWriterActivatesAt[account];
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
