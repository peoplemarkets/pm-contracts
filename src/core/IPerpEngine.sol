// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @notice Position lifecycle for People Markets perps. Single entry point for open / close /
///         modify. v0 supports one position per (trader, subject) pair, USDC settlement, no
///         funding accrual, no liquidation, no event-impulse feedback.
interface IPerpEngine {
    // ------------------------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------------------------

    enum Side {
        LONG,
        SHORT
    }

    /// @dev Mirrors `PerpStorage.Position`. `entryFundingIndex` is reserved for FundingEngine
    ///      (week 8-9) — set to 0 in v0 but kept in the struct so the storage layout stays stable.
    struct Position {
        int256 size;
        uint256 collateral;
        uint256 entryPrice;
        int256 entryFundingIndex;
        uint64 openedAt;
        uint64 lastInteractionAt;
        address owner;
        bytes32 subjectId;
    }

    /// @dev `expectedMark` + `maxSlippageBps` defends users against MEV sandwiching the mark.
    ///      `deadline` rejects stale txs (tx held in mempool past intent).
    struct OpenParams {
        bytes32 subjectId;
        Side side;
        uint256 collateralAmount;
        uint256 sizeNotional;
        uint256 expectedMark;
        uint256 maxSlippageBps;
        uint64 deadline;
        bool isMaker;
    }

    struct CloseParams {
        bytes32 subjectId;
        uint256 sizeFractionBps; // 10_000 = full close; 1..9_999 = partial
        uint256 expectedMark;
        uint256 maxSlippageBps;
        uint64 deadline;
        bool isMaker;
    }

    // ------------------------------------------------------------------------------------------
    // Trader actions
    // ------------------------------------------------------------------------------------------

    /// @notice Open a new position. Returns a permanent positionId derived from a monotonic nonce
    ///         so closed-position events stay correlatable in indexers.
    function openPosition(OpenParams calldata p) external returns (bytes32 positionId);

    /// @notice Trusted-router entrypoint: open a position on behalf of `trader`. Caller MUST be
    ///         in the `routers` set (timelocked add, immediate remove). The router orchestrates
    ///         multi-leg trades (e.g. atomic pair trades) while the trader remains the position
    ///         owner, KYC subject, and counterparty for collateral + fee debits via the LPVault.
    /// @dev    Body shape is identical to `openPosition` but uses `trader` instead of `msg.sender`
    ///         everywhere. Both entry points delegate to the same internal helper so future
    ///         changes to the open path apply uniformly.
    function openPositionFor(address trader, OpenParams calldata p) external returns (bytes32 positionId);

    /// @notice Close (or partially close) the caller's position on `subjectId`. Returns signed
    ///         realized PnL on the closed slice.
    function closePosition(CloseParams calldata p) external returns (int256 realizedPnl);

    function addCollateral(bytes32 subjectId, uint256 amount) external;
    function removeCollateral(bytes32 subjectId, uint256 amount) external;

    // ------------------------------------------------------------------------------------------
    // Permissioned writes
    // ------------------------------------------------------------------------------------------

    /// @notice Push a fresh mark price for a subject. Caller must be in the `markWriters` set.
    /// @dev    Allowed during pauses (mark observation continues; pauses gate trades, not writes).
    ///         Always sets `markUpdatedAt = block.timestamp` — the writer cannot supply a timestamp.
    function pushMark(bytes32 subjectId, uint256 newMark) external;

    /// @notice Capture a settlement mark for a DELISTED subject. Governance only.
    /// @dev    SHIM: traders must subsequently call `closeAtForcedSettlement` to claim. No
    ///         iteration here — push model. The captured mark becomes canonical from this call
    ///         onward; subsequent live-mark pushes are ignored by the close path.
    function forceSettleSubject(bytes32 subjectId, uint256 settlementMark) external;

    /// @notice Permissionless close of the caller's position on a force-settled subject. Uses the
    ///         captured mark, full-close only, ZERO fee (forced settlement is a venue obligation).
    function closeAtForcedSettlement(bytes32 subjectId) external returns (int256 realizedPnl);

    /// @notice Halt all trading globally. Governance only. v0 has no in-contract timelock here so
    ///         emergency response is fast; the operational risk is documented in the contract.
    function setGlobalHalt(bool halted) external;

    // ------------------------------------------------------------------------------------------
    // Governance (timelocked)
    // ------------------------------------------------------------------------------------------

