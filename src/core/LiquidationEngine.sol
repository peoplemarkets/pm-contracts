// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {LiquidationMath} from "../libraries/LiquidationMath.sol";

import {IInsuranceFund} from "./IInsuranceFund.sol";
import {ILPVault} from "./ILPVault.sol";
import {ILiquidationEngine} from "./ILiquidationEngine.sol";
import {IMarginEngine} from "./IMarginEngine.sol";
import {IPerpEngine} from "./IPerpEngine.sol";

/// @title  LiquidationEngine — v0 of the 5-tier waterfall (spec §3 lines 141-155).
///
/// @notice The sole entry point for liquidating positions that have crossed the liquidation
///         buffer. Implements Tiers 1-4 in this wave (PARTIAL, FULL, INSURANCE, SOCIALIZATION).
///         Tier 5 (ADL) is deferred: any path that would require it reverts with
///         `ADLNotImplemented`. The ADL queue iteration over open positions is gated for v1.
///
/// @dev    Why each tier:
///           1. PARTIAL — close 25% of the position, restore equity to MM + 100bps buffer.
///              Limits market impact on cascading liquidations. After
///              `minPartialsBeforeFull` attempts (default 4) — or the moment a partial returns
///              `collateralFreed == 0`, signalling insufficient slice — the engine escalates.
///           2. FULL — close the entire remaining position. 1% bounty on closed notional.
///           3. INSURANCE — when equity + collateral < bounty, draw the shortfall from the
///              standalone `InsuranceFund` (cap-driven; if insurance balance covers,
///              socialization is skipped entirely).
///           4. SOCIALIZATION — remaining shortfall absorbed by LP vault as a negative pnl on
///              `settleLiquidation`. Capped at `socializationCapBps × totalAssets()` per single
///              liquidation event. Excess reverts `SocializationCapExceeded` — that residual
///              would land on Tier 5 in v1.
///           5. ADL — deferred. Reverts.
///
/// @dev    Liquidators are a registered set (timelocked add, immediate remove) — matches the
///         mark-writer pattern. The bounty is the incentive; gating to a registered set caps
///         MEV griefing where a bot could call `liquidate` on its own block-tip data feed.
///
/// @dev    Storage namespace `keccak256("people.markets.liquidationengine.v1")` — NEW for this
///         contract. The legacy `LiquidationStorage` library namespace
///         (`keccak256("people.markets.liquidation.v1")`) is reserved for a future engine
///         version; this contract does not read or write it.
contract LiquidationEngine is Initializable, UUPSUpgradeable, ReentrancyGuard, ILiquidationEngine {
    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant ONE = 1e18;

    uint32 internal constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 internal constant MAX_TIMELOCK_DELAY = 30 days;

    // Default config values (seeded on initialize when storage is still zero).
    uint16 internal constant DEFAULT_PARTIAL_INCREMENT_BPS = 2_500; // 25%
    uint8 internal constant DEFAULT_MIN_PARTIALS_BEFORE_FULL = 4;
    uint16 internal constant DEFAULT_MM_RESTORE_BUFFER_BPS = 100; // 1%
    uint16 internal constant DEFAULT_FULL_BOUNTY_BPS = 100; // 1%
    uint16 internal constant DEFAULT_SOCIALIZATION_CAP_BPS = 3_000; // 30%

    // Bounds (enforced by setConfig).
    uint16 internal constant MIN_PARTIAL_INCREMENT_BPS = 500; // 5%
    uint16 internal constant MAX_PARTIAL_INCREMENT_BPS = 10_000; // 100%
    uint8 internal constant MIN_MIN_PARTIALS = 1;
    uint8 internal constant MAX_MIN_PARTIALS = 10;
    uint16 internal constant MAX_MM_RESTORE_BUFFER_BPS = 1_000; // 10%
    uint16 internal constant MAX_FULL_BOUNTY_BPS = 500; // 5%
    uint16 internal constant MIN_SOCIALIZATION_CAP_BPS = 500; // 5%
    uint16 internal constant MAX_SOCIALIZATION_CAP_BPS = 10_000; // 100%

    // ------------------------------------------------------------------------------------------
    // Namespaced storage
    // ------------------------------------------------------------------------------------------

    bytes32 internal constant LIQUIDATION_ENGINE_SLOT = keccak256("people.markets.liquidationengine.v1");

    /// @custom:storage-location erc7201:people.markets.liquidationengine.v1
    struct Layout {
        // Governance + timelock.
        address governance;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        uint32 timelockDelay;
        // Dependencies (immutable in v0; rotation lives on the caller side via PerpEngine and
        // LPVault). MarginEngine is queried only as a fallback for the maintenance-margin probe.
        address perpEngine;
        address marginEngine;
        address lpVault;
        address insuranceFund;
        // Config.
        uint16 partialIncrementBps;
        uint8 minPartialsBeforeFull;
        uint16 mmRestoreBufferBps;
        uint16 fullBountyBps;
        uint16 socializationCapBps;
        // Liquidator set + per-position partial counter.
        mapping(address account => bool) liquidators;
        mapping(address account => uint64) pendingLiquidatorActivatesAt;
        mapping(bytes32 positionId => uint8) partialAttempts;
    }

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = LIQUIDATION_ENGINE_SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ------------------------------------------------------------------------------------------
    // Initializer
    // ------------------------------------------------------------------------------------------

    /// @notice Initialize the engine.
    /// @param  governance_      Multi-sig that proposes/activates config + liquidator changes.
    /// @param  perpEngine_      Live PerpEngine address. Sole position writer.
    /// @param  marginEngine_    Live MarginEngine address. Queried for maintenance margin
    ///                          parameters and the `isUnderLiquidationBuffer` probe.
    /// @param  lpVault_         Live LPVault address. Receives `settleLiquidation` calls and
    ///                          the `drawFromInsuranceForLiquidation` pre-funding.
    /// @param  insuranceFund_   Live InsuranceFund address. Read for `balance()` to cap the
    ///                          Tier-3 draw.
    /// @param  timelockDelay_   Seconds, bounds [1h, 30d].
    function initialize(
        address governance_,
        address perpEngine_,
        address marginEngine_,
        address lpVault_,
        address insuranceFund_,
        uint32 timelockDelay_
    )
        external
        initializer
    {
        if (governance_ == address(0)) revert InvalidConfig();
        if (perpEngine_ == address(0) || marginEngine_ == address(0)) revert InvalidConfig();
        if (lpVault_ == address(0) || insuranceFund_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();

        Layout storage s = _s();
        s.governance = governance_;
        s.perpEngine = perpEngine_;
        s.marginEngine = marginEngine_;
        s.lpVault = lpVault_;
        s.insuranceFund = insuranceFund_;
        s.timelockDelay = timelockDelay_;

        // Seed defaults — idempotent in case a future re-init lands.
        if (s.partialIncrementBps == 0) s.partialIncrementBps = DEFAULT_PARTIAL_INCREMENT_BPS;
        if (s.minPartialsBeforeFull == 0) s.minPartialsBeforeFull = DEFAULT_MIN_PARTIALS_BEFORE_FULL;
        if (s.mmRestoreBufferBps == 0) s.mmRestoreBufferBps = DEFAULT_MM_RESTORE_BUFFER_BPS;
        if (s.fullBountyBps == 0) s.fullBountyBps = DEFAULT_FULL_BOUNTY_BPS;
        if (s.socializationCapBps == 0) s.socializationCapBps = DEFAULT_SOCIALIZATION_CAP_BPS;

        emit Initialized(governance_, perpEngine_, marginEngine_, lpVault_, insuranceFund_);
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != _s().governance) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyLiquidator() {
        if (!_s().liquidators[msg.sender]) revert OnlyLiquidator(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // The waterfall — Tier 1, 2, 3, 4 (Tier 5 reverts)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILiquidationEngine
    function liquidate(bytes32 positionId)
        external
        nonReentrant
        onlyLiquidator
        returns (LiquidationResult memory result)
    {
        Layout storage s = _s();
        IPerpEngine pe = IPerpEngine(s.perpEngine);

        IPerpEngine.Position memory pos = pe.positionOf(positionId);
        if (pos.size == 0) revert PositionNotFound(positionId);

        (uint256 mark,) = pe.markOf(pos.subjectId);
        if (mark == 0) revert NotUnderBuffer(positionId);

        // Liquidation gate: position must be below MM + liquidation buffer. We re-derive the gate
        // here using LiquidationMath rather than calling MarginEngine, because MarginEngine
        // exposes only `isUnderMaintenance` (without the additional buffer). This keeps the
        // dependency on MarginEngine narrow — just for the bps parameters.
        IMarginEngine me = IMarginEngine(s.marginEngine);
        (, uint16 mmBps, uint16 bufBps,,) = me.marginParams();
        bool underBuffer =
            LiquidationMath.isUnderLiquidationBuffer(pos.size, pos.collateral, mark, pos.entryPrice, mmBps, bufBps);
        if (!underBuffer) revert NotUnderBuffer(positionId);

        result.positionId = positionId;
        result.trader = pos.owner;
        result.markPrice = mark;

        uint8 attempts = s.partialAttempts[positionId];
        // Branch 1: partial path. The attempts counter has not yet exhausted the budget.
        if (attempts < s.minPartialsBeforeFull) {
            LiquidationMath.PartialResult memory pr = LiquidationMath.computePartialIncrement(
                pos.size,
                pos.collateral,
                mark,
                pos.entryPrice,
                s.partialIncrementBps,
                s.fullBountyBps,
                mmBps,
                s.mmRestoreBufferBps
            );

            if (pr.collateralFreed > 0) {
                // Partial succeeded. Apply it via PerpEngine.liquidateClose.
                //
                // The slice closed is `pr.reducedSize`; the slice's collateral share is
                // `pos.collateral × partialIncrementBps / 10_000`. The vault's payout-conservation
                // invariant requires `traderPayout + bounty = sliceCollateral + slicePnl`, so we
                // back out `slicePnl` from `(collateralFreed, bountyTarget, sliceCollateral)`.
                uint256 sliceCollateral = (pos.collateral * uint256(s.partialIncrementBps)) / BPS_DENOMINATOR;
                int256 slicePnl = int256(pr.collateralFreed) + int256(pr.bountyToLiquidator) - int256(sliceCollateral);

                pe.liquidateClose(
                    positionId,
                    pr.reducedSize,
                    pr.collateralFreed,
                    pr.bountyToLiquidator,
                    slicePnl,
                    msg.sender,
                    uint8(Tier.PARTIAL)
                );
                s.partialAttempts[positionId] = attempts + 1;

                result.tier = Tier.PARTIAL;
                result.sizeClosed = pr.reducedSize;
                result.collateralReturned = pr.collateralFreed;
                result.bountyPaid = pr.bountyToLiquidator;
                result.shortfallPnl = 0;
                emit Liquidated(result, msg.sender);
                return result;
            }
            // Partial returned `collateralFreed == 0`: the slice was not enough to restore the
            // residual to MM + buffer. We escalate WITHIN THE SAME CALL — bump the counter so the
            // partial budget is recorded, then fall through to the full waterfall. Without this
            // in-call escalation a liquidator would have to call `liquidate` `minPartialsBeforeFull`
            // times in separate transactions just to pay for the full close.
            s.partialAttempts[positionId] = s.minPartialsBeforeFull;
        }

        // Branch 2: full path. Either the attempts counter exhausted the partial budget OR the
        // last partial flagged `PartialInsufficient` and we hit `>= minPartialsBeforeFull`.
        return _runFullWaterfall(s, pe, pos, positionId, mark);
    }

    /// @dev Tier 2 — full close. If equity covers the bounty, the trader gets the residue and the
    ///      liquidator gets the bounty. Otherwise the shortfall flows through Tier 3
    ///      (InsuranceFund draw) and Tier 4 (LP socialization).
    function _runFullWaterfall(
        Layout storage s,
        IPerpEngine pe,
        IPerpEngine.Position memory pos,
        bytes32 positionId,
        uint256 mark
    )
        internal
        returns (LiquidationResult memory result)
    {
        result.positionId = positionId;
        result.trader = pos.owner;
        result.markPrice = mark;

        LiquidationMath.FullResult memory fr =
            LiquidationMath.computeFullLiquidation(pos.size, pos.collateral, mark, pos.entryPrice, s.fullBountyBps);

        if (fr.shortfall <= 0) {
            // Tier 2 only — equity covers the bounty.
            // Payout-conservation: bountyToLiquidator + collateralReturned = collateral + signedPnl.
            // signedPnl = bountyToLiquidator + collateralReturned - collateral.
            int256 signedPnl = int256(fr.bountyToLiquidator) + int256(fr.collateralReturned) - int256(pos.collateral);
            pe.liquidateClose(
                positionId,
                fr.closedSize,
                fr.collateralReturned,
                fr.bountyToLiquidator,
                signedPnl,
                msg.sender,
                uint8(Tier.FULL)
            );
            result.tier = Tier.FULL;
            result.sizeClosed = fr.closedSize;
            result.collateralReturned = fr.collateralReturned;
            result.bountyPaid = fr.bountyToLiquidator;
            result.shortfallPnl = 0;
            emit Liquidated(result, msg.sender);
            return result;
        }

        // Shortfall > 0. Tier 3 first — draw from InsuranceFund up to its balance.
        uint256 shortfall = uint256(fr.shortfall);
        IInsuranceFund insFund = IInsuranceFund(s.insuranceFund);
        uint256 insBalance = insFund.balance();
        uint256 drawn = shortfall <= insBalance ? shortfall : insBalance;
        uint256 socialized = shortfall - drawn;

        if (socialized > 0) {
            // Tier 4 — LP socialization. Cap at socializationCapBps × totalAssets() per event.
            uint256 cap = (IERC4626(s.lpVault).totalAssets() * uint256(s.socializationCapBps)) / BPS_DENOMINATOR;
            if (socialized > cap) revert SocializationCapExceeded(socialized, cap);
        }

        if (drawn > 0) {
            // Pre-fund the LPVault by drawing insurance. The USDC lands on the vault balance,
            // boosting freeAssets for the subsequent `settleLiquidation` call.
            ILPVault(s.lpVault).drawFromInsuranceForLiquidation(drawn);
        }

        // Compose the trader payout & bounty for the underwater close. The trader gets nothing
        // (case B/C of LiquidationMath.computeFullLiquidation: equity ≤ bountyTarget). The
        // liquidator gets the funded bounty — `bountyToLiquidator` in the math result, sized
        // BELOW the target when equity was insufficient. We MUST top up the bounty back to the
        // target so the liquidator is paid in full; the insurance + socialization together cover
        // that top-up.
        uint256 bountyTarget = _bountyTargetForFull(pos.size, mark, s.fullBountyBps);
        // collateralReturned in fr is 0 in case B/C; trader gets 0.
        // bountyToLiquidator in fr is capped at equity (B) or 0 (C); we top up to bountyTarget.

        // Payout-conservation:
        //   traderPayout + bountyPaid = collateral + signedPnl
        // We choose:
        //   bountyPaid = bountyTarget                 (always full bounty after Tier 3/4 absorb)
        //   traderPayout = fr.collateralReturned      (always 0 in cases B/C)
        // ⇒ signedPnl = bountyTarget + traderPayout - collateral
        //             = bountyTarget - collateral     (trader payout is 0)
        //
        // The vault sees: collateralReleased + signedPnl = bountyTarget. It transfers the
        // bountyTarget to the liquidator. The pre-drawn insurance USDC (and any LP loss absorbed
        // through `freeAssets`) backs the gap between `collateral` and `bountyTarget + |loss|`.
        int256 signedPnlFull = int256(bountyTarget) + int256(fr.collateralReturned) - int256(pos.collateral);

        pe.liquidateClose(
            positionId,
            fr.closedSize,
            fr.collateralReturned,
            bountyTarget,
            signedPnlFull,
            msg.sender,
            socialized > 0 ? uint8(Tier.SOCIALIZATION) : uint8(Tier.INSURANCE)
        );

        result.tier = socialized > 0 ? Tier.SOCIALIZATION : Tier.INSURANCE;
        result.sizeClosed = fr.closedSize;
        result.collateralReturned = fr.collateralReturned;
        result.bountyPaid = bountyTarget;
        result.shortfallPnl = int256(shortfall);
        emit Liquidated(result, msg.sender);
        return result;
    }

    // ------------------------------------------------------------------------------------------
    // Wave 7 audit Fix #6 — permissionless reset of partialAttempts for healed positions
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILiquidationEngine
    function resetPartialAttempts(bytes32 positionId) external {
        Layout storage s = _s();
        IPerpEngine pe = IPerpEngine(s.perpEngine);

        IPerpEngine.Position memory pos = pe.positionOf(positionId);
        if (pos.size == 0) revert PositionNotFound(positionId);

        (uint256 mark,) = pe.markOf(pos.subjectId);
        // markOf == 0 implies the subject has no live mark; treat as "not under buffer" — a
        // position without a usable mark is not actively distressed and should be eligible for
        // reset so the next mark push can put the partial budget back in play.
        if (mark != 0) {
            (, uint16 mmBps, uint16 bufBps,,) = IMarginEngine(s.marginEngine).marginParams();
            bool underBuffer = LiquidationMath.isUnderLiquidationBuffer(
                pos.size, pos.collateral, mark, pos.entryPrice, mmBps, bufBps
            );
            if (underBuffer) revert StillUnderBuffer(positionId);
        }

        // Healed: clear the counter so the next distress cycle starts fresh at the partial phase.
        s.partialAttempts[positionId] = 0;
        emit PartialAttemptsReset(positionId);
    }

    /// @dev Helper: recompute the bounty target (notional × fullBountyBps / 10_000) for the
    ///      full-close path. Mirrors the math inside `LiquidationMath.computeFullLiquidation`.
    function _bountyTargetForFull(int256 size, uint256 mark, uint16 bps) internal pure returns (uint256) {
        uint256 absSize = size > 0 ? uint256(size) : uint256(-size);
        uint256 notional6 = (absSize * mark) / ONE;
        return (notional6 * uint256(bps)) / BPS_DENOMINATOR;
    }

    // ------------------------------------------------------------------------------------------
    // Governance — config
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILiquidationEngine
    function setConfig(
        uint16 partialIncrementBps_,
        uint8 minPartialsBeforeFull_,
        uint16 mmRestoreBufferBps_,
        uint16 fullBountyBps_,
        uint16 socializationCapBps_
    )
        external
        onlyGovernance
    {
        if (partialIncrementBps_ < MIN_PARTIAL_INCREMENT_BPS || partialIncrementBps_ > MAX_PARTIAL_INCREMENT_BPS) {
            revert PartialIncrementOutOfRange(partialIncrementBps_);
        }
        if (minPartialsBeforeFull_ < MIN_MIN_PARTIALS || minPartialsBeforeFull_ > MAX_MIN_PARTIALS) {
            revert MinPartialsOutOfRange(minPartialsBeforeFull_);
        }
        if (mmRestoreBufferBps_ > MAX_MM_RESTORE_BUFFER_BPS) revert MmRestoreBufferOutOfRange(mmRestoreBufferBps_);
        if (fullBountyBps_ > MAX_FULL_BOUNTY_BPS) revert FullBountyOutOfRange(fullBountyBps_);
        if (socializationCapBps_ < MIN_SOCIALIZATION_CAP_BPS || socializationCapBps_ > MAX_SOCIALIZATION_CAP_BPS) {
            revert LpSocializationCapOutOfRange(socializationCapBps_);
        }

        Layout storage s = _s();
        s.partialIncrementBps = partialIncrementBps_;
        s.minPartialsBeforeFull = minPartialsBeforeFull_;
        s.mmRestoreBufferBps = mmRestoreBufferBps_;
        s.fullBountyBps = fullBountyBps_;
        s.socializationCapBps = socializationCapBps_;

        emit ConfigSet(
            partialIncrementBps_, minPartialsBeforeFull_, mmRestoreBufferBps_, fullBountyBps_, socializationCapBps_
        );
    }

    // ------------------------------------------------------------------------------------------
    // Governance — liquidator set (timelocked add, immediate remove)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILiquidationEngine
    function proposeAddLiquidator(address liquidator) external onlyGovernance {
        if (liquidator == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        if (s.liquidators[liquidator]) revert LiquidatorAlreadyAdded(liquidator);
        if (s.pendingLiquidatorActivatesAt[liquidator] != 0) revert PendingLiquidatorExists(liquidator);
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingLiquidatorActivatesAt[liquidator] = activatesAt;
        emit LiquidatorProposed(liquidator, activatesAt);
    }

    /// @inheritdoc ILiquidationEngine
    function activateAddLiquidator(address liquidator) external {
        Layout storage s = _s();
        uint64 readyAt = s.pendingLiquidatorActivatesAt[liquidator];
        if (readyAt == 0) revert NoPendingLiquidator(liquidator);
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        delete s.pendingLiquidatorActivatesAt[liquidator];
        s.liquidators[liquidator] = true;
        emit LiquidatorActivated(liquidator);
    }

    /// @inheritdoc ILiquidationEngine
    function cancelAddLiquidator(address liquidator) external onlyGovernance {
        Layout storage s = _s();
        if (s.pendingLiquidatorActivatesAt[liquidator] == 0) revert NoPendingLiquidator(liquidator);
        delete s.pendingLiquidatorActivatesAt[liquidator];
        emit LiquidatorCancelled(liquidator);
    }

    /// @inheritdoc ILiquidationEngine
    function removeLiquidator(address liquidator) external onlyGovernance {
        Layout storage s = _s();
        if (!s.liquidators[liquidator]) revert LiquidatorNotSet(liquidator);
        delete s.liquidators[liquidator];
        emit LiquidatorRemoved(liquidator);
    }

    // ------------------------------------------------------------------------------------------
    // Governance — transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILiquidationEngine
    function proposeGovernanceTransfer(address newGov) external onlyGovernance {
        if (newGov == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        if (s.pendingGovernanceActivatesAt != 0) revert PendingGovernanceTransferExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingGovernance = newGov;
        s.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGov, activatesAt);
    }

    /// @inheritdoc ILiquidationEngine
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

    /// @inheritdoc ILiquidationEngine
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

    /// @inheritdoc ILiquidationEngine
    function partialAttemptsOf(bytes32 positionId) external view returns (uint8) {
        return _s().partialAttempts[positionId];
    }

    /// @inheritdoc ILiquidationEngine
    function partialIncrementBps() external view returns (uint16) {
        return _s().partialIncrementBps;
    }

    /// @inheritdoc ILiquidationEngine
    function minPartialsBeforeFull() external view returns (uint8) {
        return _s().minPartialsBeforeFull;
    }

    /// @inheritdoc ILiquidationEngine
    function mmRestoreBufferBps() external view returns (uint16) {
        return _s().mmRestoreBufferBps;
    }

    /// @inheritdoc ILiquidationEngine
    function fullBountyBps() external view returns (uint16) {
        return _s().fullBountyBps;
    }

    /// @inheritdoc ILiquidationEngine
    function socializationCapBps() external view returns (uint16) {
        return _s().socializationCapBps;
    }

    /// @inheritdoc ILiquidationEngine
    function isLiquidator(address account) external view returns (bool) {
        return _s().liquidators[account];
    }

    /// @inheritdoc ILiquidationEngine
    function pendingLiquidatorActivatesAt(address account) external view returns (uint64) {
        return _s().pendingLiquidatorActivatesAt[account];
    }

    /// @inheritdoc ILiquidationEngine
    function governance() external view returns (address) {
        return _s().governance;
    }

    /// @inheritdoc ILiquidationEngine
    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        Layout storage s = _s();
        return (s.pendingGovernance, s.pendingGovernanceActivatesAt);
    }

    /// @inheritdoc ILiquidationEngine
    function timelockDelay() external view returns (uint32) {
        return _s().timelockDelay;
    }

    /// @inheritdoc ILiquidationEngine
    function perpEngine() external view returns (address) {
        return _s().perpEngine;
    }

    /// @inheritdoc ILiquidationEngine
    function marginEngine() external view returns (address) {
        return _s().marginEngine;
    }

    /// @inheritdoc ILiquidationEngine
    function lpVault() external view returns (address) {
        return _s().lpVault;
    }

    /// @inheritdoc ILiquidationEngine
    function insuranceFund() external view returns (address) {
        return _s().insuranceFund;
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
