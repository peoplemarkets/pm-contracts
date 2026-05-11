// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {IPerpEngine} from "../core/IPerpEngine.sol";
import {ISubjectRegistry} from "../registry/ISubjectRegistry.sol";

import {IFeedbackController} from "./IFeedbackController.sol";

/// @title  FeedbackController — event-resolution → mark-impulse driver for People Markets.
/// @notice An off-chain resolver pushes resolutions (`{subjectId, eventClass, outcomeScore,
///         eventTimestamp}`). The controller:
///           1. validates the inputs + that the subject is tradeable (spec §3 line 173);
///           2. computes the raw mark impulse as `(coefficient × outcomeScore × 10000) / 1e36`;
///           3. caps at ±`impulseCapBps` (spec §3 line 132, default 15%);
///           4. discounts for lateness per spec §5 (the longer between event-start and
///              resolution, the smaller the impulse — a stale resolution should not move the
///              mark like a fresh one);
///           5. calls `PerpEngine.applyImpulse(subjectId, finalImpulseBps)` to bump the mark.
///
/// @dev    Namespaced storage at `keccak256("people.markets.feedbackcontroller.v1")`. The legacy
///         `FeedbackStorage` namespace (in `StorageLib.sol`) is RESERVED — this contract uses its
///         own slot so the per-event-class coefficient layout (signed int256, indexed by the
///         spec §2 enum) can land without disturbing the reserved layout.
contract FeedbackController is Initializable, UUPSUpgradeable, ReentrancyGuard, IFeedbackController {
    // ------------------------------------------------------------------------------------------
    // Storage namespace
    // ------------------------------------------------------------------------------------------

    bytes32 internal constant FEEDBACK_CONTROLLER_SLOT = keccak256("people.markets.feedbackcontroller.v1");

    /// @custom:storage-location erc7201:people.markets.feedbackcontroller.v1
    struct Layout {
        // governance + timelock
        address governance;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        uint32 timelockDelay;
        // dependencies
        address perpEngine;
        address oracleRouter;
        // coefficients: signed, 1e18 scale, per event class
        mapping(IFeedbackController.EventClass => int256) coefficients_e18;
        // per-resolution impulse cap (basis points of mark)
        uint16 impulseCapBps_;
        // late-move discount parameters
        uint64 lateMoveDenominator_;
        uint64 lateMoveSlope_;
        uint16 maxDiscountBps_;
        // resolution-writer set + pending adds (timelocked)
        mapping(address writer => bool) resolutionWriters;
        mapping(address writer => uint64) pendingResolutionWriterActivatesAt_;
    }

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = FEEDBACK_CONTROLLER_SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    // ------------------------------------------------------------------------------------------
    // Constants — bounds & defaults
    // ------------------------------------------------------------------------------------------

    uint32 internal constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 internal constant MAX_TIMELOCK_DELAY = 30 days;

    int256 internal constant ONE_E18_INT = 1e18;
    int256 internal constant BPS_DENOM_INT = 10_000;

    /// @dev Spec §3 line 132. Default 1500 bps (15%); bounds [100, 5000] (1%-50%).
    uint16 internal constant DEFAULT_IMPULSE_CAP_BPS = 1_500;
    uint16 internal constant MIN_IMPULSE_CAP_BPS = 100;
    uint16 internal constant MAX_IMPULSE_CAP_BPS = 5_000;

    /// @dev Spec §5 default late-move parameters. With denominator = 3600s and slope = 1, an
    ///      impulse fully decays linearly over one hour (before the maxDiscount clamp).
    uint64 internal constant DEFAULT_LATE_MOVE_DENOMINATOR = 3600; // 1 hour
    uint64 internal constant DEFAULT_LATE_MOVE_SLOPE = 1;
    uint16 internal constant DEFAULT_MAX_DISCOUNT_BPS = 5_000; // 50%

    uint64 internal constant MIN_LATE_MOVE_DENOMINATOR = 60; // 1 minute
    uint64 internal constant MAX_LATE_MOVE_DENOMINATOR = 86_400; // 1 day
    uint64 internal constant MIN_LATE_MOVE_SLOPE = 1;
    uint64 internal constant MAX_LATE_MOVE_SLOPE = 100;
    uint16 internal constant MAX_MAX_DISCOUNT_BPS = 10_000; // 100%

    /// @dev Spec §2 line 81-89 midpoint defaults. Governance can re-tune any class.
    int256 internal constant DEFAULT_COEFF_BREAKUP_DIVORCE = -8e16; // -0.08
    int256 internal constant DEFAULT_COEFF_ARREST = -2e17; // -0.20
    int256 internal constant DEFAULT_COEFF_DEATH = -1e18; // -1.0 (subject is force-settled)
    int256 internal constant DEFAULT_COEFF_ALBUM_RELEASE = 5e16; // +0.05
    int256 internal constant DEFAULT_COEFF_TOUR_ANNOUNCEMENT = 4e16; // +0.04
    int256 internal constant DEFAULT_COEFF_AWARD_WIN = 1e17; // +0.10
    int256 internal constant DEFAULT_COEFF_SCANDAL = -15e16; // -0.15
    int256 internal constant DEFAULT_COEFF_BRAND_DEAL = 6e16; // +0.06
    int256 internal constant DEFAULT_COEFF_LEGAL_FILING = -7e16; // -0.07

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ------------------------------------------------------------------------------------------
    // Initializer
    // ------------------------------------------------------------------------------------------

    /// @notice Initialize the controller. One-time, called via the proxy.
    /// @param  governance_     Multi-sig that owns timelocked config changes.
    /// @param  perpEngine_     PerpEngine. Receives `applyImpulse` calls. Must be configured to
    ///                         treat this controller as its `feedbackController` writer.
    /// @param  oracleRouter_   OracleRouter (carried so this contract can be a future caller —
    ///                         the v1 path does not read it, but the dependency is wired to keep
    ///                         the deployment graph identical to FundingEngine).
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
        s.impulseCapBps_ = DEFAULT_IMPULSE_CAP_BPS;
        s.lateMoveDenominator_ = DEFAULT_LATE_MOVE_DENOMINATOR;
        s.lateMoveSlope_ = DEFAULT_LATE_MOVE_SLOPE;
        s.maxDiscountBps_ = DEFAULT_MAX_DISCOUNT_BPS;

        // Seed spec §2 default coefficients. Governance can re-tune any class.
        s.coefficients_e18[EventClass.BREAKUP_DIVORCE] = DEFAULT_COEFF_BREAKUP_DIVORCE;
        s.coefficients_e18[EventClass.ARREST] = DEFAULT_COEFF_ARREST;
        s.coefficients_e18[EventClass.DEATH] = DEFAULT_COEFF_DEATH;
        s.coefficients_e18[EventClass.ALBUM_RELEASE] = DEFAULT_COEFF_ALBUM_RELEASE;
        s.coefficients_e18[EventClass.TOUR_ANNOUNCEMENT] = DEFAULT_COEFF_TOUR_ANNOUNCEMENT;
        s.coefficients_e18[EventClass.AWARD_WIN] = DEFAULT_COEFF_AWARD_WIN;
        s.coefficients_e18[EventClass.SCANDAL] = DEFAULT_COEFF_SCANDAL;
        s.coefficients_e18[EventClass.BRAND_DEAL] = DEFAULT_COEFF_BRAND_DEAL;
        s.coefficients_e18[EventClass.LEGAL_FILING] = DEFAULT_COEFF_LEGAL_FILING;

        emit Initialized(governance_, perpEngine_, oracleRouter_);
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != _s().governance) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyResolutionWriter() {
        if (!_s().resolutionWriters[msg.sender]) revert OnlyResolutionWriter(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // Hot path — applyResolution
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IFeedbackController
    /// @dev Algorithm:
    ///       1. Validate `eventClass != UNSET` and `outcomeScore ∈ [-1e18, 1e18]`.
    ///       2. Pre-check tradeability via the registry. PerpEngine.applyImpulse will redo this
    ///          check inside the protected hop; doing it here gives callers a clean controller-
    ///          surfaced error before they pay for the cross-call.
    ///       3. Raw impulse: `(coeff_e18 × score_e18 × 10000) / 1e36`. Both factors are bounded
    ///          to ±1e18 so the intermediate product fits comfortably in int256.
    ///       4. Cap at ±impulseCapBps.
    ///       5. Late-move discount (spec §5 lines 285-289).
    ///       6. Push to PerpEngine.
    function applyResolution(ResolutionInput calldata input) external nonReentrant onlyResolutionWriter {
        if (input.eventClass == EventClass.UNSET) revert InvalidEventClass();
        int256 score = input.outcomeScore_e18;
        if (score < -ONE_E18_INT || score > ONE_E18_INT) revert InvalidOutcomeScore(score);

        Layout storage s = _s();

        // Spec §3 line 173: no event-impulse application during pauses. `requireTradeable`
        // covers UNREGISTERED / paused / delisting / delisted / death-pending / policy-flagged.
        ISubjectRegistry(IPerpEngine(s.perpEngine).subjectRegistry()).requireTradeable(input.subjectId);

        int256 coeff = s.coefficients_e18[input.eventClass];
        // Raw impulse in bps: `coeff_e18 × score_e18` is in 1e36, divide by 1e18 once to get
        // `e18 × bps_factor`, then by 1e18 again to get plain bps. Combining: `× 10000 / 1e36`.
        int256 rawImpulseBps = (coeff * score * BPS_DENOM_INT) / (ONE_E18_INT * ONE_E18_INT);

        int256 capBpsSigned = int256(uint256(s.impulseCapBps_));
        int256 cappedImpulseBps = rawImpulseBps;
        if (cappedImpulseBps > capBpsSigned) cappedImpulseBps = capBpsSigned;
        else if (cappedImpulseBps < -capBpsSigned) cappedImpulseBps = -capBpsSigned;

        // Late-move discount: how stale is the resolution vs the event start.
        uint64 lateBy = block.timestamp > uint256(input.eventTimestamp)
            ? uint64(block.timestamp - uint256(input.eventTimestamp))
            : 0;
        int256 finalImpulseBps = _applyLateMoveDiscount(
            cappedImpulseBps, lateBy, s.lateMoveDenominator_, s.lateMoveSlope_, s.maxDiscountBps_
        );

        IPerpEngine(s.perpEngine).applyImpulse(input.subjectId, finalImpulseBps);

        emit ResolutionApplied(
            input.subjectId,
            input.eventClass,
            score,
            input.eventTimestamp,
            lateBy,
            rawImpulseBps,
            cappedImpulseBps,
            finalImpulseBps,
            msg.sender
        );
    }

    /// @dev Late-move discount math (spec §5 lines 285-289):
    ///        discountBps = min((lateBy × slope × 10_000) / denominator, maxDiscountBps)
    ///        finalImpulse = impulse × (10_000 - discountBps) / 10_000
    ///      With the default parameters (denom = 3600, slope = 1, maxDiscount = 5000), a fresh
    ///      resolution (`lateBy = 0`) sees no discount; at `lateBy = denominator` (= 1h) the raw
    ///      ratio hits 100%, clamped to `maxDiscountBps`, so the floor is `impulse × 50%`.
    function _applyLateMoveDiscount(
        int256 impulseBps,
        uint64 lateBy,
        uint64 denominator,
        uint64 slope,
        uint16 maxDiscount
    )
        internal
        pure
        returns (int256)
    {
        if (lateBy == 0) return impulseBps;
        uint256 discountBps =
            (uint256(lateBy) * uint256(slope) * uint256(uint256(BPS_DENOM_INT))) / uint256(denominator);
        if (discountBps > uint256(maxDiscount)) discountBps = uint256(maxDiscount);
        int256 remainingBps = BPS_DENOM_INT - int256(discountBps);
        return (impulseBps * remainingBps) / BPS_DENOM_INT;
    }

    // ------------------------------------------------------------------------------------------
    // Governance: parameter setters (no timelock)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IFeedbackController
    function setCoefficient(EventClass eventClass, int256 coefficient_e18) external onlyGovernance {
        if (eventClass == EventClass.UNSET) revert InvalidEventClass();
        if (coefficient_e18 < -ONE_E18_INT || coefficient_e18 > ONE_E18_INT) {
            revert CoefficientOutOfRange(coefficient_e18);
        }
        Layout storage s = _s();
        int256 old = s.coefficients_e18[eventClass];
        s.coefficients_e18[eventClass] = coefficient_e18;
        emit CoefficientSet(eventClass, old, coefficient_e18);
    }

    /// @inheritdoc IFeedbackController
    function setImpulseCapBps(uint16 capBps) external onlyGovernance {
        if (capBps < MIN_IMPULSE_CAP_BPS || capBps > MAX_IMPULSE_CAP_BPS) revert ImpulseCapOutOfRange(capBps);
        Layout storage s = _s();
        uint16 old = s.impulseCapBps_;
        s.impulseCapBps_ = capBps;
        emit ImpulseCapBpsSet(old, capBps);
    }

    /// @inheritdoc IFeedbackController
    function setLateMoveParams(uint64 denominator, uint64 slope, uint16 maxDiscount) external onlyGovernance {
        if (denominator < MIN_LATE_MOVE_DENOMINATOR || denominator > MAX_LATE_MOVE_DENOMINATOR) {
            revert LateMoveParamsOutOfRange();
        }
        if (slope < MIN_LATE_MOVE_SLOPE || slope > MAX_LATE_MOVE_SLOPE) revert LateMoveParamsOutOfRange();
        if (maxDiscount > MAX_MAX_DISCOUNT_BPS) revert LateMoveParamsOutOfRange();
        Layout storage s = _s();
        s.lateMoveDenominator_ = denominator;
        s.lateMoveSlope_ = slope;
        s.maxDiscountBps_ = maxDiscount;
        emit LateMoveParamsSet(denominator, slope, maxDiscount);
    }

    /// @inheritdoc IFeedbackController
    function setOracleRouter(address newRouter) external onlyGovernance {
        if (newRouter == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        address old = s.oracleRouter;
        s.oracleRouter = newRouter;
        emit OracleRouterSet(old, newRouter);
    }

    /// @inheritdoc IFeedbackController
    function setPerpEngine(address newEngine) external onlyGovernance {
        if (newEngine == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        address old = s.perpEngine;
        s.perpEngine = newEngine;
        emit PerpEngineSet(old, newEngine);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: resolution-writer rotation (timelocked add, immediate remove)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IFeedbackController
    function proposeAddResolutionWriter(address writer) external onlyGovernance {
        if (writer == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        if (s.resolutionWriters[writer]) revert InvalidConfig();
        if (s.pendingResolutionWriterActivatesAt_[writer] != 0) revert PendingResolutionWriterExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingResolutionWriterActivatesAt_[writer] = activatesAt;
        emit ResolutionWriterProposed(writer, activatesAt);
    }

    /// @inheritdoc IFeedbackController
    /// @dev Permissionless once the timelock has elapsed — anyone can pay the gas to flip a
    ///      fully-timelocked, governance-approved writer into the active set.
    function activateAddResolutionWriter(address writer) external {
        Layout storage s = _s();
        uint64 readyAt = s.pendingResolutionWriterActivatesAt_[writer];
        if (readyAt == 0) revert NoPendingResolutionWriter();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        delete s.pendingResolutionWriterActivatesAt_[writer];
        s.resolutionWriters[writer] = true;
        emit ResolutionWriterActivated(writer);
    }

    /// @inheritdoc IFeedbackController
    function cancelAddResolutionWriter(address writer) external onlyGovernance {
        Layout storage s = _s();
        if (s.pendingResolutionWriterActivatesAt_[writer] == 0) revert NoPendingResolutionWriter();
        delete s.pendingResolutionWriterActivatesAt_[writer];
        emit ResolutionWriterCancelled(writer);
    }

    /// @inheritdoc IFeedbackController
    function removeResolutionWriter(address writer) external onlyGovernance {
        Layout storage s = _s();
        if (!s.resolutionWriters[writer]) revert ResolutionWriterNotSet(writer);
        delete s.resolutionWriters[writer];
        emit ResolutionWriterRemoved(writer);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IFeedbackController
    function proposeGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        if (s.pendingGovernanceActivatesAt != 0) revert PendingGovernanceTransferExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingGovernance = newGovernance;
        s.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGovernance, activatesAt);
    }

    /// @inheritdoc IFeedbackController
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

    /// @inheritdoc IFeedbackController
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

    /// @inheritdoc IFeedbackController
    function coefficientOf(EventClass eventClass) external view returns (int256) {
        return _s().coefficients_e18[eventClass];
    }

    /// @inheritdoc IFeedbackController
    function impulseCapBps() external view returns (uint16) {
        return _s().impulseCapBps_;
    }

    /// @inheritdoc IFeedbackController
    function lateMoveDenominator() external view returns (uint64) {
        return _s().lateMoveDenominator_;
    }

    /// @inheritdoc IFeedbackController
    function lateMoveSlope() external view returns (uint64) {
        return _s().lateMoveSlope_;
    }

    /// @inheritdoc IFeedbackController
    function maxDiscountBps() external view returns (uint16) {
        return _s().maxDiscountBps_;
    }

    /// @inheritdoc IFeedbackController
    function isResolutionWriter(address writer) external view returns (bool) {
        return _s().resolutionWriters[writer];
    }

    /// @inheritdoc IFeedbackController
    function pendingResolutionWriterActivatesAt(address writer) external view returns (uint64) {
        return _s().pendingResolutionWriterActivatesAt_[writer];
    }

    /// @inheritdoc IFeedbackController
    function governance() external view returns (address) {
        return _s().governance;
    }

    /// @inheritdoc IFeedbackController
    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        Layout storage s = _s();
        return (s.pendingGovernance, s.pendingGovernanceActivatesAt);
    }

    /// @inheritdoc IFeedbackController
    function perpEngine() external view returns (address) {
        return _s().perpEngine;
    }

    /// @inheritdoc IFeedbackController
    function oracleRouter() external view returns (address) {
        return _s().oracleRouter;
    }

    /// @inheritdoc IFeedbackController
    function timelockDelay() external view returns (uint32) {
        return _s().timelockDelay;
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