    function proposeAddMarkWriter(address writer) external;
    function activateAddMarkWriter(address writer) external;
    function cancelAddMarkWriter(address writer) external;

    /// @notice Removing a mark writer is fast (no timelock) so a compromised writer can be cut off
    ///         immediately. Governance still gates the call.
    function removeMarkWriter(address writer) external;

    /// @notice Propose a new trusted router. Timelocked — matches the mark-writer add pattern.
    ///         Until `activateAddRouter` runs, the router cannot call `openPositionFor`.
    function proposeAddRouter(address router) external;
    function activateAddRouter(address router) external;
    function cancelAddRouter(address router) external;

    /// @notice Removing a router is immediate (no timelock) so a compromised router can be cut off
    ///         without delay. Governance still gates the call.
    function removeRouter(address router) external;

    function setMarkStaleAfter(uint32 seconds_) external;
    function setLpRebatePct(uint8 pct) external;
    function setMarkMaxDeltaBps(uint16 bps) external;

    /// @notice Wave 4 MarginEngine rotation. Same shape as `proposeSetFundingEngine` /
    ///         `proposeSetFeedbackController`: timelocked propose/activate/cancel via the existing
    ///         `timelockDelay`. Until rotation activates, `openPosition` reverts at the
    ///         delegation site with `MarginEngineUnset`.
    function proposeSetMarginEngine(address newEngine) external;
    function activateSetMarginEngine() external;
    function cancelSetMarginEngine() external;

    /// @notice Wave 5B LiquidationEngine rotation. Same shape as MarginEngine rotation: timelocked
    ///         propose/activate/cancel via the existing `timelockDelay`. Until rotation activates,
    ///         `liquidateClose` reverts with `OnlyLiquidationEngine`.
    function proposeSetLiquidationEngine(address newEngine) external;
    function activateSetLiquidationEngine() external;
    function cancelSetLiquidationEngine() external;

    /// @notice LiquidationEngine-only atomic close used by the 5-tier waterfall. Reduces a
    ///         position's signed size by `sizeToClose` (or deletes it if equal to the full size),
    ///         decrements OI accumulators, routes (`collateralToReturn`, `signedPnl`,
    ///         `bountyToPay`) through `LPVault.settlePosition`, and emits `PositionLiquidated`.
    /// @dev    The vault settles a 3-way payout: the trader receives `collateralToReturn`, the
    ///         liquidator receives `bountyToPay`, and the LP/insurance side absorbs the pnl.
    ///         The caller (LiquidationEngine) has already drawn any insurance covering BEFORE
    ///         this call so the vault has the USDC to pay both legs in one go.
    /// @param  positionId         Target position. MUST exist (size != 0).
    /// @param  sizeToClose        Signed close size; must have the same sign as the position's
    ///                            current size and absolute magnitude in (0, |position.size|].
    /// @param  collateralToReturn 6-decimal USDC to send to the trader. Vault verifies solvency.
    /// @param  bountyToPay        6-decimal USDC to send to the liquidator (msg.sender on the
    ///                            engine side, but the LiquidationEngine address forwards the
    ///                            target via parameter).
    /// @param  signedPnl          Signed pnl applied to the slice. Negative on losses.
    /// @param  liquidator         EOA that receives the bounty.
    /// @param  tierCode           Enum-coded liquidation tier reached. Echoed in the event so
    ///                            indexers can categorise without a second lookup.
    function liquidateClose(
        bytes32 positionId,
        int256 sizeToClose,
        uint256 collateralToReturn,
        uint256 bountyToPay,
        int256 signedPnl,
        address liquidator,
        uint8 tierCode
    )
        external;

    /// @notice Tier-1 funding event stub: timelocked rotation of the FundingEngine writer.
    /// @dev    Until FundingEngine v1 ships, `fundingEngine` is `address(0)` and any
    ///         `pushFundingIndex` call reverts. Rotation follows the standard propose/activate/
    ///         cancel pattern, gated by the existing `timelockDelay`.
    function proposeSetFundingEngine(address newEngine) external;
    function activateSetFundingEngine() external;
    function cancelSetFundingEngine() external;

    /// @notice Wave 3B FeedbackController writer rotation. Same shape as the FundingEngine
    ///         rotation: timelocked propose/activate/cancel via the existing `timelockDelay`.
    ///         Until activated, `applyImpulse` reverts on every call.
    function proposeSetFeedbackController(address newController) external;
    function activateSetFeedbackController() external;
    function cancelSetFeedbackController() external;

