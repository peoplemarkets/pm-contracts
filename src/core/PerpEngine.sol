// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {FundingMath} from "../libraries/FundingMath.sol";
import {PerpInternals} from "../libraries/PerpInternals.sol";
import {PositionMath} from "../libraries/PositionMath.sol";
import {FundingStorage, PerpStorage} from "../libraries/StorageLib.sol";
import {ISubjectRegistry} from "../registry/ISubjectRegistry.sol";

import {ILPVault} from "./ILPVault.sol";
import {IMarginEngine} from "./IMarginEngine.sol";
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

    /// @dev Spec §3 fee split: 40% LP rebate (default; tunable via `setLpRebatePct` in [25, 50]),
    ///      50% insurance (pinned), residual = 100 - lpRebatePct - 50 to treasury (`accruedFees`).
    ///      `lpRebatePct` lives in storage; the spec's 40 → 30% LP-rebate decay over 6 months is
    ///      executed by governance ratcheting this value down.
    uint8 internal constant INSURANCE_PCT = 50;
    uint8 internal constant MIN_LP_REBATE_PCT = 25;
    uint8 internal constant MAX_LP_REBATE_PCT = 50;

    uint32 internal constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 internal constant MAX_TIMELOCK_DELAY = 30 days;

    uint32 internal constant MIN_MARK_STALE_AFTER = 5 seconds;
    uint32 internal constant MAX_MARK_STALE_AFTER = 1 hours;

    /// @dev Sanity bounds for mark prices. Anything outside this range is a misconfiguration.
    uint256 internal constant MIN_MARK = 1; // strictly positive
    uint256 internal constant MAX_MARK = 1e36; // 1e18 USDC × 1e18 fixed-point

    /// @dev Per-update mark max-delta (v2-audit Fix #5). Defaults to 1500 bps (15% per push) — a
    ///      generous bound that doesn't block legitimate volatility but caps the damage from a
    ///      single compromised mark-writer key. Governance can tune in [100, 5_000] bps.
    uint16 internal constant DEFAULT_MARK_MAX_DELTA_BPS = 1_500;
    uint16 internal constant MIN_MARK_MAX_DELTA_BPS = 100; // 1%
    uint16 internal constant MAX_MARK_MAX_DELTA_BPS = 5_000; // 50%

    /// @dev v2-audit Fix #3. Minimum interval between consecutive `pokeCappedTvl` calls. The
    ///      sole purpose is to defeat same-tx flash-deposit + open exploits — any non-zero
    ///      cooldown across `tx`-boundaries works since EVM transactions are atomic. 60 seconds
    ///      gives a clear human-readable buffer; first poke (when cappedTvlUpdatedAt == 0) is
    ///      uncooled to bootstrap.
    uint32 internal constant CAPPED_TVL_MIN_INTERVAL = 60 seconds;

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
        perpS.lpRebatePct = 40; // spec §3 starting value
        perpS.markMaxDeltaBps = DEFAULT_MARK_MAX_DELTA_BPS; // v2-audit Fix #5
            // Margin params + KYC caps + per-subject + per-category OI caps are now owned by the
            // MarginEngine namespace and seeded in `MarginEngine.initialize`. This contract no longer
            // touches MarginStorage on init.
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers (continued)
    // ------------------------------------------------------------------------------------------

    /// @dev Restricts to the configured FundingEngine. Reverts (with the caller address baked
    ///      into the error) if the writer is unset OR the caller is not the writer. Until
    ///      FundingEngine v1 ships, every `pushFundingIndex` call lands here and reverts.
    modifier onlyFundingEngine() {
        address writer = PerpStorage.load().fundingEngine;
        if (msg.sender != writer || writer == address(0)) revert OnlyFundingEngine(msg.sender);
        _;
    }

    /// @dev Same shape as `onlyFundingEngine`. Until the FeedbackController is wired in, every
    ///      `applyImpulse` call lands here and reverts.
    modifier onlyFeedbackController() {
        address writer = PerpStorage.load().feedbackController;
        if (msg.sender != writer || writer == address(0)) revert OnlyFeedbackController(msg.sender);
        _;
    }

    /// @dev Wave 5B. Gates `liquidateClose` to the configured LiquidationEngine. Until the
    ///      rotation activates, the writer is `address(0)` and every call reverts.
    modifier onlyLiquidationEngine() {
        address writer = PerpStorage.load().liquidationEngine;
        if (msg.sender != writer || writer == address(0)) revert OnlyLiquidationEngine(msg.sender);
        _;
    }

    /// @dev Wave 7. Gates `openPositionFor` to the trusted-router set. Adds are timelocked,
    ///      removes are immediate (same shape as `markWriters`). Until governance registers a
    ///      router, every call lands here and reverts.
    modifier onlyRouter() {
        if (!PerpStorage.load().routers[msg.sender]) revert OnlyRouter(msg.sender);
        _;
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
        return _openPositionFor(msg.sender, p);
    }

    /// @inheritdoc IPerpEngine
    /// @dev Wave 7. Trusted-router entrypoint. Body is identical to `openPosition` but the
    ///      acting trader is the `trader` parameter rather than `msg.sender`. The trader still
    ///      must have approved the LPVault for `collateralAmount + fee`; the router never holds
    ///      funds. Routers are timelocked-added and immediately removable via governance.
    function openPositionFor(
        address trader,
        OpenParams calldata p
    )
        external
        nonReentrant
        onlyRouter
        returns (bytes32 positionId)
    {
        if (trader == address(0)) revert InvalidConfig();
        return _openPositionFor(trader, p);
    }

    /// @dev Shared open-path implementation. Both `openPosition` (where `trader == msg.sender`)
    ///      and `openPositionFor` (where `trader` is supplied by a trusted router) delegate here
    ///      so the open-side semantics stay in lockstep.
    function _openPositionFor(address trader, OpenParams calldata p) internal returns (bytes32 positionId) {
        PerpStorage.Layout storage perpS = PerpStorage.load();

        if (perpS.globalHalt) revert GlobalHaltedError();
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        if (p.collateralAmount == 0 || p.sizeNotional == 0) revert AmountZero();

        // Subject + KYC gate — registry's requireTradeable reverts on UNREGISTERED, paused,
        // delisted, or any policy flag.
        ISubjectRegistry(perpS.subjectRegistry).requireTradeable(p.subjectId);
        uint8 tier = ISubjectRegistry(perpS.subjectRegistry).kycTierOf(trader);
        if (tier == 0) revert KycTierMissing(trader);

        uint256 markNow = _readFreshMark(perpS, p.subjectId);
        _checkSlippage(markNow, p.expectedMark, p.maxSlippageBps);

        // One-position-per-(trader, subject) invariant.
        if (perpS.openPositionId[trader][p.subjectId] != bytes32(0)) {
            revert PositionAlreadyOpen(trader, p.subjectId);
        }

        // Margin + cap checks — delegated to MarginEngine. The two calls below revert with the
        // MarginEngine-side error variants (LeverageTooHigh, InitialMarginShort, PerSubjectOiCap...)
        // matching the legacy reverts byte-for-byte from the caller's perspective.
        IMarginEngine me = IMarginEngine(perpS.marginEngine);
        if (address(me) == address(0)) revert MarginEngineUnset();
        me.checkInitialMargin(p.sizeNotional, p.collateralAmount);
        bytes32 categoryId = _categoryOf(perpS, p.subjectId);
        _enforceOpenCaps(me, perpS, trader, p.subjectId, categoryId, p.side, p.sizeNotional, tier);

        // Compute fee + split.
        (uint256 fee, uint256 lpRebate, uint256 insuranceShare) = _computeFees(p.sizeNotional, p.isMaker);

        // Compute signed size in base units. Bound check: sizeNotional × ONE fits since
        // sizeNotional ≤ tier cap (max ≈ 1e6 USDC × 1e18 = 1e24 — safe).
        int256 absSize = int256((p.sizeNotional * ONE) / markNow);
        int256 signedSize = p.side == Side.LONG ? absSize : -absSize;

        // Allocate positionId from monotonic nonce.
        unchecked {
            positionId = keccak256(abi.encode(trader, p.subjectId, perpS.nextPositionNonce++));
        }

        // Tier-1 funding event stub: snapshot the cumulative funding index at open. The math is
        // not applied in v0 (no per-position settle yet) — capturing the snapshot now means
        // FundingEngine v1 can compute (currentIndex − entryFundingIndex) × size without a
        // storage migration.
        int256 entryFundingIndex = FundingStorage.load().cumulativeFundingIndex[p.subjectId];

        // Write position.
        perpS.positions[positionId] = Position({
            size: signedSize,
            collateral: p.collateralAmount,
            entryPrice: markNow,
            entryFundingIndex: entryFundingIndex,
            openedAt: uint64(block.timestamp),
            lastInteractionAt: uint64(block.timestamp),
            owner: trader,
            subjectId: p.subjectId
        });
        perpS.openPositionId[trader][p.subjectId] = positionId;

        // OI side-counters live on PerpStorage. Signed per-category OI + per-trader exposure live
        // on MarginEngine — delegate the update so the canonical state stays in one place.
        if (p.side == Side.LONG) {
            perpS.totalLongOI[p.subjectId] += p.sizeNotional;
        } else {
            perpS.totalShortOI[p.subjectId] += p.sizeNotional;
        }
        me.recordOpenDelta(trader, categoryId, IMarginEngine.Side(uint8(p.side)), p.sizeNotional, tier);

        // Vault settle: pull (collateralAmount + fee) from trader, book the split. The trader
        // (not the router or msg.sender) is the funds source — they must have pre-approved the
        // LPVault for `collateralAmount + fee`.
        ILPVault(perpS.lpVault).openPositionFlow(trader, p.collateralAmount, fee, lpRebate, insuranceShare);

        emit PositionOpened(positionId, trader, p.subjectId, p.side, signedSize, markNow, p.collateralAmount, fee);
    }

    /// @dev Local-only struct used to thread close-flow values out of the helper. Keeps
    ///      `closePosition` under solc's stack-depth bound when via-IR is disabled (e.g. under
    ///      `forge coverage` instrumentation).
    struct _CloseValues {
        int256 closeSize;
        uint256 closeCollateral;
        uint256 openingNotionalDelta;
        int256 realizedPnl;
        // Funding debt settled on the closed slice. Signed, 6-decimal USDC: positive = trader OWES
        // funding (deducted from payout, credited to the LP vault); negative = trader RECEIVES
        // funding (added to payout, debited from the LP vault). Computed from the cumulative
        // funding index delta (currentIndex − entryFundingIndex) via `FundingMath.computeFundingDebt`.
        int256 fundingDebt6;
        // PnL leg actually booked to the vault on settle: `realizedPnl − fundingDebt6`. Folding
        // funding into the vault's signed-pnl leg keeps a single settlement primitive (the vault is
        // the universal counterparty), so funding paid by traders accrues to LP `freeAssets` and
        // funding owed to traders is paid out of it.
        int256 settlePnl;
        uint256 fee;
        uint256 lpRebate;
        uint256 insuranceShare;
        uint256 returned;
        bool isLong;
        bool fullClose;
    }

    /// @inheritdoc IPerpEngine
    function closePosition(CloseParams calldata p) external nonReentrant returns (int256 realizedPnl) {
        return _closePositionFor(msg.sender, p);
    }

    /// @inheritdoc IPerpEngine
    /// @dev Wave 6C. Trusted-router entrypoint. Body delegates to the same internal helper used by
    ///      `closePosition` with `trader` replacing `msg.sender`. Caller MUST be a registered router.
    ///      Zero-trader is implicitly rejected: `openPositionId[address(0)][...]` is always zero,
    ///      so the `PositionNotOpen` revert in the shared helper handles it.
    function closePositionFor(
        address trader,
        CloseParams calldata p
    )
        external
        nonReentrant
        onlyRouter
        returns (int256 realizedPnl)
    {
        return _closePositionFor(trader, p);
    }

    /// @dev Shared close-path implementation. Both `closePosition` and `closePositionFor` route
    ///      here so semantics stay in lockstep.
    function _closePositionFor(address trader, CloseParams calldata p) internal returns (int256 realizedPnl) {
        PerpStorage.Layout storage perpS = PerpStorage.load();

        if (perpS.globalHalt) revert GlobalHaltedError();
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        if (p.sizeFractionBps == 0 || p.sizeFractionBps > BPS_DENOMINATOR) {
            revert InvalidSizeFraction(p.sizeFractionBps);
        }
        // Once a subject has been force-settled, the canonical price is captured. Trades against
        // the live mark are no longer meaningful — traders must use `closeAtForcedSettlement`.
        if (perpS.subjectForceSettled[p.subjectId]) revert SubjectIsForceSettled(p.subjectId);

        bytes32 positionId = perpS.openPositionId[trader][p.subjectId];
        if (positionId == bytes32(0)) revert PositionNotOpen(p.subjectId);

        // Closes are allowed during subject pauses (wind-down) — only globalHalt blocks them.
        uint256 markNow = _readFreshMark(perpS, p.subjectId);
        _checkSlippage(markNow, p.expectedMark, p.maxSlippageBps);

        Position memory orig = perpS.positions[positionId];
        // Funding settlement (Tier-1): the cumulative funding index is the single source of truth,
        // pushed by FundingEngine via `pushFundingIndex` and frozen during pauses. We settle funding
        // on the CLOSED SLICE only; the residual keeps its original `entryFundingIndex`, so funding
        // that accrued over the residual's lifetime is settled in full at its own eventual close —
        // no double counting, no missed accrual.
        int256 currentFundingIndex = FundingStorage.load().cumulativeFundingIndex[p.subjectId];
        _CloseValues memory v = _computeCloseValues(orig, markNow, p.sizeFractionBps, p.isMaker, currentFundingIndex);

        // Update position state.
        if (v.fullClose) {
            delete perpS.positions[positionId];
            delete perpS.openPositionId[trader][p.subjectId];
        } else {
            // Partial close locks in PnL via realizedPnl; entryPrice is unchanged so the residual
            // continues to reference the original entry.
            Position storage pos = perpS.positions[positionId];
            pos.size = orig.size - v.closeSize;
            pos.collateral = orig.collateral - v.closeCollateral;
            pos.lastInteractionAt = uint64(block.timestamp);
        }

        // OI side-counters on PerpStorage. Signed per-category OI + per-trader exposure live on
        // MarginEngine — delegate the unwind. OI deltas use OPENING notional throughout.
        if (v.isLong) {
            perpS.totalLongOI[p.subjectId] -= v.openingNotionalDelta;
        } else {
            perpS.totalShortOI[p.subjectId] -= v.openingNotionalDelta;
        }
        // marginEngine MAY be unset (legacy positions opened before Wave 4 rotation). Guard so
        // close paths stay alive on a partially-wired engine — opens are blocked by the unset
        // pointer, but unwinds must always succeed.
        if (perpS.marginEngine != address(0)) {
            IMarginEngine(perpS.marginEngine).recordCloseDelta(
                trader, _categoryOf(perpS, p.subjectId), v.openingNotionalDelta, v.isLong
            );
        }

        // Settle the closed slice against the vault. The pnl leg is `realizedPnl − fundingDebt6`
        // (funding folded in — see `_CloseValues.settlePnl`). Fees are unchanged; funding is NOT
        // a fee and does not route through the lpRebate/insurance split.
        ILPVault(perpS.lpVault).settlePosition(
            trader, v.closeCollateral, v.settlePnl, v.fee, v.lpRebate, v.insuranceShare
        );

        // Funding settled on the closed slice. `fundingDebt6 > 0` ⇒ trader paid funding into the
        // vault; `< 0` ⇒ trader received funding from the vault. Reported separately from the
        // trading PnL (`PositionClosed.realizedPnl`) so indexers can decompose the two.
        emit FundingSettled(positionId, trader, v.fundingDebt6);
        // `v.closeSize` is the SIGNED slice actually closed (full size on a full close, the
        // pro-rata slice on a partial close); `v.isLong` is the position side. See IPerpEngine —
        // appending these fields is a BREAKING event-signature change for off-chain decoders.
        emit PositionClosed(
            positionId, trader, p.subjectId, v.realizedPnl, v.fee, v.returned, v.fullClose, v.closeSize, v.isLong
        );
        return v.realizedPnl;
    }

    function _computeCloseValues(
        Position memory orig,
        uint256 markNow,
        uint256 sizeFractionBps,
        bool isMaker,
        int256 currentFundingIndex
    )
        internal
        view
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

        // Funding debt on the closed slice. `computeFundingDebt = closeSize × (currentIndex −
        // entryIndex) / 1e18`. Sign: long + index-grew ⇒ pays; short + index-grew ⇒ receives.
        // The `settlePnl` leg folds funding into the vault settlement.
        v.fundingDebt6 = FundingMath.computeFundingDebt(v.closeSize, currentFundingIndex, orig.entryFundingIndex);
        v.settlePnl = v.realizedPnl - v.fundingDebt6;

        // Underwater guard. Voluntary close into negative equity (after funding) reverts — the
        // LiquidationEngine waterfall is the only path that clears a position whose equity cannot
        // cover its obligations. Funding is included so a position pushed underwater purely by
        // accrued funding debt cannot be voluntarily closed at the vault's expense.
        int256 returnedSigned = int256(v.closeCollateral) + v.settlePnl - int256(v.fee);
        if (returnedSigned < 0) revert UnderwaterClose(returnedSigned);
        v.returned = uint256(returnedSigned);
    }

    /// @inheritdoc IPerpEngine
    /// @dev Spec §6 line 367/369: forced settlement at last fair mark on death/incapacitation
    ///      (oracle-confirmed) or involuntary delisting (legal/regulatory). v0 SHIM: governance
    ///      captures the mark; traders subsequently call `closeAtForcedSettlement` to claim.
    ///      No on-chain iteration over open positions; ADL queueing is week 14+ (LiquidationEngine).
    ///
    /// @dev Subject status MUST be DELISTED. The two-step pattern (registry sets DELISTED via
    ///      `confirmDeath` / `forceSettle` / `involuntaryDelist`, then engine `forceSettleSubject`)
    ///      keeps the audit trail clean and avoids cross-contract reads of registry-internal state.
    function forceSettleSubject(bytes32 subjectId, uint256 settlementMark) external onlyGovernance {
        if (settlementMark < MIN_MARK || settlementMark > MAX_MARK) {
            revert MarkValueOutOfRange(settlementMark);
        }
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.subjectForceSettled[subjectId]) revert SubjectAlreadyForceSettled(subjectId);
        ISubjectRegistry.SubjectStatus status = ISubjectRegistry(perpS.subjectRegistry).statusOf(subjectId);
        if (status != ISubjectRegistry.SubjectStatus.DELISTED) revert SubjectNotDelisted(subjectId);

        perpS.subjectSettlementMark[subjectId] = settlementMark;
        perpS.subjectForceSettled[subjectId] = true;
        emit SubjectForceSettled(subjectId, settlementMark, msg.sender);
    }

    /// @inheritdoc IPerpEngine
    /// @dev Permissionless: any caller with an open position on a force-settled subject can claim.
    ///      Forced full close at the captured mark. ZERO fee — venue obligation, not discretionary
    ///      trade. Skips staleness (the captured mark is canonical from `forceSettleSubject` time).
    ///      Not gated by `globalHalt` — once a subject is force-settled, the trader has a vested
    ///      right to the captured-mark unwind regardless of broader system state.
    function closeAtForcedSettlement(bytes32 subjectId) external nonReentrant returns (int256 realizedPnl) {
        // Body extracted to `PerpInternals.forceSettlementClose` (DELEGATECALL) to keep this
        // contract under the 24,576-byte EIP-170 cap. Namespaced storage + msg.sender resolve
        // unchanged. Settles funding accrued up to the freeze and caps the trader's loss at
        // posted collateral.
        return PerpInternals.forceSettlementClose(subjectId, msg.sender);
    }

    /// @inheritdoc IPerpEngine
    function addCollateral(bytes32 subjectId, uint256 amount) external nonReentrant {
        _addCollateralFor(msg.sender, subjectId, amount);
    }

    /// @inheritdoc IPerpEngine
    /// @dev Wave 6C. Trusted-router entrypoint. `positionId` MUST be owned by `trader`.
    function addCollateralFor(address trader, bytes32 positionId, uint256 amount) external nonReentrant onlyRouter {
        _addCollateralFor(trader, _subjectIdForOwner(trader, positionId), amount);
    }

    /// @dev Shared add-collateral helper. `subjectId` looks up the open position for `trader`.
    function _addCollateralFor(address trader, bytes32 subjectId, uint256 amount) internal {
        if (amount == 0) revert AmountZero();
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.globalHalt) revert GlobalHaltedError();
        if (perpS.subjectForceSettled[subjectId]) revert SubjectIsForceSettled(subjectId);

        bytes32 positionId = perpS.openPositionId[trader][subjectId];
        if (positionId == bytes32(0)) revert PositionNotOpen(subjectId);

        Position storage pos = perpS.positions[positionId];
        pos.collateral += amount;
        pos.lastInteractionAt = uint64(block.timestamp);

        ILPVault(perpS.lpVault).lockCollateral(trader, amount);

        emit CollateralAdded(positionId, amount, pos.collateral);
    }

    /// @inheritdoc IPerpEngine
    function removeCollateral(bytes32 subjectId, uint256 amount) external nonReentrant {
        _removeCollateralFor(msg.sender, subjectId, amount);
    }

    /// @inheritdoc IPerpEngine
    /// @dev Wave 6C. Trusted-router entrypoint. `positionId` MUST be owned by `trader`.
    function removeCollateralFor(address trader, bytes32 positionId, uint256 amount) external nonReentrant onlyRouter {
        _removeCollateralFor(trader, _subjectIdForOwner(trader, positionId), amount);
    }

    /// @dev Resolve `positionId`'s subject and reject mismatches (positionId not owned by
    ///      `trader` or pointing at a closed slot). Shared between router add/remove paths so
    ///      both reuse a single revert site.
    function _subjectIdForOwner(address trader, bytes32 positionId) internal view returns (bytes32) {
        Position storage pos = PerpStorage.load().positions[positionId];
        bytes32 subjectId = pos.subjectId;
        if (pos.owner != trader || pos.size == 0) revert PositionNotOpen(subjectId);
        return subjectId;
    }

    /// @dev Shared remove-collateral helper. Recomputes IM on the residual so withdrawals never
    ///      leave a position teetering above maintenance margin.
    function _removeCollateralFor(address trader, bytes32 subjectId, uint256 amount) internal {
        if (amount == 0) revert AmountZero();
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.globalHalt) revert GlobalHaltedError();
        if (perpS.subjectForceSettled[subjectId]) revert SubjectIsForceSettled(subjectId);

        bytes32 positionId = perpS.openPositionId[trader][subjectId];
        if (positionId == bytes32(0)) revert PositionNotOpen(subjectId);

        Position storage pos = perpS.positions[positionId];
        if (amount >= pos.collateral) revert AmountZero(); // can't remove all collateral

        // Need a fresh mark to recompute leverage + IM on the residual.
        uint256 markNow = _readFreshMark(perpS, subjectId);

        uint256 newCollateral = pos.collateral - amount;
        uint256 absSize = pos.size > 0 ? uint256(pos.size) : uint256(-pos.size);
        uint256 currentNotional = (absSize * markNow) / ONE;

        // Negative-equity short-circuit: emits the dedicated MaintenanceMarginShort selector to
        // preserve the pre-extraction error trail. Other IM/leverage failures route through
        // MarginEngine.checkInitialMarginResidual which mirrors the legacy selectors.
        int256 uPnl = PositionMath.unrealizedPnl(pos.size, pos.entryPrice, markNow);
        if (int256(newCollateral) + uPnl <= 0) revert MaintenanceMarginShort(0, 0);

        // Re-check leverage + IM on the residual via MarginEngine. NOT maintenance — withdrawals
        // must leave the position genuinely safe, not just past the liquidation threshold.
        address me = perpS.marginEngine;
        if (me == address(0)) revert MarginEngineUnset();
        IMarginEngine(me).checkInitialMarginResidual(newCollateral, currentNotional, uPnl);

        pos.collateral = newCollateral;
        pos.lastInteractionAt = uint64(block.timestamp);

        ILPVault(perpS.lpVault).releaseCollateral(trader, amount);

        emit CollateralRemoved(positionId, amount, newCollateral);
    }

    // ------------------------------------------------------------------------------------------
    // LiquidationEngine entrypoint
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    /// @dev Wave 5B. The LiquidationEngine has already computed the close shape via
    ///      `LiquidationMath` and (where relevant) pre-funded the LPVault by drawing
    ///      `InsuranceFund` for any shortfall. This call atomically:
    ///        1. Validates `sizeToClose` sign + magnitude against the stored position.
    ///        2. Decrements or deletes the position (per-trader-per-subject index too).
    ///        3. Decrements OI counters by the OPENING notional contribution being unwound.
    ///        4. Forwards a 3-way settle through `LPVault.settlePosition` — trader gets
    ///           `collateralToReturn`, liquidator gets `bountyToPay`, and the slice's
    ///           `signedPnl` is booked to the LP / insurance side.
    ///      The vault's `UnderwaterClose` guard fires if `collateralReleased + pnl - fee < 0`
    ///      (fee == bounty here). LiquidationEngine sizes the bounty to never trip that guard.
    function liquidateClose(
        bytes32 positionId,
        int256 sizeToClose,
        uint256 collateralToReturn,
        uint256 bountyToPay,
        int256 signedPnl,
        address liquidator,
        uint8 tierCode
    )
        external
        nonReentrant
        onlyLiquidationEngine
    {
        // Body extracted to `PerpInternals.liquidateClose` to keep this contract under the
        // 24,576-byte EIP-170 runtime cap. Public library function is linked at deploy and
        // entered via DELEGATECALL — namespaced storage + msg.sender resolve unchanged.
        PerpInternals.liquidateClose(
            positionId, sizeToClose, collateralToReturn, bountyToPay, signedPnl, liquidator, tierCode
        );
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

    /// @dev Delegates the cap enforcement to MarginEngine. PerpEngine computes the cap
    ///      denominator (`min(cappedTvl, liveTvl)` — v2-audit Fix #3) locally so MarginEngine
    ///      does not need a back-pointer to the LP vault. The signed-OI accumulator + side
    ///      counters are read from PerpStorage and passed through.
    function _enforceOpenCaps(
        IMarginEngine me,
        PerpStorage.Layout storage perpS,
        address trader,
        bytes32 subjectId,
        bytes32 categoryId,
        Side side,
        uint256 sizeNotional,
        uint8 tier
    )
        internal
        view
    {
        uint256 liveTvl = IERC4626(perpS.lpVault).totalAssets();
        uint256 vaultTvl = perpS.cappedTvl < liveTvl ? perpS.cappedTvl : liveTvl;
        me.enforceOpenCaps(
            trader,
            subjectId,
            categoryId,
            IMarginEngine.Side(uint8(side)),
            sizeNotional,
            tier,
            perpS.totalLongOI[subjectId],
            perpS.totalShortOI[subjectId],
            vaultTvl
        );
    }

    /// @dev Look up the category for `subjectId` from the registry. Wrapped in a private helper
    ///      to keep the open/close paths terse and to make the cross-contract read explicit.
    function _categoryOf(PerpStorage.Layout storage perpS, bytes32 subjectId) internal view returns (bytes32) {
        return ISubjectRegistry(perpS.subjectRegistry).subjectOf(subjectId).categoryId;
    }

    function _computeFees(
        uint256 notional,
        bool isMaker
    )
        internal
        view
        returns (uint256 fee, uint256 lpRebate, uint256 insuranceShare)
    {
        uint256 rate = isMaker ? MAKER_FEE_RATE : TAKER_FEE_RATE;
        fee = (notional * rate) / FEE_RATE_DENOM;
        // lpRebatePct lives in storage so governance can ratchet 40% → 30% per spec §3 line 139.
        lpRebate = (fee * uint256(PerpStorage.load().lpRebatePct)) / 100;
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
    /// @dev v2-audit Fix #5: per-update max-delta cap. The first push for a subject (oldMark == 0)
    ///      is uncapped — there is no prior reference point. Subsequent pushes must satisfy
    ///      |newMark − oldMark| × 10_000 ≤ markMaxDeltaBps × oldMark, bounding the damage from a
    ///      single compromised mark-writer key. Legitimate volatility above the cap requires
    ///      multiple successive pushes (each within the cap), spread across blocks.
    function pushMark(bytes32 subjectId, uint256 newMark) external {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (!perpS.markWriters[msg.sender]) revert Unauthorized(msg.sender);
        if (newMark < MIN_MARK || newMark > MAX_MARK) revert MarkValueOutOfRange(newMark);

        uint256 oldMark = perpS.markPrice[subjectId];
        if (oldMark != 0) {
            uint256 diff = newMark > oldMark ? newMark - oldMark : oldMark - newMark;
            uint16 capBps = perpS.markMaxDeltaBps;
            if (diff * BPS_DENOMINATOR > uint256(capBps) * oldMark) {
                revert MarkDeltaTooLarge(subjectId, oldMark, newMark, capBps);
            }
        }

        perpS.markPrice[subjectId] = newMark;
        perpS.markUpdatedAt[subjectId] = uint64(block.timestamp);

        emit MarkPushed(subjectId, oldMark, newMark, uint64(block.timestamp));
    }

    /// @inheritdoc IPerpEngine
    /// @dev Tier-1 funding event stub. FundingEngine v1 will call this once per accrual interval
    ///      per subject. The engine writes the new index + last-accrued timestamp and emits the
    ///      event so indexers can compute realized funding off-chain. Pauses freeze funding per
    ///      spec §2 line 66 — we route through `requireTradeable` to share the existing
    ///      pause-state semantics (status == ACTIVE, no policy flag).
    function pushFundingIndex(bytes32 subjectId, int256 newIndex, int256 fundingRate1e18) external onlyFundingEngine {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        ISubjectRegistry(perpS.subjectRegistry).requireTradeable(subjectId);

        FundingStorage.Layout storage fundingS = FundingStorage.load();
        int256 oldIndex = fundingS.cumulativeFundingIndex[subjectId];
        fundingS.cumulativeFundingIndex[subjectId] = newIndex;
        fundingS.lastFundingAt[subjectId] = uint64(block.timestamp);

        emit FundingPushed(subjectId, oldIndex, newIndex, fundingRate1e18, uint64(block.timestamp));
    }

    /// @inheritdoc IPerpEngine
    /// @dev Wave 3B FeedbackController hook. Multiplies the current mark by
    ///      `(BPS_DENOMINATOR + impulseBps) / BPS_DENOMINATOR`. Caller MUST be the configured
    ///      FeedbackController; the subject MUST be tradeable so spec §3 line 173
    ///      ("no event-impulse application during pauses") holds.
    ///
    /// @dev No per-update delta-cap check here — the FeedbackController's own ±15% impulse cap
    ///      is the controlling lever. The `markMaxDeltaBps` field bounds live mark-writer
    ///      pushes (which use a separate channel via `pushMark`); applying that cap here would
    ///      double-bound a path that is already constrained.
    ///
    /// @dev First-ever push for a subject (mark == 0) reverts: applying a multiplicative impulse
    ///      to an uninitialized mark would still leave it at zero and silently drop the bump.
    function applyImpulse(bytes32 subjectId, int256 impulseBps) external onlyFeedbackController {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        ISubjectRegistry(perpS.subjectRegistry).requireTradeable(subjectId);

        uint256 oldMark = perpS.markPrice[subjectId];
        if (oldMark == 0) revert MarkNotInitialized(subjectId);

        // newMark = oldMark × (BPS + impulseBps) / BPS. The multiplier is signed; for
        // `impulseBps = -BPS_DENOMINATOR` it is zero and we revert as ImpulseUnderflow. For
        // anything more negative it would be negative — also caught by the underflow guard.
        int256 multiplier = int256(BPS_DENOMINATOR) + impulseBps;
        int256 newMarkSigned = (int256(oldMark) * multiplier) / int256(BPS_DENOMINATOR);
        if (newMarkSigned <= 0) revert ImpulseUnderflow();
        uint256 newMark = uint256(newMarkSigned);

        perpS.markPrice[subjectId] = newMark;
        perpS.markUpdatedAt[subjectId] = uint64(block.timestamp);

        emit MarkImpulsed(subjectId, oldMark, newMark, impulseBps, uint64(block.timestamp));
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
    // Governance: trusted-router set (Wave 7)
    //
    // Mirrors the mark-writer pattern: adds timelocked, removes immediate. Routers gain access
    // to `openPositionFor` on activation; a compromised router is cut off without delay via
    // `removeRouter`.
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    function proposeAddRouter(address router) external onlyGovernance {
        if (router == address(0)) revert InvalidConfig();
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.routers[router]) revert RouterAlreadySet(router);
        if (perpS.pendingRouterActivatesAt[router] != 0) revert PendingRouterExists(router);
        uint64 activatesAt = uint64(block.timestamp + perpS.timelockDelay);
        perpS.pendingRouterActivatesAt[router] = activatesAt;
        emit RouterProposed(router, activatesAt);
    }

    /// @inheritdoc IPerpEngine
    function activateAddRouter(address router) external {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        uint64 readyAt = perpS.pendingRouterActivatesAt[router];
        if (readyAt == 0) revert NoPendingRouter(router);
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        delete perpS.pendingRouterActivatesAt[router];
        perpS.routers[router] = true;
        emit RouterActivated(router);
    }

    /// @inheritdoc IPerpEngine
    function cancelAddRouter(address router) external onlyGovernance {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.pendingRouterActivatesAt[router] == 0) revert NoPendingRouter(router);
        delete perpS.pendingRouterActivatesAt[router];
        emit RouterCancelled(router);
    }

    /// @inheritdoc IPerpEngine
    function removeRouter(address router) external onlyGovernance {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (!perpS.routers[router]) revert RouterNotSet(router);
        delete perpS.routers[router];
        emit RouterRemoved(router);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: parameter setters
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    function setMarkStaleAfter(uint32 seconds_) external onlyGovernance {
        if (seconds_ < MIN_MARK_STALE_AFTER || seconds_ > MAX_MARK_STALE_AFTER) revert InvalidConfig();
        PerpStorage.load().markStaleAfter = seconds_;
        emit MarkStaleAfterSet(seconds_);
    }

    /// @inheritdoc IPerpEngine
    /// @dev v2-audit Fix #3. Permissionless — anyone can poke after the cooldown elapses. The
    ///      OI cap reads `min(cappedTvl, freeAssets())` so a same-block flash deposit that
    ///      inflates `freeAssets` does not raise the cap (cappedTvl is unchanged), and a sudden
    ///      withdrawal that drops `freeAssets` does immediately tighten the cap.
    function pokeCappedTvl() external {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        uint64 lastUpdate = perpS.cappedTvlUpdatedAt;
        if (lastUpdate != 0) {
            uint64 readyAt = lastUpdate + uint64(CAPPED_TVL_MIN_INTERVAL);
            if (block.timestamp < readyAt) revert CappedTvlPokeTooSoon(readyAt);
        }
        uint256 newTvl = IERC4626(perpS.lpVault).totalAssets();
        perpS.cappedTvl = newTvl;
        perpS.cappedTvlUpdatedAt = uint64(block.timestamp);
        emit CappedTvlPoked(newTvl, msg.sender);
    }

    /// @inheritdoc IPerpEngine
    /// @dev v2-audit Fix #5. Bounds [100, 5_000] bps (1% to 50% per push). Default 1500 (15%).
    function setMarkMaxDeltaBps(uint16 bps) external onlyGovernance {
        if (bps < MIN_MARK_MAX_DELTA_BPS || bps > MAX_MARK_MAX_DELTA_BPS) {
            revert MarkMaxDeltaBpsOutOfRange(bps);
        }
        PerpStorage.Layout storage perpS = PerpStorage.load();
        uint16 old = perpS.markMaxDeltaBps;
        perpS.markMaxDeltaBps = bps;
        emit MarkMaxDeltaBpsSet(old, bps);
    }

    /// @inheritdoc IPerpEngine
    /// @dev Spec §3 line 139: LP rebate decreases from 40% to 30% over 6 months. Encoded as a
    ///      governance setter rather than a fixed time-curve so the operations multi-sig can
    ///      calibrate from yield trajectory (spec §7 line 417). Bounds [25, 50] prevent obvious
    ///      mis-set; the upper bound matches `INSURANCE_PCT` so residual stays ≥ 0.
    function setLpRebatePct(uint8 pct) external onlyGovernance {
        if (pct < MIN_LP_REBATE_PCT || pct > MAX_LP_REBATE_PCT) revert LpRebatePctOutOfRange(pct);
        PerpStorage.Layout storage perpS = PerpStorage.load();
        uint8 old = perpS.lpRebatePct;
        perpS.lpRebatePct = pct;
        emit LpRebatePctSet(old, pct);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: FundingEngine writer rotation (timelocked)
    //
    // Same shape as `proposeSetPerpEngine` on LPVault. Until FundingEngine v1 ships, the writer
    // stays at `address(0)` and `pushFundingIndex` reverts.
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    function proposeSetFundingEngine(address newEngine) external onlyGovernance {
        if (newEngine == address(0)) revert InvalidConfig();
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.pendingFundingEngineActivatesAt != 0) revert PendingFundingEngineExists();
        uint64 activatesAt = uint64(block.timestamp + perpS.timelockDelay);
        perpS.pendingFundingEngine = newEngine;
        perpS.pendingFundingEngineActivatesAt = activatesAt;
        emit FundingEngineProposed(newEngine, activatesAt);
    }

    /// @inheritdoc IPerpEngine
    function activateSetFundingEngine() external {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        uint64 readyAt = perpS.pendingFundingEngineActivatesAt;
        if (readyAt == 0) revert NoPendingFundingEngine();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldEngine = perpS.fundingEngine;
        address newEngine = perpS.pendingFundingEngine;
        perpS.fundingEngine = newEngine;
        delete perpS.pendingFundingEngine;
        delete perpS.pendingFundingEngineActivatesAt;
        emit FundingEngineActivated(oldEngine, newEngine);
    }

    /// @inheritdoc IPerpEngine
    function cancelSetFundingEngine() external onlyGovernance {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.pendingFundingEngineActivatesAt == 0) revert NoPendingFundingEngine();
        address pending = perpS.pendingFundingEngine;
        delete perpS.pendingFundingEngine;
        delete perpS.pendingFundingEngineActivatesAt;
        emit FundingEngineCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: FeedbackController rotation (timelocked)
    //
    // Same shape as `proposeSetFundingEngine`. Until the FeedbackController is wired in, the
    // writer stays at `address(0)` and `applyImpulse` reverts.
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    function proposeSetFeedbackController(address newController) external onlyGovernance {
        if (newController == address(0)) revert InvalidConfig();
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.pendingFeedbackControllerActivatesAt != 0) revert PendingFeedbackControllerExists();
        uint64 activatesAt = uint64(block.timestamp + perpS.timelockDelay);
        perpS.pendingFeedbackController = newController;
        perpS.pendingFeedbackControllerActivatesAt = activatesAt;
        emit FeedbackControllerProposed(newController, activatesAt);
    }

    /// @inheritdoc IPerpEngine
    function activateSetFeedbackController() external {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        uint64 readyAt = perpS.pendingFeedbackControllerActivatesAt;
        if (readyAt == 0) revert NoPendingFeedbackController();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldController = perpS.feedbackController;
        address newController = perpS.pendingFeedbackController;
        perpS.feedbackController = newController;
        delete perpS.pendingFeedbackController;
        delete perpS.pendingFeedbackControllerActivatesAt;
        emit FeedbackControllerActivated(oldController, newController);
    }

    /// @inheritdoc IPerpEngine
    function cancelSetFeedbackController() external onlyGovernance {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.pendingFeedbackControllerActivatesAt == 0) revert NoPendingFeedbackController();
        address pending = perpS.pendingFeedbackController;
        delete perpS.pendingFeedbackController;
        delete perpS.pendingFeedbackControllerActivatesAt;
        emit FeedbackControllerCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: MarginEngine rotation (timelocked)
    //
    // Same shape as `proposeSetFundingEngine` / `proposeSetFeedbackController`. Until rotation
    // activates, `openPosition` reverts at the `_enforceOpenCaps` delegation with
    // `MarginEngineUnset`.
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    function proposeSetMarginEngine(address newEngine) external onlyGovernance {
        if (newEngine == address(0)) revert InvalidConfig();
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.pendingMarginEngineActivatesAt != 0) revert PendingMarginEngineExists();
        uint64 activatesAt = uint64(block.timestamp + perpS.timelockDelay);
        perpS.pendingMarginEngine = newEngine;
        perpS.pendingMarginEngineActivatesAt = activatesAt;
        emit MarginEngineProposed(newEngine, activatesAt);
    }

    /// @inheritdoc IPerpEngine
    function activateSetMarginEngine() external {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        uint64 readyAt = perpS.pendingMarginEngineActivatesAt;
        if (readyAt == 0) revert NoPendingMarginEngine();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldEngine = perpS.marginEngine;
        address newEngine = perpS.pendingMarginEngine;
        perpS.marginEngine = newEngine;
        delete perpS.pendingMarginEngine;
        delete perpS.pendingMarginEngineActivatesAt;
        emit MarginEngineActivated(oldEngine, newEngine);
    }

    /// @inheritdoc IPerpEngine
    function cancelSetMarginEngine() external onlyGovernance {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.pendingMarginEngineActivatesAt == 0) revert NoPendingMarginEngine();
        address pending = perpS.pendingMarginEngine;
        delete perpS.pendingMarginEngine;
        delete perpS.pendingMarginEngineActivatesAt;
        emit MarginEngineCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: LiquidationEngine rotation (timelocked) — Wave 5B
    //
    // Same shape as `proposeSetMarginEngine`. Until rotation activates, `liquidateClose` reverts
    // at the `onlyLiquidationEngine` modifier with `OnlyLiquidationEngine`.
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    function proposeSetLiquidationEngine(address newEngine) external onlyGovernance {
        if (newEngine == address(0)) revert InvalidConfig();
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.pendingLiquidationEngineActivatesAt != 0) revert PendingLiquidationEngineExists();
        uint64 activatesAt = uint64(block.timestamp + perpS.timelockDelay);
        perpS.pendingLiquidationEngine = newEngine;
        perpS.pendingLiquidationEngineActivatesAt = activatesAt;
        emit LiquidationEngineProposed(newEngine, activatesAt);
    }

    /// @inheritdoc IPerpEngine
    function activateSetLiquidationEngine() external {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        uint64 readyAt = perpS.pendingLiquidationEngineActivatesAt;
        if (readyAt == 0) revert NoPendingLiquidationEngine();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldEngine = perpS.liquidationEngine;
        address newEngine = perpS.pendingLiquidationEngine;
        perpS.liquidationEngine = newEngine;
        delete perpS.pendingLiquidationEngine;
        delete perpS.pendingLiquidationEngineActivatesAt;
        emit LiquidationEngineActivated(oldEngine, newEngine);
    }

    /// @inheritdoc IPerpEngine
    function cancelSetLiquidationEngine() external onlyGovernance {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.pendingLiquidationEngineActivatesAt == 0) revert NoPendingLiquidationEngine();
        address pending = perpS.pendingLiquidationEngine;
        delete perpS.pendingLiquidationEngine;
        delete perpS.pendingLiquidationEngineActivatesAt;
        emit LiquidationEngineCancelled(pending);
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

    /// @inheritdoc IPerpEngine
    function lpRebatePct() external view returns (uint8) {
        return PerpStorage.load().lpRebatePct;
    }

    /// @inheritdoc IPerpEngine
    function markMaxDeltaBps() external view returns (uint16) {
        return PerpStorage.load().markMaxDeltaBps;
    }

    /// @inheritdoc IPerpEngine
    function cappedTvl() external view returns (uint256 tvl, uint64 updatedAt) {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        return (perpS.cappedTvl, perpS.cappedTvlUpdatedAt);
    }

    /// @inheritdoc IPerpEngine
    function isForceSettled(bytes32 subjectId) external view returns (bool) {
        return PerpStorage.load().subjectForceSettled[subjectId];
    }

    /// @inheritdoc IPerpEngine
    function settlementMarkOf(bytes32 subjectId) external view returns (uint256) {
        return PerpStorage.load().subjectSettlementMark[subjectId];
    }

    /// @inheritdoc IPerpEngine
    function fundingEngine() external view returns (address) {
        return PerpStorage.load().fundingEngine;
    }

    /// @inheritdoc IPerpEngine
    function cumulativeFundingIndex(bytes32 subjectId) external view returns (int256) {
        return FundingStorage.load().cumulativeFundingIndex[subjectId];
    }

    /// @inheritdoc IPerpEngine
    function lastFundingAt(bytes32 subjectId) external view returns (uint64) {
        return FundingStorage.load().lastFundingAt[subjectId];
    }

    /// @notice Pending FundingEngine rotation (zero address + zero timestamp when none in flight).
    function pendingFundingEngine() external view returns (address account, uint64 activatesAt) {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        return (perpS.pendingFundingEngine, perpS.pendingFundingEngineActivatesAt);
    }

    /// @inheritdoc IPerpEngine
    function feedbackController() external view returns (address) {
        return PerpStorage.load().feedbackController;
    }

    /// @inheritdoc IPerpEngine
    function pendingFeedbackController() external view returns (address account, uint64 activatesAt) {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        return (perpS.pendingFeedbackController, perpS.pendingFeedbackControllerActivatesAt);
    }

    function pendingMarkWriterActivatesAt(address writer) external view returns (uint64) {
        return PerpStorage.load().pendingMarkWriterActivatesAt[writer];
    }

    /// @inheritdoc IPerpEngine
    function isRouter(address account) external view returns (bool) {
        return PerpStorage.load().routers[account];
    }

    /// @inheritdoc IPerpEngine
    function pendingRouterActivatesAt(address router) external view returns (uint64) {
        return PerpStorage.load().pendingRouterActivatesAt[router];
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

    /// @notice Configured MarginEngine address. `address(0)` until the timelocked rotation
    ///         lands. While unset, every `openPosition` call reverts at the delegation site with
    ///         `MarginEngineUnset` — the deploy script must wire MarginEngine before traders can
    ///         open new positions.
    function marginEngine() external view returns (address) {
        return PerpStorage.load().marginEngine;
    }

    /// @notice Pending MarginEngine rotation (zero address + zero timestamp when none in flight).
    function pendingMarginEngine() external view returns (address account, uint64 activatesAt) {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        return (perpS.pendingMarginEngine, perpS.pendingMarginEngineActivatesAt);
    }

    /// @inheritdoc IPerpEngine
    function liquidationEngine() external view returns (address) {
        return PerpStorage.load().liquidationEngine;
    }

    /// @inheritdoc IPerpEngine
    function pendingLiquidationEngine() external view returns (address account, uint64 activatesAt) {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        return (perpS.pendingLiquidationEngine, perpS.pendingLiquidationEngineActivatesAt);
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
