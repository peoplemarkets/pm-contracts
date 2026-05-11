// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {PositionMath} from "../libraries/PositionMath.sol";
import {MarginStorage} from "../libraries/StorageLib.sol";

import {IMarginEngine} from "./IMarginEngine.sol";
import {IPerpEngine} from "./IPerpEngine.sol";

/// @title  MarginEngine — extracted margin / cap policy for People Markets perps.
/// @notice Owns the cap-and-margin checks (open-time per-subject side OI cap, per-category net
///         OI cap, per-trader subject cap, combined exposure cap; the initial-margin + leverage
///         check; the maintenance-margin probe), plus all margin parameter setters. PerpEngine
///         delegates the open/close-path checks AND the per-trader-exposure + per-category-OI
///         bookkeeping mutations to this contract via the `enforceOpenCaps`, `checkInitialMargin`,
///         `checkInitialMarginResidual`, `recordOpenDelta`, and `recordCloseDelta` entry points.
///
/// @dev    Storage convention. MarginEngine owns its own outer namespace at
///         `keccak256("people.markets.marginengine.v1")` — see `Layout` below. That outer
///         namespace holds governance + perp-engine pointer + timelock + pending governance.
///         The margin policy state itself lives in the `MarginStorage` library namespace
///         (`keccak256("people.markets.margin.v1")`) which — because library namespaces resolve
///         to a slot inside the *calling* proxy's storage — lives inside MarginEngine's storage,
///         not PerpEngine's. PerpEngine no longer carries any MarginStorage state of its own;
///         every read/write goes through the hooks on this contract.
///
/// @dev    Migration plan (governance off-chain script):
///           1. Deploy MarginEngine via UUPSProxy + `initialize(governance, perpEngine, delay)`
///              — seeds the spec §3 defaults into MarginStorage.
///           2. `PerpEngine.proposeSetMarginEngine(addr)` → wait timelock → `activate`.
///           3. From this point forward, governance calls margin setters on MarginEngine; the
///              old PerpEngine versions are removed. PerpEngine.openPosition reverts at the
///              delegation site with `MarginEngineUnset` until step 2 completes.
contract MarginEngine is Initializable, UUPSUpgradeable, IMarginEngine {
    // ------------------------------------------------------------------------------------------
    // Storage namespace
    // ------------------------------------------------------------------------------------------

    /// @dev Local namespace for governance + perp-engine pointer + pending governance. The
    ///      policy state lives in the separate `MarginStorage` library namespace (inside this
    ///      proxy's storage).
    bytes32 internal constant MARGIN_ENGINE_SLOT = keccak256("people.markets.marginengine.v1");

    /// @custom:storage-location erc7201:people.markets.marginengine.v1
    struct Layout {
        // governance + timelock
        address governance;
        uint32 timelockDelay;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        // wiring — back-pointer to PerpEngine (read-only side: position struct, mark, etc.)
        address perpEngine;
    }

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = MARGIN_ENGINE_SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant ONE = 1e18;

    uint32 internal constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 internal constant MAX_TIMELOCK_DELAY = 30 days;

    /// @dev Hard ceilings for governance-tunable params. Block obvious misconfiguration. These
    ///      mirror the constants that previously lived on PerpEngine so behaviour is preserved.
    uint16 internal constant MAX_INITIAL_MARGIN_BPS = 10_000; // 100%
    uint16 internal constant MAX_MAINTENANCE_MARGIN_BPS = 5_000; // 50%
    uint16 internal constant MAX_LIQ_BUFFER_BPS = 2_000; // 20%
    uint16 internal constant MAX_LEVERAGE_BPS = 60_000; // 6× (uint16 packing bound on storage)
    uint16 internal constant MAX_OI_CAP_BPS = 5_000; // 50%

    uint16 internal constant DEFAULT_CATEGORY_NET_OI_CAP_BPS = 2_000; // 20%
    uint16 internal constant MIN_CATEGORY_NET_OI_CAP_BPS = 500; // 5%
    uint16 internal constant MAX_CATEGORY_NET_OI_CAP_BPS = 5_000; // 50%

    /// @dev Default cross-margin multiplier (1e18 scale). Spec §3: starts at 0.25e18 (25%);
    ///      bounds [0.20e18, 0.40e18]. Seeded only if the storage field is still zero on init —
    ///      a re-init via UUPS upgrade would not stomp a governance-rotated value.
    uint256 internal constant DEFAULT_CROSS_MARGIN_MULTIPLIER = 0.25e18;
    uint256 internal constant MIN_CROSS_MARGIN_MULTIPLIER = 0.2e18;
    uint256 internal constant MAX_CROSS_MARGIN_MULTIPLIER = 0.4e18;

    /// @dev Spec §3 default margin parameters. Seeded on init when MarginStorage is fresh.
    uint16 internal constant DEFAULT_INITIAL_MARGIN_BPS = 2_000;
    uint16 internal constant DEFAULT_MAINTENANCE_MARGIN_BPS = 500;
    uint16 internal constant DEFAULT_LIQ_BUFFER_BPS = 250;
    uint16 internal constant DEFAULT_MAX_LEVERAGE_BPS = 50_000;
    uint16 internal constant DEFAULT_PER_SUBJECT_SIDE_OI_CAP_BPS = 500;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ------------------------------------------------------------------------------------------
    // Initializer
    // ------------------------------------------------------------------------------------------

    /// @notice Initialize the engine. One-time, called via the proxy.
    /// @param  governance_      Multi-sig that proposes/activates config changes; timelocked.
    /// @param  perpEngine_      PerpEngine address. Sole authorised caller of the bookkeeping
    ///                          hooks (`recordOpenDelta`, `recordCloseDelta`). Also the source
    ///                          for `isMarginOk(positionId)` / `positionFor` pass-through reads.
    /// @param  timelockDelay_   Seconds. Must lie in [MIN_TIMELOCK_DELAY, MAX_TIMELOCK_DELAY].
    /// @dev    Seeds MarginStorage with the spec §3 defaults. MarginStorage is namespaced inside
    ///         this proxy's storage (per the namespaced-storage convention) — PerpEngine has its
    ///         own MarginStorage slot, which is left untouched. The MarginEngine-side state is
    ///         the canonical one from this point forward; PerpEngine routes all margin/cap reads
    ///         and writes through this contract.
    function initialize(address governance_, address perpEngine_, uint32 timelockDelay_) external initializer {
        if (governance_ == address(0)) revert InvalidConfig();
        if (perpEngine_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();

        Layout storage s = _s();
        s.governance = governance_;
        s.perpEngine = perpEngine_;
        s.timelockDelay = timelockDelay_;

        // Seed MarginStorage with the spec §3 defaults. Idempotent: only fields still at zero get
        // defaults so a UUPS upgrade does not stomp governance-rotated values.
        MarginStorage.Layout storage marginS = MarginStorage.load();
        if (marginS.initialMarginBps == 0) marginS.initialMarginBps = DEFAULT_INITIAL_MARGIN_BPS;
        if (marginS.maintenanceMarginBps == 0) marginS.maintenanceMarginBps = DEFAULT_MAINTENANCE_MARGIN_BPS;
        if (marginS.liquidationBufferBps == 0) marginS.liquidationBufferBps = DEFAULT_LIQ_BUFFER_BPS;
        if (marginS.maxLeverageBps == 0) marginS.maxLeverageBps = DEFAULT_MAX_LEVERAGE_BPS;
        if (marginS.perSubjectSideOiCapBps == 0) marginS.perSubjectSideOiCapBps = DEFAULT_PER_SUBJECT_SIDE_OI_CAP_BPS;
        if (marginS.categoryNetOiCapBps == 0) marginS.categoryNetOiCapBps = DEFAULT_CATEGORY_NET_OI_CAP_BPS;
        if (marginS.crossMarginMultiplier == 0) marginS.crossMarginMultiplier = DEFAULT_CROSS_MARGIN_MULTIPLIER;

        emit Initialized(governance_, perpEngine_, timelockDelay_);
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != _s().governance) revert Unauthorized(msg.sender);
        _;
    }

    /// @dev Gates the bookkeeping hooks. PerpEngine is the sole authorised writer of the
    ///      per-trader exposure and the signed per-category OI accumulator.
    modifier onlyPerpEngine() {
        address pe = _s().perpEngine;
        if (msg.sender != pe || pe == address(0)) revert OnlyPerpEngine(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // Check functions (called by PerpEngine open path)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IMarginEngine
    /// @dev Body lifted verbatim from `PerpEngine._enforceOpenCaps`. The cap denominator (the
    ///      `min(cappedTvl, liveTvl)` quantity) is computed by the caller and passed in as
    ///      `cappedVaultTvl` so this contract avoids a back-pointer dependency on the LP vault.
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
        view
    {
        MarginStorage.Layout storage marginS = MarginStorage.load();

        // Per-subject side OI cap. Denominator is `min(cappedTvl, liveTvl)` (v2-audit Fix #3).
        uint256 sideOiCap = (cappedVaultTvl * marginS.perSubjectSideOiCapBps) / BPS_DENOMINATOR;
        uint256 newSideOi = side == Side.LONG ? longOI + sizeNotional : shortOI + sizeNotional;
        if (newSideOi > sideOiCap) {
            revert PerSubjectOiCapExceeded(subjectId, side, newSideOi, sideOiCap);
        }

        // Per-category net OI cap. The prospective net is `current + signed sizeNotional`; cap
        // the absolute value so a trade that nets a category from +X to −X still cannot exceed
        // the cap in either direction. Same denominator semantic as the per-subject cap.
        int256 currentNet = marginS.netCategoryOi[categoryId];
        int256 prospective = side == Side.LONG ? currentNet + int256(sizeNotional) : currentNet - int256(sizeNotional);
        uint256 prospectiveAbs = prospective >= 0 ? uint256(prospective) : uint256(-prospective);
        uint256 categoryCap = (cappedVaultTvl * marginS.categoryNetOiCapBps) / BPS_DENOMINATOR;
        if (prospectiveAbs > categoryCap) {
            revert CategoryOiCapExceeded(categoryId, prospectiveAbs, categoryCap);
        }

        // Per-trader-per-subject cap. The one-position invariant on the caller means we know the
        // trader has no existing position on this subject, so the cap applies cleanly to
        // `sizeNotional`.
        uint256 perSubjectCap = marginS.tierPerSubjectCap[MarginStorage.KycTier(kycTier)];
        if (sizeNotional > perSubjectCap) {
            revert PerSubjectTraderCapExceeded(trader, subjectId, sizeNotional, perSubjectCap);
        }

        // Combined exposure cap.
        uint256 combinedCap = marginS.tierCombinedCap[MarginStorage.KycTier(kycTier)];
        uint256 newCombined = marginS.exposure[trader].totalPerpNotional + sizeNotional;
        if (newCombined > combinedCap) revert CombinedExposureCapExceeded(trader, newCombined, combinedCap);
    }

    /// @inheritdoc IMarginEngine
    /// @dev Lifted from PerpEngine's open-path leverage + IM checks. Same ordering: leverage
    ///      first (cheaper to compute, and the spec's worst-case violation), then IM. Reverts
    ///      `LeverageTooHigh` carries the *computed* leverage, not the cap — matches the
    ///      pre-extraction error shape.
    function checkInitialMargin(uint256 notional, uint256 collateral) external view {
        if (collateral == 0) revert InvalidConfig();

        MarginStorage.Layout storage marginS = MarginStorage.load();

        uint256 leverageBps = (notional * BPS_DENOMINATOR) / collateral;
        if (leverageBps > marginS.maxLeverageBps) {
            revert LeverageTooHigh(leverageBps, marginS.maxLeverageBps);
        }
        uint256 reqIM = (notional * marginS.initialMarginBps) / BPS_DENOMINATOR;
        if (collateral < reqIM) revert InitialMarginShort(reqIM, collateral);
    }

    /// @inheritdoc IMarginEngine
    /// @dev Mirrors the legacy `removeCollateral` IM re-check on PerpEngine. The caller computes
    ///      `currentNotional = absSize × markNow / 1e18` and `unrealizedPnl` externally and
    ///      passes them in — keeps this contract independent of position storage layout. Negative
    ///      equity is left to the caller's domain error (PerpEngine emits `MaintenanceMarginShort`
    ///      for that case to preserve the historical revert signature).
    function checkInitialMarginResidual(
        uint256 newCollateral,
        uint256 currentNotional,
        int256 unrealizedPnl
    )
        external
        view
    {
        if (currentNotional == 0) revert InvalidConfig();
        MarginStorage.Layout storage marginS = MarginStorage.load();

        // Re-check leverage cap on the residual.
        if (newCollateral == 0) revert InvalidConfig();
        uint256 leverageBps = (currentNotional * BPS_DENOMINATOR) / newCollateral;
        if (leverageBps > marginS.maxLeverageBps) {
            revert LeverageTooHigh(leverageBps, marginS.maxLeverageBps);
        }

        // Equity = collateral + uPnl. Caller short-circuits the negative-equity case before
        // calling this hook (it has the dedicated `MaintenanceMarginShort` selector to emit).
        int256 equitySigned = int256(newCollateral) + unrealizedPnl;
        if (equitySigned <= 0) {
            // Treat as fail-safe — caller should have intercepted; revert IM short with computed
            // required = currentNotional × IM / BPS and provided equity = 0.
            revert InitialMarginShort((currentNotional * marginS.initialMarginBps) / BPS_DENOMINATOR, 0);
        }
        uint256 equity = uint256(equitySigned);
        uint256 marginRatioBps_ = (equity * BPS_DENOMINATOR) / currentNotional;
        if (marginRatioBps_ < marginS.initialMarginBps) {
            revert InitialMarginShort((currentNotional * marginS.initialMarginBps) / BPS_DENOMINATOR, equity);
        }
    }

    /// @inheritdoc IMarginEngine
    /// @dev Mirrors the open-time bookkeeping that previously lived inline in
    ///      `PerpEngine.openPosition`. PerpEngine remains the OI-counter writer on the PerpStorage
    ///      side (long/short totals per subject); this hook is the *signed* per-category and
    ///      per-trader writer.
    function recordOpenDelta(
        address trader,
        bytes32 categoryId,
        Side side,
        uint256 sizeNotional,
        uint8 kycTier
    )
        external
        onlyPerpEngine
    {
        MarginStorage.Layout storage marginS = MarginStorage.load();
        if (side == Side.LONG) {
            marginS.netCategoryOi[categoryId] += int256(sizeNotional);
        } else {
            marginS.netCategoryOi[categoryId] -= int256(sizeNotional);
        }
        marginS.exposure[trader].totalPerpNotional += sizeNotional;
        marginS.exposure[trader].tier = MarginStorage.KycTier(kycTier);
    }

    /// @inheritdoc IMarginEngine
    /// @dev Symmetric counterpart of `recordOpenDelta`. PerpEngine calls this from full close,
    ///      partial close, and `closeAtForcedSettlement` with the OPENING notional being unwound.
    function recordCloseDelta(
        address trader,
        bytes32 categoryId,
        uint256 sizeNotional,
        bool isLong
    )
        external
        onlyPerpEngine
    {
        MarginStorage.Layout storage marginS = MarginStorage.load();
        if (isLong) {
            // Unwind the long's positive contribution.
            marginS.netCategoryOi[categoryId] -= int256(sizeNotional);
        } else {
            // Unwind the short's negative contribution (add back).
            marginS.netCategoryOi[categoryId] += int256(sizeNotional);
        }
        marginS.exposure[trader].totalPerpNotional -= sizeNotional;
    }

    /// @inheritdoc IMarginEngine
    /// @dev Inlines the maintenance-margin computation (`marginRatioBps < maintenanceMarginBps`)
    ///      so MarginEngine does not link LiquidationMath at this layer (keeps the dependency
    ///      graph directed). Same semantic as `PerpEngine.isMarginOk` negated.
    function isUnderMaintenance(
        int256 size,
        uint256 collateral,
        uint256 markPrice,
        uint256 entryPrice
    )
        external
        view
        returns (bool)
    {
        if (size == 0 || markPrice == 0) return false;
        uint256 notional_ = PositionMath.notional(size, markPrice);
        int256 uPnl = PositionMath.unrealizedPnl(size, entryPrice, markPrice);
        int256 equity = PositionMath.equity(collateral, uPnl);
        uint256 ratio = PositionMath.marginRatioBps(equity, notional_);
        return ratio < MarginStorage.load().maintenanceMarginBps;
    }

    // ------------------------------------------------------------------------------------------
    // Governance setters
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IMarginEngine
    function setKycCaps(uint8 tier, uint256 perSubjectCap, uint256 combinedCap) external onlyGovernance {
        if (tier == 0 || tier > 3) revert InvalidKycTier(tier);
        if (perSubjectCap == 0 || combinedCap == 0) revert InvalidConfig();
        if (combinedCap < perSubjectCap) revert InvalidConfig();
        MarginStorage.Layout storage marginS = MarginStorage.load();
        MarginStorage.KycTier t = MarginStorage.KycTier(tier);
        marginS.tierPerSubjectCap[t] = perSubjectCap;
        marginS.tierCombinedCap[t] = combinedCap;
        emit KycCapsSet(tier, perSubjectCap, combinedCap);
    }

    /// @inheritdoc IMarginEngine
    function setMarginParams(uint16 imBps, uint16 mmBps, uint16 bufBps, uint16 maxLevBps) external onlyGovernance {
        if (imBps == 0 || imBps > MAX_INITIAL_MARGIN_BPS) revert InitialMarginBpsOutOfRange(imBps);
        if (mmBps == 0 || mmBps > MAX_MAINTENANCE_MARGIN_BPS) revert MaintenanceMarginBpsOutOfRange(mmBps);
        if (bufBps > MAX_LIQ_BUFFER_BPS) revert LiquidationBufferBpsOutOfRange(bufBps);
        if (maxLevBps == 0 || maxLevBps > MAX_LEVERAGE_BPS) revert MaxLeverageBpsOutOfRange(maxLevBps);
        // Logical ordering: maintenance < initial. A position must be insolvent at MM before
        // becoming insolvent at IM.
        if (mmBps >= imBps) revert MmGteIm(imBps, mmBps);

        MarginStorage.Layout storage marginS = MarginStorage.load();
        marginS.initialMarginBps = imBps;
        marginS.maintenanceMarginBps = mmBps;
        marginS.liquidationBufferBps = bufBps;
        marginS.maxLeverageBps = maxLevBps;
        emit MarginParamsSet(imBps, mmBps, bufBps, maxLevBps);
    }

    /// @inheritdoc IMarginEngine
    /// @dev Bounds [1, MAX_OI_CAP_BPS]. The lower bound is "non-zero" so a misset that disables
    ///      the cap entirely (0 → "cap is 0 USDC") cannot land in one transaction.
    function setPerSubjectSideOiCapBps(uint16 bps) external onlyGovernance {
        if (bps == 0 || bps > MAX_OI_CAP_BPS) revert PerSubjectSideOiCapBpsOutOfRange(bps);
        MarginStorage.Layout storage marginS = MarginStorage.load();
        uint16 old = marginS.perSubjectSideOiCapBps;
        marginS.perSubjectSideOiCapBps = bps;
        emit PerSubjectSideOiCapBpsSet(old, bps);
    }

    /// @inheritdoc IMarginEngine
    /// @dev Spec §3 line 123: net-category cap = 20% of vault TVL. Bounds [500, 5000] preserve
    ///      the lever's meaning at the low end (5%) and keep the per-subject cap binding at the
    ///      high end (50%).
    function setCategoryNetOiCapBps(uint16 bps) external onlyGovernance {
        if (bps < MIN_CATEGORY_NET_OI_CAP_BPS || bps > MAX_CATEGORY_NET_OI_CAP_BPS) {
            revert CategoryNetOiCapBpsOutOfRange(bps);
        }
        MarginStorage.Layout storage marginS = MarginStorage.load();
        uint16 old = marginS.categoryNetOiCapBps;
        marginS.categoryNetOiCapBps = bps;
        emit CategoryNetOiCapBpsSet(old, bps);
    }

    // ------------------------------------------------------------------------------------------
    // Wiring
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IMarginEngine
    /// @dev Non-timelocked rotation. The `perpEngine` field is a pointer used only for view
    ///      passthroughs (`positionFor`, `isMarginOk`) — it does not gate any privileged action,
    ///      so an immediate setter under the governance multi-sig is the right shape.
    function setPerpEngine(address newPerpEngine) external onlyGovernance {
        if (newPerpEngine == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        address old = s.perpEngine;
        s.perpEngine = newPerpEngine;
        emit PerpEngineSet(old, newPerpEngine);
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IMarginEngine
    function proposeGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        if (s.pendingGovernanceActivatesAt != 0) revert PendingGovernanceTransferExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingGovernance = newGovernance;
        s.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGovernance, activatesAt);
    }

    /// @inheritdoc IMarginEngine
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

    /// @inheritdoc IMarginEngine
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

    /// @inheritdoc IMarginEngine
    function initialMarginBps() external view returns (uint16) {
        return MarginStorage.load().initialMarginBps;
    }

    /// @inheritdoc IMarginEngine
    function maintenanceMarginBps() external view returns (uint16) {
        return MarginStorage.load().maintenanceMarginBps;
    }

    /// @inheritdoc IMarginEngine
    function liquidationBufferBps() external view returns (uint16) {
        return MarginStorage.load().liquidationBufferBps;
    }

    /// @inheritdoc IMarginEngine
    function maxLeverageBps() external view returns (uint16) {
        return MarginStorage.load().maxLeverageBps;
    }

    /// @inheritdoc IMarginEngine
    function perSubjectSideOiCapBps() external view returns (uint16) {
        return MarginStorage.load().perSubjectSideOiCapBps;
    }

    /// @inheritdoc IMarginEngine
    function categoryNetOiCapBps() external view returns (uint16) {
        return MarginStorage.load().categoryNetOiCapBps;
    }

    /// @inheritdoc IMarginEngine
    function crossMarginMultiplier() external view returns (uint256) {
        return MarginStorage.load().crossMarginMultiplier;
    }

    /// @inheritdoc IMarginEngine
    function netCategoryOiOf(bytes32 categoryId) external view returns (int256) {
        return MarginStorage.load().netCategoryOi[categoryId];
    }

    /// @inheritdoc IMarginEngine
    function tierPerSubjectCap(uint8 tier) external view returns (uint256) {
        return MarginStorage.load().tierPerSubjectCap[MarginStorage.KycTier(tier)];
    }

    /// @inheritdoc IMarginEngine
    function tierCombinedCap(uint8 tier) external view returns (uint256) {
        return MarginStorage.load().tierCombinedCap[MarginStorage.KycTier(tier)];
    }

    /// @inheritdoc IMarginEngine
    function tierCaps(uint8 tier) external view returns (uint256 perSubjectCap, uint256 combinedCap) {
        MarginStorage.Layout storage marginS = MarginStorage.load();
        MarginStorage.KycTier t = MarginStorage.KycTier(tier);
        return (marginS.tierPerSubjectCap[t], marginS.tierCombinedCap[t]);
    }

    /// @inheritdoc IMarginEngine
    function marginParams()
        external
        view
        returns (uint16 imBps, uint16 mmBps, uint16 bufBps, uint16 maxLevBps, uint16 perSubjectSideOiCapBps_)
    {
        MarginStorage.Layout storage marginS = MarginStorage.load();
        return (
            marginS.initialMarginBps,
            marginS.maintenanceMarginBps,
            marginS.liquidationBufferBps,
            marginS.maxLeverageBps,
            marginS.perSubjectSideOiCapBps
        );
    }

    /// @inheritdoc IMarginEngine
    function exposureOf(address trader)
        external
        view
        returns (uint256 totalPerpNotional, uint256 totalEventExposure, uint8 tier)
    {
        MarginStorage.AccountExposure storage e = MarginStorage.load().exposure[trader];
        return (e.totalPerpNotional, e.totalEventExposure, uint8(e.tier));
    }

    /// @inheritdoc IMarginEngine
    function governance() external view returns (address) {
        return _s().governance;
    }

    /// @inheritdoc IMarginEngine
    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        Layout storage s = _s();
        return (s.pendingGovernance, s.pendingGovernanceActivatesAt);
    }

    /// @inheritdoc IMarginEngine
    function timelockDelay() external view returns (uint32) {
        return _s().timelockDelay;
    }

    /// @inheritdoc IMarginEngine
    function perpEngine() external view returns (address) {
        return _s().perpEngine;
    }

    /// @inheritdoc IMarginEngine
    function isMarginOk(bytes32 positionId) external view returns (bool) {
        address pe = _s().perpEngine;
        if (pe == address(0)) return false;
        IPerpEngine.Position memory pos = IPerpEngine(pe).positionOf(positionId);
        if (pos.size == 0) return true;
        (uint256 markNow,) = IPerpEngine(pe).markOf(pos.subjectId);
        if (markNow == 0) return false;
        uint256 notional_ = PositionMath.notional(pos.size, markNow);
        int256 uPnl = PositionMath.unrealizedPnl(pos.size, pos.entryPrice, markNow);
        int256 eq = PositionMath.equity(pos.collateral, uPnl);
        uint256 ratio = PositionMath.marginRatioBps(eq, notional_);
        return ratio >= MarginStorage.load().maintenanceMarginBps;
    }

    /// @inheritdoc IMarginEngine
    function positionFor(bytes32 positionId) external view returns (IPerpEngine.Position memory) {
        address pe = _s().perpEngine;
        if (pe == address(0)) revert InvalidConfig();
        return IPerpEngine(pe).positionOf(positionId);
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
