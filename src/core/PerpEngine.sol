// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {PositionMath} from "../libraries/PositionMath.sol";
import {MarginStorage, PerpStorage} from "../libraries/StorageLib.sol";
import {ISubjectRegistry} from "../registry/ISubjectRegistry.sol";

import {ILPVault} from "./ILPVault.sol";
import {IPerpEngine} from "./IPerpEngine.sol";

/// @title PerpEngine — position lifecycle for People Markets perps.
/// @notice Single contract entry point for `openPosition`, `closePosition`, `addCollateral`,
///         `removeCollateral`, and the permissioned `pushMark`. Reads subject status + KYC
///         tier from the SubjectRegistry; routes collateral and PnL through the LPVault.
///
/// @dev    v0 scope: one position per (trader, subject), no funding accrual, no liquidation,
///         no event-impulse feedback. The Position struct reserves an `entryFundingIndex` slot
///         so FundingEngine (week 8-9) can ship without a storage migration.
///
/// @dev    Roles:
///         - `governance` — slow lever, timelocked. Mark-writer adds, governance transfer.
///         - `governance` (no timelock) — margin/cap parameter setters, mark-writer revokes,
///           globalHalt. Parameter changes have a lower blast radius than role grants;
///           timelocked governance multi-sig provides operational discipline.
///         - `markWriters` — push-only. Off-chain price keepers.
contract PerpEngine is Initializable, UUPSUpgradeable, ReentrancyGuard, IPerpEngine {
    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Fee precision: 1e6, so taker = 0.075% = 750. Bps (1e4) is too coarse for the spec's
    ///      0.075% / 0.025% values; ppm gives clean integers without fractional rounding.
    uint256 internal constant FEE_RATE_DENOM = 1_000_000;
    uint16 internal constant TAKER_FEE_RATE = 750; // 0.075% per spec §3
    uint16 internal constant MAKER_FEE_RATE = 250; // 0.025%

    /// @dev Spec §3 fee split: 40% LP rebate, 50% insurance, 10% residual treasury.
    uint8 internal constant LP_REBATE_PCT = 40;
    uint8 internal constant INSURANCE_PCT = 50;

    uint32 internal constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 internal constant MAX_TIMELOCK_DELAY = 30 days;

    uint32 internal constant MIN_MARK_STALE_AFTER = 5 seconds;
    uint32 internal constant MAX_MARK_STALE_AFTER = 1 hours;

    /// @dev Sanity bounds for mark prices. Anything outside this range is a misconfiguration.
    uint256 internal constant MIN_MARK = 1; // strictly positive
    uint256 internal constant MAX_MARK = 1e36; // 1e18 USDC × 1e18 fixed-point

    /// @dev Hard ceilings for governance-tunable params. Block obvious misconfiguration.
    uint16 internal constant MAX_INITIAL_MARGIN_BPS = 10_000; // 100%
    uint16 internal constant MAX_MAINTENANCE_MARGIN_BPS = 5_000; // 50%
    uint16 internal constant MAX_LIQ_BUFFER_BPS = 2_000; // 20%
    uint16 internal constant MAX_LEVERAGE_BPS = 60_000; // 6× (uint16 packing bound on storage)
    uint16 internal constant MAX_OI_CAP_BPS = 5_000; // 50%

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the engine. One-time, called via the proxy.
    function initialize(
        address governance_,
        uint32 timelockDelay_,
        address subjectRegistry_,
        address lpVault_
    )
        external
        initializer
    {
        if (governance_ == address(0)) revert InvalidConfig();
        if (subjectRegistry_ == address(0) || lpVault_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();

        PerpStorage.Layout storage perpS = PerpStorage.load();
        perpS.governance = governance_;
        perpS.timelockDelay = timelockDelay_;
        perpS.subjectRegistry = subjectRegistry_;
        perpS.lpVault = lpVault_;
        perpS.markStaleAfter = 30 seconds; // spec §1 default

        // Margin params seeded with spec §3 defaults; governance can tune later.
        MarginStorage.Layout storage marginS = MarginStorage.load();
        marginS.initialMarginBps = 2_000; // 20%
        marginS.maintenanceMarginBps = 500; // 5%
        marginS.liquidationBufferBps = 250; // 2.5%
        marginS.maxLeverageBps = 50_000; // 5×
        marginS.perSubjectSideOiCapBps = 500; // 5%
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != PerpStorage.load().governance) revert Unauthorized(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // Trader actions
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    function openPosition(OpenParams calldata p) external nonReentrant returns (bytes32 positionId) {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        MarginStorage.Layout storage marginS = MarginStorage.load();

        if (perpS.globalHalt) revert GlobalHaltedError();
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        if (p.collateralAmount == 0 || p.sizeNotional == 0) revert AmountZero();

        // Subject + KYC gate — registry's requireTradeable reverts on UNREGISTERED, paused,
        // delisted, or any policy flag.
        ISubjectRegistry(perpS.subjectRegistry).requireTradeable(p.subjectId);
        uint8 tier = ISubjectRegistry(perpS.subjectRegistry).kycTierOf(msg.sender);
        if (tier == 0) revert KycTierMissing(msg.sender);

        uint256 markNow = _readFreshMark(perpS, p.subjectId);
        _checkSlippage(markNow, p.expectedMark, p.maxSlippageBps);

        // One-position-per-(trader, subject) invariant.
        if (perpS.openPositionId[msg.sender][p.subjectId] != bytes32(0)) {
            revert PositionAlreadyOpen(msg.sender, p.subjectId);
        }

        // Leverage + initial margin.
        uint256 leverageBps = (p.sizeNotional * BPS_DENOMINATOR) / p.collateralAmount;
        if (leverageBps > marginS.maxLeverageBps) {
            revert LeverageTooHigh(leverageBps, marginS.maxLeverageBps);
        }
        uint256 reqIM = (p.sizeNotional * marginS.initialMarginBps) / BPS_DENOMINATOR;
        if (p.collateralAmount < reqIM) revert InitialMarginShort(reqIM, p.collateralAmount);

        // Caps.
        _enforceOpenCaps(perpS, marginS, p.subjectId, p.side, p.sizeNotional, tier);

        // Compute fee + split.
        (uint256 fee, uint256 lpRebate, uint256 insuranceShare) = _computeFees(p.sizeNotional, p.isMaker);

        // Compute signed size in base units. Bound check: sizeNotional × ONE fits since
        // sizeNotional ≤ tier cap (max ≈ 1e6 USDC × 1e18 = 1e24 — safe).
        int256 absSize = int256((p.sizeNotional * ONE) / markNow);
        int256 signedSize = p.side == Side.LONG ? absSize : -absSize;

        // Allocate positionId from monotonic nonce.
        unchecked {
            positionId = keccak256(abi.encode(msg.sender, p.subjectId, perpS.nextPositionNonce++));
        }

        // Write position.
        perpS.positions[positionId] = Position({
            size: signedSize,
            collateral: p.collateralAmount,
            entryPrice: markNow,
            entryFundingIndex: 0,
            openedAt: uint64(block.timestamp),
            lastInteractionAt: uint64(block.timestamp),
            owner: msg.sender,
            subjectId: p.subjectId
        });
        perpS.openPositionId[msg.sender][p.subjectId] = positionId;

        // OI + exposure (post-delta).
        if (p.side == Side.LONG) {
            perpS.totalLongOI[p.subjectId] += p.sizeNotional;
        } else {
            perpS.totalShortOI[p.subjectId] += p.sizeNotional;
        }
        marginS.exposure[msg.sender].totalPerpNotional += p.sizeNotional;
        marginS.exposure[msg.sender].tier = MarginStorage.KycTier(tier);

        // Vault settle: pull (collateralAmount + fee) from trader, book the split.
        ILPVault(perpS.lpVault).openPositionFlow(msg.sender, p.collateralAmount, fee, lpRebate, insuranceShare);

        emit PositionOpened(positionId, msg.sender, p.subjectId, p.side, signedSize, markNow, p.collateralAmount, fee);
    }

    /// @dev Local-only struct used to thread close-flow values out of the helper. Keeps
    ///      `closePosition` under solc's stack-depth bound when via-IR is disabled (e.g. under
    ///      `forge coverage` instrumentation).
    struct _CloseValues {
        int256 closeSize;
        uint256 closeCollateral;
        uint256 openingNotionalDelta;
        int256 realizedPnl;
        uint256 fee;
        uint256 lpRebate;
        uint256 insuranceShare;
        uint256 returned;
        bool isLong;
        bool fullClose;
    }

    /// @inheritdoc IPerpEngine
    function closePosition(CloseParams calldata p) external nonReentrant returns (int256 realizedPnl) {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        MarginStorage.Layout storage marginS = MarginStorage.load();

        if (perpS.globalHalt) revert GlobalHaltedError();
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        if (p.sizeFractionBps == 0 || p.sizeFractionBps > BPS_DENOMINATOR) {
            revert InvalidSizeFraction(p.sizeFractionBps);
        }

        bytes32 positionId = perpS.openPositionId[msg.sender][p.subjectId];
        if (positionId == bytes32(0)) revert PositionNotOpen(p.subjectId);

        // Closes are allowed during subject pauses (wind-down) — only globalHalt blocks them.
        uint256 markNow = _readFreshMark(perpS, p.subjectId);
        _checkSlippage(markNow, p.expectedMark, p.maxSlippageBps);

        Position memory orig = perpS.positions[positionId];
        _CloseValues memory v = _computeCloseValues(orig, markNow, p.sizeFractionBps, p.isMaker);

        // Update position state.
        if (v.fullClose) {
            delete perpS.positions[positionId];
            delete perpS.openPositionId[msg.sender][p.subjectId];
        } else {
            // Partial close locks in PnL via realizedPnl; entryPrice is unchanged so the residual
            // continues to reference the original entry.
            Position storage pos = perpS.positions[positionId];
            pos.size = orig.size - v.closeSize;
            pos.collateral = orig.collateral - v.closeCollateral;
            pos.lastInteractionAt = uint64(block.timestamp);
        }

        // OI + exposure deltas (always at OPENING notional — OI tracks contract count × open price).
        if (v.isLong) {
            perpS.totalLongOI[p.subjectId] -= v.openingNotionalDelta;
        } else {
            perpS.totalShortOI[p.subjectId] -= v.openingNotionalDelta;
        }
        marginS.exposure[msg.sender].totalPerpNotional -= v.openingNotionalDelta;

        ILPVault(perpS.lpVault).settlePosition(
            msg.sender, v.closeCollateral, v.realizedPnl, v.fee, v.lpRebate, v.insuranceShare
        );

        emit PositionClosed(positionId, msg.sender, p.subjectId, v.realizedPnl, v.fee, v.returned, v.fullClose);
        return v.realizedPnl;
    }

    function _computeCloseValues(
        Position memory orig,
        uint256 markNow,
        uint256 sizeFractionBps,
        bool isMaker
    )
        internal
        pure
        returns (_CloseValues memory v)
    {
        v.fullClose = sizeFractionBps == BPS_DENOMINATOR;
        v.isLong = orig.size > 0;

        if (v.fullClose) {
            v.closeSize = orig.size;
            v.closeCollateral = orig.collateral;
        } else {
            v.closeSize = (orig.size * int256(sizeFractionBps)) / int256(BPS_DENOMINATOR);
            v.closeCollateral = (orig.collateral * sizeFractionBps) / BPS_DENOMINATOR;
        }

        uint256 absCloseSize = v.closeSize > 0 ? uint256(v.closeSize) : uint256(-v.closeSize);
        v.openingNotionalDelta = (absCloseSize * orig.entryPrice) / ONE;
        uint256 closeNotionalAtMark = (absCloseSize * markNow) / ONE;
        v.realizedPnl = PositionMath.unrealizedPnl(v.closeSize, orig.entryPrice, markNow);

        (v.fee, v.lpRebate, v.insuranceShare) = _computeFees(closeNotionalAtMark, isMaker);

        // Underwater guard. v0 has no liquidation; voluntary close into negative equity reverts.
        int256 returnedSigned = int256(v.closeCollateral) + v.realizedPnl - int256(v.fee);
        if (returnedSigned < 0) revert UnderwaterClose(returnedSigned);
        v.returned = uint256(returnedSigned);
    }

    /// @inheritdoc IPerpEngine
    function addCollateral(bytes32 subjectId, uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.globalHalt) revert GlobalHaltedError();

        bytes32 positionId = perpS.openPositionId[msg.sender][subjectId];
        if (positionId == bytes32(0)) revert PositionNotOpen(subjectId);

        Position storage pos = perpS.positions[positionId];
        pos.collateral += amount;
        pos.lastInteractionAt = uint64(block.timestamp);

        ILPVault(perpS.lpVault).lockCollateral(msg.sender, amount);

        emit CollateralAdded(positionId, amount, pos.collateral);
    }

    /// @inheritdoc IPerpEngine
    function removeCollateral(bytes32 subjectId, uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();
        PerpStorage.Layout storage perpS = PerpStorage.load();
        MarginStorage.Layout storage marginS = MarginStorage.load();
        if (perpS.globalHalt) revert GlobalHaltedError();

        bytes32 positionId = perpS.openPositionId[msg.sender][subjectId];
        if (positionId == bytes32(0)) revert PositionNotOpen(subjectId);

        Position storage pos = perpS.positions[positionId];
        if (amount >= pos.collateral) revert AmountZero(); // can't remove all collateral

        // Need a fresh mark to recompute leverage + IM on the residual.
        uint256 markNow = _readFreshMark(perpS, subjectId);

        uint256 newCollateral = pos.collateral - amount;
        uint256 absSize = pos.size > 0 ? uint256(pos.size) : uint256(-pos.size);
        uint256 currentNotional = (absSize * markNow) / ONE;

        // Re-check leverage cap on the residual.
        uint256 leverageBps = (currentNotional * BPS_DENOMINATOR) / newCollateral;
        if (leverageBps > marginS.maxLeverageBps) {
            revert LeverageTooHigh(leverageBps, marginS.maxLeverageBps);
        }

        // Re-check initial margin (NOT maintenance — withdrawals must leave the position
        // genuinely safe, not just past the liquidation threshold).
        int256 uPnl = PositionMath.unrealizedPnl(pos.size, pos.entryPrice, markNow);
        int256 equity = int256(newCollateral) + uPnl;
        if (equity <= 0) revert MaintenanceMarginShort(marginS.maintenanceMarginBps, 0);
        uint256 marginRatioBps = (uint256(equity) * BPS_DENOMINATOR) / currentNotional;
        if (marginRatioBps < marginS.initialMarginBps) {
            revert InitialMarginShort((currentNotional * marginS.initialMarginBps) / BPS_DENOMINATOR, uint256(equity));
        }

        pos.collateral = newCollateral;
        pos.lastInteractionAt = uint64(block.timestamp);

        ILPVault(perpS.lpVault).releaseCollateral(msg.sender, amount);

        emit CollateralRemoved(positionId, amount, newCollateral);
    }

    // ------------------------------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------------------------------

    function _readFreshMark(
        PerpStorage.Layout storage perpS,
        bytes32 subjectId
    )
        internal
        view
        returns (uint256 markNow)
    {
        markNow = perpS.markPrice[subjectId];
        if (markNow == 0) revert MarkNotSet(subjectId);
        uint64 ts = perpS.markUpdatedAt[subjectId];
        if (block.timestamp > uint256(ts) + uint256(perpS.markStaleAfter)) {
            revert MarkStale(subjectId, ts);
        }
    }

    function _checkSlippage(uint256 markNow, uint256 expectedMark, uint256 maxSlippageBps) internal pure {
        if (expectedMark == 0) revert InvalidConfig();
        uint256 diff = markNow > expectedMark ? markNow - expectedMark : expectedMark - markNow;
        // diff × 10_000 ≤ maxSlippageBps × expectedMark
        if (diff * BPS_DENOMINATOR > maxSlippageBps * expectedMark) {
            revert SlippageExceeded(expectedMark, markNow, maxSlippageBps);
        }
    }

    function _enforceOpenCaps(
        PerpStorage.Layout storage perpS,
        MarginStorage.Layout storage marginS,
        bytes32 subjectId,
        Side side,
        uint256 sizeNotional,
        uint8 tier
    )
        internal
        view
    {
        // Per-subject side OI cap as a fraction of vault.totalAssets() (= freeAssets in our impl).
        uint256 vaultTvl = IERC4626(perpS.lpVault).totalAssets();
        uint256 sideOiCap = (vaultTvl * marginS.perSubjectSideOiCapBps) / BPS_DENOMINATOR;
        uint256 newSideOi = side == Side.LONG
            ? perpS.totalLongOI[subjectId] + sizeNotional
            : perpS.totalShortOI[subjectId] + sizeNotional;
        if (newSideOi > sideOiCap) {
            revert PerSubjectOiCapExceeded(subjectId, side, newSideOi, sideOiCap);
        }

        // Per-trader-per-subject cap. The one-position invariant means we know the trader has no
        // existing position on this subject, so the cap applies cleanly to `sizeNotional`.
        uint256 perSubjectCap = marginS.tierPerSubjectCap[MarginStorage.KycTier(tier)];
        if (sizeNotional > perSubjectCap) {
            revert PerTraderSubjectCapExceeded(msg.sender, subjectId, sizeNotional, perSubjectCap);
        }

        // Combined exposure cap.
        uint256 combinedCap = marginS.tierCombinedCap[MarginStorage.KycTier(tier)];
        uint256 newCombined = marginS.exposure[msg.sender].totalPerpNotional + sizeNotional;
        if (newCombined > combinedCap) revert CombinedExposureCapExceeded(msg.sender, newCombined, combinedCap);
    }

    function _computeFees(
        uint256 notional,
        bool isMaker
    )
        internal
        pure
        returns (uint256 fee, uint256 lpRebate, uint256 insuranceShare)
    {
        uint256 rate = isMaker ? MAKER_FEE_RATE : TAKER_FEE_RATE;
        fee = (notional * rate) / FEE_RATE_DENOM;
        lpRebate = (fee * LP_REBATE_PCT) / 100;
        insuranceShare = (fee * INSURANCE_PCT) / 100;
        // residual = fee − lpRebate − insuranceShare flows to vault.accruedFees in the vault
    }

    // ------------------------------------------------------------------------------------------
    // Permissioned writes
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    /// @dev Mark pushes are allowed regardless of subject status — a writer can record a price
    ///      observation even on a paused or delisting subject. State-changing trades gate the
    ///      mark via `_readFreshMark`.
    function pushMark(bytes32 subjectId, uint256 newMark) external {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (!perpS.markWriters[msg.sender]) revert Unauthorized(msg.sender);
        if (newMark < MIN_MARK || newMark > MAX_MARK) revert MarkValueOutOfRange(newMark);

        uint256 oldMark = perpS.markPrice[subjectId];
        perpS.markPrice[subjectId] = newMark;
        perpS.markUpdatedAt[subjectId] = uint64(block.timestamp);

        emit MarkPushed(subjectId, oldMark, newMark, uint64(block.timestamp));
    }

    /// @inheritdoc IPerpEngine
    function setGlobalHalt(bool halted) external onlyGovernance {
        PerpStorage.load().globalHalt = halted;
        emit GlobalHaltSet(halted);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: mark writer set
    //
    // Adds are timelocked (compromised governance can't immediately add a malicious writer).
    // Removes are immediate (compromised writer can be cut off without delay).
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    function proposeAddMarkWriter(address writer) external onlyGovernance {
        if (writer == address(0)) revert InvalidConfig();
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.markWriters[writer]) revert MarkWriterAlreadyAdded(writer);
        if (perpS.pendingMarkWriterActivatesAt[writer] != 0) revert PendingProposalExists();
        uint64 activatesAt = uint64(block.timestamp + perpS.timelockDelay);
        perpS.pendingMarkWriterActivatesAt[writer] = activatesAt;
        emit MarkWriterAddProposed(writer, activatesAt);
    }

    /// @inheritdoc IPerpEngine
    function activateAddMarkWriter(address writer) external {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        uint64 readyAt = perpS.pendingMarkWriterActivatesAt[writer];
        if (readyAt == 0) revert NoPendingProposal();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        delete perpS.pendingMarkWriterActivatesAt[writer];
        perpS.markWriters[writer] = true;
        emit MarkWriterAdded(writer);
    }

    /// @inheritdoc IPerpEngine
    function cancelAddMarkWriter(address writer) external onlyGovernance {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.pendingMarkWriterActivatesAt[writer] == 0) revert NoPendingProposal();
        delete perpS.pendingMarkWriterActivatesAt[writer];
        emit MarkWriterAddCancelled(writer);
    }

    /// @inheritdoc IPerpEngine
    function removeMarkWriter(address writer) external onlyGovernance {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (!perpS.markWriters[writer]) revert MarkWriterNotFound(writer);
        delete perpS.markWriters[writer];
        emit MarkWriterRemoved(writer);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: parameter setters
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    function setMarginParams(uint16 imBps, uint16 mmBps, uint16 bufBps, uint16 maxLevBps) external onlyGovernance {
        if (imBps == 0 || imBps > MAX_INITIAL_MARGIN_BPS) revert InvalidConfig();
        if (mmBps == 0 || mmBps > MAX_MAINTENANCE_MARGIN_BPS) revert InvalidConfig();
        if (bufBps > MAX_LIQ_BUFFER_BPS) revert InvalidConfig();
        if (maxLevBps == 0 || maxLevBps > MAX_LEVERAGE_BPS) revert InvalidConfig();
        // Logical ordering: maintenance < initial. A position must be insolvent at MM before
        // becoming insolvent at IM.
        if (mmBps >= imBps) revert InvalidConfig();

        MarginStorage.Layout storage marginS = MarginStorage.load();
        marginS.initialMarginBps = imBps;
        marginS.maintenanceMarginBps = mmBps;
        marginS.liquidationBufferBps = bufBps;
        marginS.maxLeverageBps = maxLevBps;
        emit MarginParamsSet(imBps, mmBps, bufBps, maxLevBps);
    }

    /// @inheritdoc IPerpEngine
    function setKycCaps(uint8 tier, uint256 perSubjectCap, uint256 combinedCap) external onlyGovernance {
        if (tier == 0 || tier > 3) revert KycTierInvalid(tier);
        if (perSubjectCap == 0 || combinedCap == 0) revert InvalidConfig();
        if (combinedCap < perSubjectCap) revert InvalidConfig();
        MarginStorage.Layout storage marginS = MarginStorage.load();
        MarginStorage.KycTier t = MarginStorage.KycTier(tier);
        marginS.tierPerSubjectCap[t] = perSubjectCap;
        marginS.tierCombinedCap[t] = combinedCap;
        emit KycCapsSet(tier, perSubjectCap, combinedCap);
    }

    /// @notice Governance setter for the per-subject side OI cap (basis points of vault TVL).
    function setPerSubjectSideOiCapBps(uint16 bps) external onlyGovernance {
        if (bps == 0 || bps > MAX_OI_CAP_BPS) revert InvalidConfig();
        MarginStorage.load().perSubjectSideOiCapBps = bps;
    }

    /// @inheritdoc IPerpEngine
    function setMarkStaleAfter(uint32 seconds_) external onlyGovernance {
        if (seconds_ < MIN_MARK_STALE_AFTER || seconds_ > MAX_MARK_STALE_AFTER) revert InvalidConfig();
        PerpStorage.load().markStaleAfter = seconds_;
        emit MarkStaleAfterSet(seconds_);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    function proposeGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidConfig();
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.pendingGovernanceActivatesAt != 0) revert PendingProposalExists();
        uint64 activatesAt = uint64(block.timestamp + perpS.timelockDelay);
        perpS.pendingGovernance = newGovernance;
        perpS.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGovernance, activatesAt);
    }

    /// @inheritdoc IPerpEngine
    function activateGovernanceTransfer() external {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        uint64 readyAt = perpS.pendingGovernanceActivatesAt;
        if (readyAt == 0) revert NoPendingProposal();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldGov = perpS.governance;
        address newGov = perpS.pendingGovernance;
        perpS.governance = newGov;
        delete perpS.pendingGovernance;
        delete perpS.pendingGovernanceActivatesAt;
        emit GovernanceTransferActivated(oldGov, newGov);
    }

    /// @inheritdoc IPerpEngine
    function cancelGovernanceTransfer() external onlyGovernance {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.pendingGovernanceActivatesAt == 0) revert NoPendingProposal();
        address pending = perpS.pendingGovernance;
        delete perpS.pendingGovernance;
        delete perpS.pendingGovernanceActivatesAt;
        emit GovernanceTransferCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    function positionOf(bytes32 positionId) external view returns (Position memory) {
        return PerpStorage.load().positions[positionId];
    }

    /// @inheritdoc IPerpEngine
    function positionIdOf(address trader, bytes32 subjectId) external view returns (bytes32) {
        return PerpStorage.load().openPositionId[trader][subjectId];
    }

    /// @inheritdoc IPerpEngine
    function markOf(bytes32 subjectId) external view returns (uint256 price, uint64 updatedAt) {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        return (perpS.markPrice[subjectId], perpS.markUpdatedAt[subjectId]);
    }

    /// @inheritdoc IPerpEngine
    function openInterestOf(bytes32 subjectId) external view returns (uint256 longOI, uint256 shortOI) {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        return (perpS.totalLongOI[subjectId], perpS.totalShortOI[subjectId]);
    }

    /// @inheritdoc IPerpEngine
    function equityOf(bytes32 positionId) external view returns (int256) {
        Position memory pos = PerpStorage.load().positions[positionId];
        if (pos.size == 0) return 0;
        uint256 markNow = PerpStorage.load().markPrice[pos.subjectId];
        if (markNow == 0) return int256(pos.collateral);
        int256 uPnl = PositionMath.unrealizedPnl(pos.size, pos.entryPrice, markNow);
        return PositionMath.equity(pos.collateral, uPnl);
    }

    /// @inheritdoc IPerpEngine
    function marginRatioBpsOf(bytes32 positionId) external view returns (uint256) {
        Position memory pos = PerpStorage.load().positions[positionId];
        if (pos.size == 0) return 0;
        uint256 markNow = PerpStorage.load().markPrice[pos.subjectId];
        if (markNow == 0) return 0;
        uint256 notional_ = PositionMath.notional(pos.size, markNow);
        int256 uPnl = PositionMath.unrealizedPnl(pos.size, pos.entryPrice, markNow);
        int256 eq = PositionMath.equity(pos.collateral, uPnl);
        return PositionMath.marginRatioBps(eq, notional_);
    }

    /// @inheritdoc IPerpEngine
    function leverageBpsOf(bytes32 positionId) external view returns (uint256) {
        Position memory pos = PerpStorage.load().positions[positionId];
        if (pos.size == 0 || pos.collateral == 0) return 0;
        uint256 markNow = PerpStorage.load().markPrice[pos.subjectId];
        if (markNow == 0) return 0;
        uint256 notional_ = PositionMath.notional(pos.size, markNow);
        return PositionMath.leverageBps(notional_, pos.collateral);
    }

    /// @inheritdoc IPerpEngine
    function isMarginOk(bytes32 positionId) external view returns (bool) {
        Position memory pos = PerpStorage.load().positions[positionId];
        if (pos.size == 0) return true;
        uint256 markNow = PerpStorage.load().markPrice[pos.subjectId];
        if (markNow == 0) return false;
        uint256 notional_ = PositionMath.notional(pos.size, markNow);
        int256 uPnl = PositionMath.unrealizedPnl(pos.size, pos.entryPrice, markNow);
        int256 eq = PositionMath.equity(pos.collateral, uPnl);
        uint256 ratio = PositionMath.marginRatioBps(eq, notional_);
        return ratio >= MarginStorage.load().maintenanceMarginBps;
    }

    /// @inheritdoc IPerpEngine
    function isMarkWriter(address account) external view returns (bool) {
        return PerpStorage.load().markWriters[account];
    }

    /// @inheritdoc IPerpEngine
    function globalHalt() external view returns (bool) {
        return PerpStorage.load().globalHalt;
    }

    /// @inheritdoc IPerpEngine
    function governance() external view returns (address) {
        return PerpStorage.load().governance;
    }

    /// @inheritdoc IPerpEngine
    function timelockDelay() external view returns (uint32) {
        return PerpStorage.load().timelockDelay;
    }

    /// @inheritdoc IPerpEngine
    function markStaleAfter() external view returns (uint32) {
        return PerpStorage.load().markStaleAfter;
    }

    function pendingMarkWriterActivatesAt(address writer) external view returns (uint64) {
        return PerpStorage.load().pendingMarkWriterActivatesAt[writer];
    }

    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        return (perpS.pendingGovernance, perpS.pendingGovernanceActivatesAt);
    }

    function lpVault() external view returns (address) {
        return PerpStorage.load().lpVault;
    }

    function subjectRegistry() external view returns (address) {
        return PerpStorage.load().subjectRegistry;
    }

    function marginParams()
        external
        view
        returns (uint16 imBps, uint16 mmBps, uint16 bufBps, uint16 maxLevBps, uint16 oiCapBps)
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

    function tierCaps(uint8 tier) external view returns (uint256 perSubjectCap, uint256 combinedCap) {
        MarginStorage.Layout storage marginS = MarginStorage.load();
        MarginStorage.KycTier t = MarginStorage.KycTier(tier);
        return (marginS.tierPerSubjectCap[t], marginS.tierCombinedCap[t]);
    }

    function exposureOf(address trader)
        external
        view
        returns (uint256 totalPerpNotional, uint256 totalEventExposure, uint8 tier)
    {
        MarginStorage.AccountExposure storage e = MarginStorage.load().exposure[trader];
        return (e.totalPerpNotional, e.totalEventExposure, uint8(e.tier));
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
