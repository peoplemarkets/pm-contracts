// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {PerpInternals} from "../libraries/PerpInternals.sol";
import {FundingStorage, PerpStorage, QuoteFundingStorage} from "../libraries/StorageLib.sol";
import {ISubjectRegistry} from "../registry/ISubjectRegistry.sol";

import {ILPVault} from "./ILPVault.sol";
import {IPerpEngine} from "./IPerpEngine.sol";

/// @title PerpEngine — position lifecycle for People Markets perps.
/// @notice Single contract entry point for `openPosition`, `closePosition`, `addCollateral`,
///         `removeCollateral`, and the permissioned `pushMark`. Reads subject status + KYC
///         tier from the SubjectRegistry; routes collateral and PnL through the LPVault.
///
/// @dev    Quote-denominated funding uses a separate namespaced index and per-position snapshot.
///         The legacy dimensionless `entryFundingIndex` field remains ABI/storage compatible but
///         is not consumed by settlement.
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

    /// @dev Spec §3 fee split: 40% LP rebate (default; tunable via `setLpRebatePct` in [25, 50]),
    ///      50% insurance (pinned), residual = 100 - lpRebatePct - 50 to treasury (`accruedFees`).
    ///      `lpRebatePct` lives in storage; the spec's 40 → 30% LP-rebate decay over 6 months is
    ///      executed by governance ratcheting this value down.
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

    /// @dev Restricts legacy and quote-index writes to the configured FundingEngine. Reverts
    ///      (with the caller address baked into the error) when unset or called by another account.
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
        _requireRouter();
        _;
    }

    function _requireRouter() private view {
        if (!PerpStorage.load().routers[msg.sender]) revert OnlyRouter(msg.sender);
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        _requireGovernance();
        _;
    }

    function _requireGovernance() private view {
        if (msg.sender != PerpStorage.load().governance) revert Unauthorized(msg.sender);
    }

    // ------------------------------------------------------------------------------------------
    // Trader actions
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    function openPosition(OpenParams calldata p) external nonReentrant returns (bytes32 positionId) {
        return PerpInternals.openPositionFor(msg.sender, p);
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
        return PerpInternals.openPositionFor(trader, p);
    }

    /// @inheritdoc IPerpEngine
    /// @dev The trusted matched-fill router is the authorization and atomicity boundary. This
    ///      wrapper preserves PerpEngine's reentrancy and timelocked-router gates; the extracted
    ///      implementation keeps the additional execution-price path outside the EIP-170-constrained
    ///      engine bytecode.
    function openPositionForMatched(
        address trader,
        MatchedOpenParams calldata p
    )
        external
        nonReentrant
        onlyRouter
        returns (bytes32 positionId)
    {
        return PerpInternals.openPositionForMatched(trader, p);
    }

    /// @inheritdoc IPerpEngine
    /// @dev The matched-fill router has already verified the trader signature, exact position
    ///      binding, reduce-only flag, order direction, role, price limit, and atomic counterparty.
    ///      The linked implementation re-checks all position-sensitive constraints at settlement.
    function closePositionForMatched(
        address trader,
        MatchedCloseParams calldata p
    )
        external
        nonReentrant
        onlyRouter
        returns (int256 realizedPnl)
    {
        return PerpInternals.closePositionForMatched(trader, p);
    }

    /// @inheritdoc IPerpEngine
    function closePosition(CloseParams calldata p) external nonReentrant returns (int256 realizedPnl) {
        return PerpInternals.closePositionFor(msg.sender, p);
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
        return PerpInternals.closePositionFor(trader, p);
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
        PerpInternals.removeCollateralFor(msg.sender, subjectId, amount);
    }

    /// @inheritdoc IPerpEngine
    /// @dev Wave 6C. Trusted-router entrypoint. `positionId` MUST be owned by `trader`.
    function removeCollateralFor(address trader, bytes32 positionId, uint256 amount) external nonReentrant onlyRouter {
        PerpInternals.removeCollateralFor(trader, _subjectIdForOwner(trader, positionId), amount);
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
    // Permissioned writes
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPerpEngine
    /// @dev Mark pushes are allowed regardless of subject status — a writer can record a price
    ///      observation even on a paused or delisting subject. State-changing trades gate the
    ///      mark via `PerpInternals._readFreshMark`.
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
    function pushFundingIndex(bytes32 subjectId, int256 newIndex, int256 fundingRate1e18) external onlyFundingEngine {
        if (QuoteFundingStorage.load().enabled) revert LegacyFundingIndexDisabled();
        PerpStorage.Layout storage perpS = PerpStorage.load();
        ISubjectRegistry(perpS.subjectRegistry).requireTradeable(subjectId);

        FundingStorage.Layout storage fundingS = FundingStorage.load();
        int256 oldIndex = fundingS.cumulativeFundingIndex[subjectId];
        fundingS.cumulativeFundingIndex[subjectId] = newIndex;
        fundingS.lastFundingAt[subjectId] = uint64(block.timestamp);

        emit FundingPushed(subjectId, oldIndex, newIndex, fundingRate1e18, uint64(block.timestamp));
    }

    /// @inheritdoc IPerpEngine
    function pushFundingQuoteIndex(
        bytes32 subjectId,
        int256 newQuoteIndex1e18,
        int256 fundingRate1e18,
        uint256 markPrice1e18
    )
        external
        onlyFundingEngine
    {
        PerpInternals.pushFundingQuoteIndex(subjectId, newQuoteIndex1e18, fundingRate1e18, markPrice1e18);
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
        PerpInternals.applyImpulse(subjectId, impulseBps);
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
        // Snapshot the O(1) event-funding-invariant OI-cap denominator, not the NAV.
        uint256 newTvl = ILPVault(perpS.lpVault).capTvl();
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
    // Same shape as `proposeSetPerpEngine` on LPVault. Both legacy-transition and quote-index
    // selectors share this writer so rotation remains atomic.
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
        return PerpInternals.equityOf(positionId);
    }

    /// @inheritdoc IPerpEngine
    function marginRatioBpsOf(bytes32 positionId) external view returns (uint256) {
        return PerpInternals.marginRatioBpsOf(positionId);
    }

    /// @inheritdoc IPerpEngine
    function leverageBpsOf(bytes32 positionId) external view returns (uint256) {
        return PerpInternals.leverageBpsOf(positionId);
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

    /// @inheritdoc IPerpEngine
    function cumulativeFundingQuoteIndex(bytes32 subjectId) external view returns (int256) {
        return QuoteFundingStorage.load().cumulativeQuoteIndex[subjectId];
    }

    /// @inheritdoc IPerpEngine
    function lastQuoteFundingAt(bytes32 subjectId) external view returns (uint64) {
        return QuoteFundingStorage.load().lastQuoteFundingAt[subjectId];
    }

    /// @inheritdoc IPerpEngine
    function positionFundingQuoteIndex(bytes32 positionId) external view returns (int256) {
        return QuoteFundingStorage.load().entryQuoteIndex[positionId];
    }

    /// @inheritdoc IPerpEngine
    function fundingDebtOf(bytes32 positionId) external view returns (int256) {
        return PerpInternals.fundingDebtOf(positionId);
    }

    /// @inheritdoc IPerpEngine
    function quoteFundingEnabled() external view returns (bool) {
        return QuoteFundingStorage.load().enabled;
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