    /// @notice FeedbackController-only mark bump. Caller MUST be the configured
    ///         `feedbackController`; the subject MUST be tradeable. Multiplies the current mark
    ///         by `(10_000 + impulseBps) / 10_000` and updates `markUpdatedAt`.
    function applyImpulse(bytes32 subjectId, int256 impulseBps) external;

    /// @notice FundingEngine-only writer for the per-subject cumulative funding index. Caller MUST
    ///         be the configured `fundingEngine`; the subject MUST be tradeable (pauses freeze
    ///         funding per spec §2 line 66).
    /// @dev    v0 SHIM: this is event-only — no PnL math, no position settle. Positions opened
    ///         after this call inherit the new index via `entryFundingIndex` so FundingEngine v1
    ///         can ship without a storage migration.
    function pushFundingIndex(bytes32 subjectId, int256 newIndex, int256 fundingRate1e18) external;

    /// @notice Permissionless poke that snapshots the live `vault.totalAssets()` into the
    ///         `cappedTvl` field used by the per-subject OI cap. Cooldown-gated so a same-block
    ///         flash deposit cannot inflate the cap. v2-audit Fix #3.
    function pokeCappedTvl() external;

    function proposeGovernanceTransfer(address newGovernance) external;
    function activateGovernanceTransfer() external;
    function cancelGovernanceTransfer() external;

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function positionOf(bytes32 positionId) external view returns (Position memory);
    function positionIdOf(address trader, bytes32 subjectId) external view returns (bytes32);
    function markOf(bytes32 subjectId) external view returns (uint256 price, uint64 updatedAt);
    function openInterestOf(bytes32 subjectId) external view returns (uint256 longOI, uint256 shortOI);

    /// @notice Equity = collateral + unrealized PnL. Signed because PnL can exceed collateral.
    function equityOf(bytes32 positionId) external view returns (int256);
    function marginRatioBpsOf(bytes32 positionId) external view returns (uint256);
    function leverageBpsOf(bytes32 positionId) external view returns (uint256);

    function isMarkWriter(address account) external view returns (bool);

    /// @notice Whether `account` is a registered trusted router cleared to call `openPositionFor`.
    function isRouter(address account) external view returns (bool);

    /// @notice Pending router activation timestamp. Zero if `router` has no add proposal in flight.
    function pendingRouterActivatesAt(address router) external view returns (uint64);
    function globalHalt() external view returns (bool);
    function governance() external view returns (address);
    function timelockDelay() external view returns (uint32);
    function markStaleAfter() external view returns (uint32);
    function lpRebatePct() external view returns (uint8);
    function markMaxDeltaBps() external view returns (uint16);
    function cappedTvl() external view returns (uint256 tvl, uint64 updatedAt);
    function isForceSettled(bytes32 subjectId) external view returns (bool);
    function settlementMarkOf(bytes32 subjectId) external view returns (uint256);

    /// @notice Configured FundingEngine writer. `address(0)` until FundingEngine v1 ships.
    function fundingEngine() external view returns (address);

    /// @notice Configured FeedbackController writer. `address(0)` until Wave 3B is wired in.
    function feedbackController() external view returns (address);

    /// @notice Pending FeedbackController rotation (zero address + zero timestamp when none).
    function pendingFeedbackController() external view returns (address account, uint64 activatesAt);

    /// @notice The configured SubjectRegistry dependency.
    function subjectRegistry() external view returns (address);

    /// @notice Most recent cumulative funding index for `subjectId` (signed, 1e18 scale).
    function cumulativeFundingIndex(bytes32 subjectId) external view returns (int256);

    /// @notice Timestamp (seconds) of the last `pushFundingIndex` for `subjectId`.
    function lastFundingAt(bytes32 subjectId) external view returns (uint64);

    /// @notice Configured MarginEngine (Wave 4). `address(0)` until rotated in.
    function marginEngine() external view returns (address);

    /// @notice Pending MarginEngine rotation (zero address + zero timestamp when none in flight).
    function pendingMarginEngine() external view returns (address account, uint64 activatesAt);

    /// @notice Configured LiquidationEngine (Wave 5B). `address(0)` until rotated in. Until set,
    ///         `liquidateClose` reverts with `OnlyLiquidationEngine`.
    function liquidationEngine() external view returns (address);

