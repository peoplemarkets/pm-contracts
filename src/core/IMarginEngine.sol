// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IPerpEngine} from "./IPerpEngine.sol";

/// @title  IMarginEngine — interface for the extracted margin / cap engine.
/// @notice MarginEngine owns the cap-and-margin policy: it enforces per-subject side OI caps,
///         per-category net OI caps, per-trader subject + combined exposure caps, the initial-
///         margin check, and the leverage cap. PerpEngine delegates BOTH the check paths
///         (`enforceOpenCaps`, `checkInitialMargin`, `checkInitialMarginResidual`) AND the
///         bookkeeping mutations (`recordOpenDelta`, `recordCloseDelta`) to this contract. The
///         margin policy state lives entirely inside MarginEngine's storage (PerpEngine carries
///         no MarginStorage of its own after the extraction).
///
/// @dev    Roles:
///           - `governance` — slow lever, timelocked. Margin parameters, KYC tier caps, category
///             cap, governance transfer.
///           - `perpEngine` — sole authorised caller of the bookkeeping hooks. Wiring is rotated
///             through a non-timelocked governance call (`setPerpEngine`) since this is a pointer,
///             not a state grant.
///
/// @dev    Storage convention: MarginEngine owns two namespaces inside its own proxy storage. The
///         outer `MarginEngineStorage` namespace at `keccak256("people.markets.marginengine.v1")`
///         carries governance + perp-engine pointer + pending governance transfer. The inner
///         `MarginStorage` library namespace (`keccak256("people.markets.margin.v1")` from
///         `StorageLib.sol`) carries the actual policy state — `exposure`, `tierCombinedCap`,
///         `tierPerSubjectCap`, margin bps fields, OI cap bps, `netCategoryOi`. Library
///         namespaces resolve to a slot inside the calling proxy's storage, so PerpEngine's
///         MarginStorage slot is unused after this extraction — every read and write flows
///         through MarginEngine.
interface IMarginEngine {
    // ------------------------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------------------------

    /// @dev Long / short — mirrors `IPerpEngine.Side` but kept local so MarginEngine does not
    ///      need an import dependency on PerpEngine's full interface for callers.
    enum Side {
        LONG,
        SHORT
    }

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error Unauthorized(address caller);
    error InvalidConfig();
    error InvalidKycTier(uint8 tier);
    error InitialMarginBpsOutOfRange(uint16 bps);
    error MaintenanceMarginBpsOutOfRange(uint16 bps);
    error LiquidationBufferBpsOutOfRange(uint16 bps);
    error MaxLeverageBpsOutOfRange(uint16 bps);
    error PerSubjectSideOiCapBpsOutOfRange(uint16 bps);
    error CategoryNetOiCapBpsOutOfRange(uint16 bps);
    error MmGteIm(uint16 imBps, uint16 mmBps);

    // Open-path caps (revert in `enforceOpenCaps`).
    error PerSubjectOiCapExceeded(bytes32 subjectId, Side side, uint256 newSideOi, uint256 cap);
    error CategoryOiCapExceeded(bytes32 categoryId, uint256 proposedAbs, uint256 cap);
    error PerSubjectTraderCapExceeded(address trader, bytes32 subjectId, uint256 proposedNotional, uint256 cap);
    error CombinedExposureCapExceeded(address trader, uint256 newCombined, uint256 cap);

    // Margin path (revert in `checkInitialMargin`).
    error LeverageTooHigh(uint256 leverageBps, uint256 maxBps);
    error InitialMarginShort(uint256 required, uint256 provided);

    // Governance transfer.
    error PendingGovernanceTransferExists();
    error NoPendingGovernanceTransfer();
    error TimelockNotElapsed(uint64 readyAt);

    // Hook errors (called by PerpEngine on the open/close hot path).
    error OnlyPerpEngine(address caller);

