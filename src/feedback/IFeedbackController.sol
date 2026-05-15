// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title  IFeedbackController — event-resolution → mark-impulse driver.
/// @notice The FeedbackController is the v1 application of off-chain event resolutions to perp
///         mark prices. An authorized `resolutionWriter` (the off-chain resolver feed) submits a
///         `ResolutionInput`; the controller translates `(coefficient[eventClass] × outcomeScore)`
///         into a basis-point mark impulse, discounts it for lateness (spec §5), caps it at
///         ±impulseCapBps of mark (spec §3 line 132, default 15%), and calls
///         `PerpEngine.applyImpulse(subjectId, finalImpulseBps)`.
///
/// @dev    Roles:
///           - `governance` — slow lever, timelocked. Resolution-writer adds and governance
///             transfer use the standard propose/activate/cancel flow.
///           - `governance` (no timelock) — coefficient / cap / late-move / dependency setters.
///             Matches the FundingEngine pattern: parameter changes have lower blast radius
///             than role grants, and the multi-sig is the gate.
///           - `resolutionWriter` — push-only. Off-chain resolver. Removes are immediate.
interface IFeedbackController {
    // ------------------------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------------------------

    /// @notice Event classes per spec §2 line 81-89. Coefficients indexed by this enum.
    /// @dev    `UNSET` is the zero value and is never a valid input — it lets us detect the
    ///         "field never written" state and reject calls that did not populate `eventClass`.
    enum EventClass {
        UNSET,
        BREAKUP_DIVORCE,
        ARREST,
        DEATH,
        ALBUM_RELEASE,
        TOUR_ANNOUNCEMENT,
        AWARD_WIN,
        SCANDAL,
        BRAND_DEAL,
        LEGAL_FILING
    }

    /// @notice Resolution input passed from the off-chain resolver to `applyResolution`.
    /// @param  subjectId        Subject the resolution targets.
    /// @param  eventClass       Class of the event (drives coefficient lookup).
    /// @param  outcomeScore_e18 Signed score in `[-1e18, 1e18]`. `+1e18` = max-positive outcome,
    ///                          `-1e18` = max-negative.
    /// @param  eventTimestamp   When the event "started" — used to compute the late-move discount.
    struct ResolutionInput {
        bytes32 subjectId;
        EventClass eventClass;
        int256 outcomeScore_e18;
        uint64 eventTimestamp;
    }

    // ------------------------------------------------------------------------------------------
    // External — resolution writer
    // ------------------------------------------------------------------------------------------

    /// @notice Apply an event resolution to the subject's mark. Caller must be a
    ///         `resolutionWriter`. Reverts if the subject is not tradeable (paused / delisting /
    ///         delisted / death-pending / policy-flagged) — spec §3 line 173 ("no event-impulse
    ///         application during pauses").
    function applyResolution(ResolutionInput calldata input) external;

    // ------------------------------------------------------------------------------------------
    // External — governance (no timelock)
    // ------------------------------------------------------------------------------------------

    /// @notice Set the coefficient (signed, 1e18 scale) for `eventClass`. Range
    ///         `[-1e18, 1e18]`. `UNSET` cannot be configured.
    function setCoefficient(EventClass eventClass, int256 coefficient_e18) external;

    /// @notice Set the per-resolution impulse cap (basis points of mark). Range `[100, 5000]`.
    function setImpulseCapBps(uint16 capBps) external;

    /// @notice Set the late-move discount parameters. Ranges: denominator `[60, 86400]`,
    ///         slope `[1, 100]`, maxDiscountBps `[0, 10000]`.
    function setLateMoveParams(uint64 denominator, uint64 slope, uint16 maxDiscountBps) external;

    // ------------------------------------------------------------------------------------------
    // External — governance (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @notice Schedule a PerpEngine repoint. Activates after `timelockDelay`. Wave 7 audit
    ///         Fix #4: cross-cutting pointer rotations follow the standard
    ///         propose/activate/cancel pattern (mirrors `proposeSetFundingEngine` on PerpEngine
    ///         and `proposeSetPerpEngine` on LPVault). The PerpEngine is the consumer of
    ///         `applyImpulse` calls; an instant swap could divert impulse-driven mark moves to
    ///         a malicious engine before LPs see the change in the indexer.
    function proposeSetPerpEngine(address newEngine) external;
    function activateSetPerpEngine() external;
    function cancelSetPerpEngine() external;

    /// @notice Schedule an OracleRouter repoint. Activates after `timelockDelay`. The router is
    ///         the dependency carried for forward-compatibility (v1 does not read it on the hot
    ///         path); rotation still follows the timelocked pattern so the deployment graph is
    ///         self-consistent.
    function proposeSetOracleRouter(address newRouter) external;
    function activateSetOracleRouter() external;
    function cancelSetOracleRouter() external;