    /// @notice Pending LiquidationEngine rotation (zero address + zero timestamp when none).
    function pendingLiquidationEngine() external view returns (address account, uint64 activatesAt);

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event PositionOpened(
        bytes32 indexed positionId,
        address indexed trader,
        bytes32 indexed subjectId,
        Side side,
        int256 size,
        uint256 entryPrice,
        uint256 collateral,
        uint256 fee
    );
    event PositionClosed(
        bytes32 indexed positionId,
        address indexed trader,
        bytes32 indexed subjectId,
        int256 realizedPnl,
        uint256 fee,
        uint256 returnedToTrader,
        bool isFullClose
    );
    event CollateralAdded(bytes32 indexed positionId, uint256 amount, uint256 newCollateral);
    event CollateralRemoved(bytes32 indexed positionId, uint256 amount, uint256 newCollateral);
    event MarkPushed(bytes32 indexed subjectId, uint256 oldMark, uint256 newMark, uint64 updatedAt);
    event GlobalHaltSet(bool halted);
    event MarkWriterAdded(address indexed writer);
    event MarkWriterRemoved(address indexed writer);
    event MarkWriterAddProposed(address indexed writer, uint64 activatesAt);
    event MarkWriterAddCancelled(address indexed writer);
    event RouterProposed(address indexed router, uint64 activatesAt);
    event RouterActivated(address indexed router);
    event RouterCancelled(address indexed router);
    event RouterRemoved(address indexed router);
    event MarkStaleAfterSet(uint32 seconds_);
    event LpRebatePctSet(uint8 oldPct, uint8 newPct);
    event MarkMaxDeltaBpsSet(uint16 oldBps, uint16 newBps);
    event CappedTvlPoked(uint256 newTvl, address indexed by);
    event MarkDeltaCapExceeded(bytes32 indexed subjectId, uint256 oldMark, uint256 newMark, uint16 capBps);
    event SubjectForceSettled(bytes32 indexed subjectId, uint256 settlementMark, address indexed by);
    event PositionClosedAtForcedSettlement(
        bytes32 indexed positionId,
        address indexed trader,
        bytes32 indexed subjectId,
        int256 realizedPnl,
        uint256 returnedToTrader
    );
    event GovernanceTransferProposed(address indexed newGovernance, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceTransferCancelled(address indexed pendingGovernance);

    // --- Tier-1 funding event stub ---
    /// @notice FundingEngine wrote a new cumulative index for `subjectId`. Indexers subscribe
    ///         to this event today; the math lands in FundingEngine v1.
    event FundingPushed(
        bytes32 indexed subjectId, int256 oldIndex, int256 newIndex, int256 fundingRate1e18, uint64 timestamp
    );
    /// @notice Funding-debt settlement on a position close. `fundingDelta1e6` is denominated in
    ///         USDC (6-dec) and signed (positive = paid to trader, negative = paid by trader).
    ///         Stubbed to 0 in v0 — FundingEngine v1 computes the actual delta.
    event FundingSettled(bytes32 indexed positionId, address indexed trader, int256 fundingDelta1e6);

    /// @notice Timelocked rotation of the FundingEngine writer.
    event FundingEngineProposed(address indexed newEngine, uint64 activatesAt);
    event FundingEngineActivated(address indexed oldEngine, address indexed newEngine);
    event FundingEngineCancelled(address indexed pendingEngine);

    // --- Wave 3B FeedbackController ---
    /// @notice FeedbackController bumped the mark for `subjectId` via `applyImpulse`.
    event MarkImpulsed(
        bytes32 indexed subjectId, uint256 oldMark, uint256 newMark, int256 impulseBps, uint64 timestamp
    );
    /// @notice Timelocked rotation of the FeedbackController writer.
    event FeedbackControllerProposed(address indexed newController, uint64 activatesAt);
    event FeedbackControllerActivated(address indexed oldController, address indexed newController);
    event FeedbackControllerCancelled(address indexed pendingController);

    // --- Wave 4 MarginEngine rotation ---
    /// @notice Timelocked rotation of the MarginEngine pointer.
    event MarginEngineProposed(address indexed newEngine, uint64 activatesAt);
    event MarginEngineActivated(address indexed oldEngine, address indexed newEngine);
    event MarginEngineCancelled(address indexed pendingEngine);

    // --- Wave 5B LiquidationEngine rotation ---
    /// @notice Timelocked rotation of the LiquidationEngine pointer.
    event LiquidationEngineProposed(address indexed newEngine, uint64 activatesAt);
    event LiquidationEngineActivated(address indexed oldEngine, address indexed newEngine);
    event LiquidationEngineCancelled(address indexed pendingEngine);

    /// @notice Emitted on every successful `liquidateClose`. `tierCode` matches the
    ///         `ILiquidationEngine.Tier` enum (PARTIAL=1, FULL=2, INSURANCE=3, SOCIALIZATION=4).
    event PositionLiquidated(
        bytes32 indexed positionId,
        address indexed trader,
        address indexed liquidator,
        int256 sizeClosed,
        uint256 collateralReturned,
        uint256 bountyPaid,
        int256 signedPnl,
        uint8 tierCode
    );

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error Unauthorized(address caller);
    error InvalidConfig();
    error GlobalHaltedError();
    error SubjectNotTradeable(bytes32 subjectId);
    error MarkStale(bytes32 subjectId, uint64 updatedAt);
    error MarkNotSet(bytes32 subjectId);
    error PositionAlreadyOpen(address trader, bytes32 subjectId);
    error PositionNotOpen(bytes32 subjectId);
    error LeverageTooHigh(uint256 leverageBps, uint256 maxBps);
    error InitialMarginShort(uint256 required, uint256 provided);
    error MaintenanceMarginShort(uint256 mmBps, uint256 ratioBps);
    error PerSubjectOiCapExceeded(bytes32 subjectId, Side side, uint256 newOi, uint256 cap);
    error PerTraderSubjectCapExceeded(address trader, bytes32 subjectId, uint256 notional, uint256 cap);
    error CombinedExposureCapExceeded(address trader, uint256 total, uint256 cap);
    error KycTierMissing(address trader);
    error KycTierInvalid(uint8 tier);
    error SlippageExceeded(uint256 expected, uint256 actual, uint256 maxBps);
    error DeadlineExpired(uint64 deadline);
    error InvalidSizeFraction(uint256 bps);
    error UnderwaterClose(int256 equity);
    error AmountZero();
    error NoPendingProposal();
    error PendingProposalExists();
    error TimelockNotElapsed(uint64 readyAt);
    error MarkValueOutOfRange(uint256 value);
    error MarkWriterAlreadyAdded(address writer);
    error MarkWriterNotFound(address writer);
    error LpRebatePctOutOfRange(uint8 pct);
    error MarkDeltaTooLarge(bytes32 subjectId, uint256 oldMark, uint256 newMark, uint16 capBps);
    error MarkMaxDeltaBpsOutOfRange(uint16 bps);
    error CappedTvlPokeTooSoon(uint64 readyAt);
    error SubjectNotDelisted(bytes32 subjectId);
    error SubjectAlreadyForceSettled(bytes32 subjectId);
    error SubjectNotForceSettled(bytes32 subjectId);
    error SubjectIsForceSettled(bytes32 subjectId);
    // --- Tier-1 funding event stub ---
    error OnlyFundingEngine(address caller);
    error PendingFundingEngineExists();
    error NoPendingFundingEngine();
    // --- Tier-1 net-category OI cap ---
    error CategoryOiCapExceeded(bytes32 categoryId, uint256 proposedAbs, uint256 cap);
    error CategoryOiCapBpsOutOfRange();
    // --- Wave 3B FeedbackController ---
    error OnlyFeedbackController(address caller);
    error MarkNotInitialized(bytes32 subjectId);
    error ImpulseUnderflow();
    error PendingFeedbackControllerExists();
    error NoPendingFeedbackController();
    // --- Wave 4 MarginEngine ---
    error MarginEngineUnset();
    error PendingMarginEngineExists();
    error NoPendingMarginEngine();
    // --- Wave 5B LiquidationEngine ---
    error OnlyLiquidationEngine(address caller);
    error PendingLiquidationEngineExists();
    error NoPendingLiquidationEngine();
    error LiquidationSizeMismatch(int256 positionSize, int256 sizeToClose);
    error LiquidationSizeZero();
    // --- Wave 7 Trusted-router set ---
    error OnlyRouter(address caller);
    error PendingRouterExists(address router);
    error NoPendingRouter(address router);
    error RouterAlreadySet(address router);
    error RouterNotSet(address router);
}