    /// @dev Thrown by `seedNetCategoryOi` on the second invocation. The one-shot flag prevents
    ///      the accumulator from being rebased after live use.
    error AlreadySeeded();

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event Initialized(address indexed governance, address indexed perpEngine, uint32 timelockDelay);
    event KycCapsSet(uint8 indexed tier, uint256 perSubjectCap, uint256 combinedCap);
    event MarginParamsSet(uint16 imBps, uint16 mmBps, uint16 bufBps, uint16 maxLevBps);
    event PerSubjectSideOiCapBpsSet(uint16 oldBps, uint16 newBps);
    event CategoryNetOiCapBpsSet(uint16 oldBps, uint16 newBps);
    event PerpEngineSet(address indexed oldEngine, address indexed newEngine);
    event GovernanceTransferProposed(address indexed newGovernance, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceTransferCancelled(address indexed pendingGovernance);
    /// @notice Emitted per category by the one-shot `seedNetCategoryOi` rotation helper.
    event NetCategoryOiSeeded(bytes32 indexed categoryId, int256 value);
    /// @notice Emitted at the end of a successful `seedNetCategoryOi` call. The `seeded` flag is
    ///         set; further calls to the helper revert `AlreadySeeded`.
    event SeedingFinalized();

    // ------------------------------------------------------------------------------------------
    // Check functions (called by PerpEngine open/close paths)
    // ------------------------------------------------------------------------------------------

    /// @notice Validate the per-subject side OI cap, per-category net OI cap, per-trader subject
    ///         cap, and combined exposure cap. Reverts on any violation. The caller (PerpEngine)
    ///         supplies `cappedVaultTvl` so MarginEngine does not need a back-pointer to the LP
    ///         vault for the cap denominator (keeps the call direction one-way:
    ///         PerpEngine → MarginEngine).
    /// @param  trader        Position owner; combined-exposure cap is per (trader, KYC tier).
    /// @param  subjectId     Subject the position is on.
    /// @param  categoryId    Category of the subject (used for the per-category net OI cap).
    /// @param  side          0 = LONG, 1 = SHORT.
    /// @param  sizeNotional  Opening notional being added (1e18 USDC-scale).
    /// @param  kycTier       Trader's KYC tier (1, 2, or 3). 0 should be filtered upstream.
    /// @param  longOI        Current long OI on `subjectId` (pre-trade).
    /// @param  shortOI       Current short OI on `subjectId` (pre-trade).
    /// @param  cappedVaultTvl Cap denominator (= `min(perpS.cappedTvl, vault.totalAssets())`).
    function enforceOpenCaps(
        address trader,
        bytes32 subjectId,
        bytes32 categoryId,
        Side side,
        uint256 sizeNotional,
        uint8 kycTier,
        uint256 longOI,
        uint256 shortOI,
        uint256 cappedVaultTvl
    )
        external
        view;

    /// @notice Initial-margin + leverage cap check. Reverts on either violation.
    /// @param  notional    Position notional (1e18 USDC-scale).
    /// @param  collateral  Locked collateral (1e18 USDC-scale). Must be non-zero — the caller is
    ///                     expected to filter zero-collateral inputs before invoking this.
    function checkInitialMargin(uint256 notional, uint256 collateral) external view;

    /// @notice Pure maintenance-margin probe. Returns `true` when the position's margin ratio is
    ///         strictly below `maintenanceMarginBps`. Used by views and (eventually) liquidation.
    /// @dev    All inputs are 1e18 fixed-point; `size` is signed.
    function isUnderMaintenance(
        int256 size,
        uint256 collateral,
        uint256 markPrice,
        uint256 entryPrice
    )
        external
        view
        returns (bool);

    /// @notice Re-check initial margin against the residual after a `removeCollateral` call.
    ///         Same semantic as the open-path IM check, but uses `currentNotional` (size × mark)
    ///         and reverts with `InitialMarginShort(required, providedEquity)` so the caller's
    ///         error trail mirrors the legacy behaviour.
    /// @dev    Pure-style view: reads margin params from MarginStorage; computes the
    ///         residual equity = collateral + unrealizedPnl. Negative equity reverts as the
    ///         dedicated `MaintenanceMarginShort` selector on IPerpEngine for source compatibility
    ///         — kept upstream in PerpEngine.
    function checkInitialMarginResidual(
        uint256 newCollateral,
        uint256 currentNotional,
        int256 unrealizedPnl
    )
        external
        view;

    // ------------------------------------------------------------------------------------------
    // Hook functions (called by PerpEngine open/close paths)
    // ------------------------------------------------------------------------------------------

    /// @notice Apply the open-position bookkeeping mutations: bump the per-trader perp notional,
    ///         set the trader's KYC tier, and shift the per-category net OI accumulator. Must be
    ///         called inside `PerpEngine.openPosition` immediately after the position is written.
    /// @dev    Caller MUST be the configured `perpEngine` — reverts `OnlyPerpEngine` otherwise.
    function recordOpenDelta(
        address trader,
        bytes32 categoryId,
        Side side,
        uint256 sizeNotional,
        uint8 kycTier
    )
        external;

    /// @notice Apply the close-position bookkeeping mutations: decrement the per-trader perp
    ///         notional and unwind the per-category net OI contribution. Must be called inside
    ///         the close paths (full close, partial close, force-settlement claim).
    /// @dev    Caller MUST be the configured `perpEngine`.
    function recordCloseDelta(address trader, bytes32 categoryId, uint256 sizeNotional, bool isLong) external;

    // ------------------------------------------------------------------------------------------
    // Governance setters (immediate, no timelock — matches the existing PerpEngine pattern)
    // ------------------------------------------------------------------------------------------

    function setKycCaps(uint8 tier, uint256 perSubjectCap, uint256 combinedCap) external;
    function setMarginParams(uint16 imBps, uint16 mmBps, uint16 bufBps, uint16 maxLevBps) external;
    function setPerSubjectSideOiCapBps(uint16 bps) external;
    function setCategoryNetOiCapBps(uint16 bps) external;

    // ------------------------------------------------------------------------------------------
    // Governance transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    function proposeGovernanceTransfer(address newGovernance) external;
    function activateGovernanceTransfer() external;
    function cancelGovernanceTransfer() external;

    // ------------------------------------------------------------------------------------------
    // Wiring (governance, no timelock — back-pointer rotation)
    // ------------------------------------------------------------------------------------------

    function setPerpEngine(address newPerpEngine) external;

    // ------------------------------------------------------------------------------------------
    // Wave 7 audit Fix #7 — one-shot rotation-seed helper
    // ------------------------------------------------------------------------------------------

    /// @notice Seed the per-category net OI accumulator. ONE-SHOT — reverts `AlreadySeeded` on
    ///         the second call.
    /// @dev    Used during the rotation flow when a fresh MarginEngine proxy is deployed and the
    ///         live position set already held in PerpEngine needs to be mirrored into the new
    ///         accumulator before the engine starts gating opens/closes. The `seeded` flag is
    ///         intentionally one-shot to prevent rebasing the accumulator after live use.
    function seedNetCategoryOi(bytes32[] calldata categoryIds, int256[] calldata values) external;

    /// @notice True after `seedNetCategoryOi` has run.
    function seeded() external view returns (bool);

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function initialMarginBps() external view returns (uint16);
    function maintenanceMarginBps() external view returns (uint16);
    function liquidationBufferBps() external view returns (uint16);
    function maxLeverageBps() external view returns (uint16);
    function perSubjectSideOiCapBps() external view returns (uint16);
    function categoryNetOiCapBps() external view returns (uint16);
    function crossMarginMultiplier() external view returns (uint256);
    function netCategoryOiOf(bytes32 categoryId) external view returns (int256);
    function tierPerSubjectCap(uint8 tier) external view returns (uint256);
    function tierCombinedCap(uint8 tier) external view returns (uint256);

    /// @notice Composite (perSubjectCap, combinedCap) tuple for `tier`. Convenience for
    ///         scripts/UIs that want both values in a single call.
    function tierCaps(uint8 tier) external view returns (uint256 perSubjectCap, uint256 combinedCap);

    /// @notice Aggregate margin parameters: IM, MM, liq-buffer, max-leverage, per-subject OI cap.
    function marginParams()
        external
        view
        returns (uint16 imBps, uint16 mmBps, uint16 bufBps, uint16 maxLevBps, uint16 perSubjectSideOiCapBps_);

    function exposureOf(address trader)
        external
        view
        returns (uint256 totalPerpNotional, uint256 totalEventExposure, uint8 tier);

    function governance() external view returns (address);
    function pendingGovernance() external view returns (address account, uint64 activatesAt);
    function timelockDelay() external view returns (uint32);
    function perpEngine() external view returns (address);

    /// @notice `isMarginOk` probe by positionId — reads the position from PerpEngine and checks
    ///         maintenance margin. Returns `true` for empty positions (size == 0).
    function isMarginOk(bytes32 positionId) external view returns (bool);

    /// @notice Pass-through to the local `IPerpEngine.Position` shape so callers that hold only
    ///         the MarginEngine address can sanity-check position data without importing the
    ///         PerpEngine interface. Returns the position from the configured `perpEngine`.
    function positionFor(bytes32 positionId) external view returns (IPerpEngine.Position memory);
}