    function proposeAddResolutionWriter(address writer) external;
    function activateAddResolutionWriter(address writer) external;
    function cancelAddResolutionWriter(address writer) external;

    /// @notice Remove a resolution writer. Immediate; no timelock — a compromised writer can
    ///         be cut off without delay.
    function removeResolutionWriter(address writer) external;

    function proposeGovernanceTransfer(address newGovernance) external;
    function activateGovernanceTransfer() external;
    function cancelGovernanceTransfer() external;

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function coefficientOf(EventClass eventClass) external view returns (int256);
    function impulseCapBps() external view returns (uint16);
    function lateMoveDenominator() external view returns (uint64);
    function lateMoveSlope() external view returns (uint64);
    function maxDiscountBps() external view returns (uint16);
    function isResolutionWriter(address writer) external view returns (bool);
    function pendingResolutionWriterActivatesAt(address writer) external view returns (uint64);
    function governance() external view returns (address);
    function pendingGovernance() external view returns (address account, uint64 activatesAt);
    function perpEngine() external view returns (address);
    function oracleRouter() external view returns (address);
    function timelockDelay() external view returns (uint32);
    /// @notice Pending PerpEngine rotation (zero address + zero timestamp when none).
    function pendingPerpEngine() external view returns (address account, uint64 activatesAt);
    /// @notice Pending OracleRouter rotation (zero address + zero timestamp when none).
    function pendingOracleRouter() external view returns (address account, uint64 activatesAt);

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event Initialized(address governance, address perpEngine, address oracleRouter);
    event ResolutionApplied(
        bytes32 indexed subjectId,
        EventClass indexed eventClass,
        int256 outcomeScore_e18,
        uint64 eventTimestamp,
        uint64 lateBy,
        int256 rawImpulseBps,
        int256 cappedImpulseBps,
        int256 finalImpulseBps,
        address indexed writer
    );
    event CoefficientSet(EventClass indexed eventClass, int256 oldCoeff, int256 newCoeff);
    event ImpulseCapBpsSet(uint16 oldBps, uint16 newBps);
    event LateMoveParamsSet(uint64 denominator, uint64 slope, uint16 maxDiscountBps);
    /// @notice Emitted by the timelocked PerpEngine pointer-rotation dance.
    event PerpEngineProposed(address indexed newEngine, uint64 activatesAt);
    event PerpEngineActivated(address indexed oldEngine, address indexed newEngine);
    event PerpEngineCancelled(address indexed pendingEngine);
    /// @notice Emitted by the timelocked OracleRouter pointer-rotation dance.
    event OracleRouterProposed(address indexed newRouter, uint64 activatesAt);
    event OracleRouterActivated(address indexed oldRouter, address indexed newRouter);
    event OracleRouterCancelled(address indexed pendingRouter);
    event ResolutionWriterProposed(address indexed writer, uint64 activatesAt);
    event ResolutionWriterActivated(address indexed writer);
    event ResolutionWriterCancelled(address indexed writer);
    event ResolutionWriterRemoved(address indexed writer);
    event GovernanceTransferProposed(address indexed newGov, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGov, address indexed newGov);
    event GovernanceTransferCancelled(address indexed pendingGov);

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error Unauthorized(address caller);
    error OnlyResolutionWriter(address caller);
    error InvalidConfig();
    error InvalidEventClass();
    error InvalidOutcomeScore(int256 score);
    error ImpulseCapOutOfRange(uint16 capBps);
    error CoefficientOutOfRange(int256 coeff);
    error LateMoveParamsOutOfRange();
    error SubjectNotTradeable(bytes32 subjectId);
    error PendingGovernanceTransferExists();
    error NoPendingGovernanceTransfer();
    error TimelockNotElapsed(uint64 readyAt);
    error PendingResolutionWriterExists();
    error NoPendingResolutionWriter();
    error ResolutionWriterNotSet(address writer);
    /// @dev Thrown by `proposeSetPerpEngine` when a rotation is already in flight.
    error PendingPerpEngineExists();
    /// @dev Thrown by `activateSetPerpEngine` / `cancelSetPerpEngine` when there is no pending rotation.
    error NoPendingPerpEngine();
    /// @dev Thrown by `proposeSetOracleRouter` when a rotation is already in flight.
    error PendingOracleRouterExists();
    /// @dev Thrown by `activateSetOracleRouter` / `cancelSetOracleRouter` when there is no pending rotation.
    error NoPendingOracleRouter();
}
