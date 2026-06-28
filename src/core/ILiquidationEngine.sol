// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title  ILiquidationEngine — interface for the 5-tier liquidation waterfall (spec §3 141-155).
///
/// @notice The LiquidationEngine is the sole entry point for closing out positions that have
///         crossed the liquidation buffer. The 5-tier waterfall is:
///           Tier 1 — Partial liquidation. 25% increments, restore equity to MM + 100 bps buffer
///                    after each. Minimum 4 partial attempts before escalating.
///           Tier 2 — Full liquidation. 1% bounty on closed notional.
///           Tier 3 — Insurance fund draw. Covers shortfall when equity < bounty.
///           Tier 4 — LP socialization. Capped at 30% of vault TVL per liquidation event.
///                    Implemented naturally via `LPVault.settlePosition` accepting a negative pnl.
///           Tier 5 — ADL (auto-deleveraging). DEFERRED in v0; reverts with `ADLNotImplemented`.
///
/// @dev    Liquidators are a registered set (timelocked add, immediate remove) — matches the
///         mark-writer / sentiment-writer / resolution-writer pattern. The bounty is the
///         incentive; a registered set caps MEV griefing.
///
/// @dev    Partial-attempt counter. Each call to `liquidate` while the position is still under
///         buffer increments `partialAttempts[positionId]`. When the count reaches
///         `minPartialsBeforeFull`, the next call escalates to Tier 2.
interface ILiquidationEngine {
    // ------------------------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------------------------

    /// @notice Which waterfall tier produced this liquidation result.
    /// @dev    `UNSET` is reserved for the zero-value default and is never emitted.
    enum Tier {
        UNSET,
        PARTIAL,
        FULL,
        INSURANCE,
        SOCIALIZATION,
        ADL
    }

    /// @notice Outcome of a single `liquidate(positionId)` call.
    /// @param  tier                 Highest tier reached (PARTIAL, FULL, INSURANCE, or
    ///                              SOCIALIZATION). Higher tiers imply lower tiers also fired.
    /// @param  positionId           The position closed (partially or fully).
    /// @param  trader               Position owner. Convenience for indexers.
    /// @param  sizeClosed           Signed contract units closed (1e6-fixed contracts). Same sign
    ///                              as the position's pre-call size.
    /// @param  collateralReturned   6-decimal USDC paid back to the trader (0 on FULL/INSURANCE).
    /// @param  bountyPaid           6-decimal USDC paid to the liquidator (msg.sender).
    /// @param  shortfallPnl         Signed 6-decimal USDC. Positive = how much shortfall was
    ///                              absorbed by InsuranceFund + LP socialization combined.
    /// @param  markPrice            Mark price at the time of liquidation (1e18 fixed-point).
    struct LiquidationResult {
        Tier tier;
        bytes32 positionId;
        address trader;
        int256 sizeClosed;
        uint256 collateralReturned;
        uint256 bountyPaid;
        int256 shortfallPnl;
        uint256 markPrice;
    }

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error Unauthorized(address caller);
    error OnlyLiquidator(address caller);
    error InvalidConfig();
    error PositionNotFound(bytes32 positionId);
    error NotUnderBuffer(bytes32 positionId);
    error SocializationCapExceeded(uint256 requested, uint256 cap);
    error ADLNotImplemented();
    /// @dev Thrown by `adl` when the position is NOT bad enough to justify ADL — i.e. the normal
    ///      Tier 1-4 waterfall (insurance draw + socialization within the cap) could absorb the
    ///      shortfall. ADL is reserved for the residual that would otherwise breach the cap.
    error ADLNotRequired(bytes32 positionId);
    /// @dev Thrown when a supplied ADL counterparty is ineligible: wrong subject, same side as the
    ///      bad position, not currently profitable at mark, or insolvent at the bankruptcy price
    ///      (closing it there would itself create new bad debt).
    error ADLCounterpartyNotEligible(bytes32 counterpartyId);
    /// @dev Thrown when the supplied counterparties' combined size cannot fully offset the bad
    ///      position's size. The keeper must supply enough opposite-side notional.
    error ADLInsufficientCounterpartySize(uint256 remaining);
    /// @dev Thrown when the liquidator is also the owner of the bad position or a counterparty.
    error ADLSelfLiquidation(address account);
    error PartialIncrementOutOfRange(uint16 bps);
    error MinPartialsOutOfRange(uint8 attempts);
    error MmRestoreBufferOutOfRange(uint16 bps);
    error FullBountyOutOfRange(uint16 bps);
    error LpSocializationCapOutOfRange(uint16 bps);
    error PendingGovernanceTransferExists();
    error NoPendingGovernanceTransfer();
    error TimelockNotElapsed(uint64 readyAt);
    error PendingLiquidatorExists(address liquidator);
    error NoPendingLiquidator(address liquidator);
    error LiquidatorNotSet(address liquidator);
    error LiquidatorAlreadyAdded(address liquidator);
    /// @dev Thrown by `resetPartialAttempts` when the position is still under the liquidation
    ///      buffer. Reset is reserved for positions that have been healed (collateral added,
    ///      mark moved, etc.) so the next distress cycle re-enters at the partial phase.
    error StillUnderBuffer(bytes32 positionId);

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event Initialized(
        address indexed governance,
        address indexed perpEngine,
        address indexed marginEngine,
        address lpVault,
        address insuranceFund
    );
    event Liquidated(LiquidationResult result, address indexed liquidator);
    /// @notice Emitted once per counterparty deleveraged inside an `adl` call.
    /// @param  badPositionId       The liquidated (bankrupt) position whose risk is being offloaded.
    /// @param  counterpartyId      The profitable opposite-side position being force-closed.
    /// @param  counterparty        Owner of the deleveraged position.
    /// @param  sizeClosed          Signed contract units of the counterparty closed at `bankruptcyPrice`.
    /// @param  bankruptcyPrice     Price (1e18) at which the counterparty was closed.
    /// @param  traderPayout        6-dec USDC paid back to the counterparty for the closed slice.
    event AutoDeleveraged(
        bytes32 indexed badPositionId,
        bytes32 indexed counterpartyId,
        address indexed counterparty,
        int256 sizeClosed,
        uint256 bankruptcyPrice,
        uint256 traderPayout
    );
    event ConfigSet(
        uint16 partialIncrementBps,
        uint8 minPartialsBeforeFull,
        uint16 mmRestoreBufferBps,
        uint16 fullBountyBps,
        uint16 socializationCapBps
    );
    event LiquidatorProposed(address indexed liquidator, uint64 activatesAt);
    event LiquidatorActivated(address indexed liquidator);
    event LiquidatorCancelled(address indexed liquidator);
    event LiquidatorRemoved(address indexed liquidator);
    event GovernanceTransferProposed(address indexed newGov, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGov, address indexed newGov);
    event GovernanceTransferCancelled(address indexed pendingGov);
    /// @notice Emitted when a permissionless caller resets the partial-attempts counter for a
    ///         healed position (Wave 7 audit Fix #6).
    event PartialAttemptsReset(bytes32 indexed positionId);

    // ------------------------------------------------------------------------------------------
    // External
    // ------------------------------------------------------------------------------------------

    /// @notice Run the waterfall against a single position. Only registered liquidators may call.
    /// @dev    Returns the LiquidationResult and emits one Liquidated event with the highest tier
    ///         reached. Reverts (a) `NotUnderBuffer` if the position is not yet eligible, (b)
    ///         `PositionNotFound` if `size == 0`, (c) `SocializationCapExceeded` if LP
    ///         socialization would exceed the cap, (d) `ADLNotImplemented` if the waterfall would
    ///         need Tier 5.
    function liquidate(bytes32 positionId) external returns (LiquidationResult memory);

    /// @notice Tier-5 auto-deleveraging. Closes a bankrupt position at zero equity (its full
    ///         collateral absorbs the loss, no LP shortfall) and offloads its directional size onto
    ///         keeper-supplied profitable opposite-side positions, each force-closed at the bad
    ///         position's BANKRUPTCY PRICE rather than the (more favourable) current mark.
    ///
    /// @dev    Only callable when the normal Tier 1-4 waterfall cannot absorb the shortfall (the
    ///         residual LP socialization would breach the configured cap) — otherwise reverts
    ///         `ADLNotRequired`. Counterparties MUST be supplied in the protocol's published ADL
    ///         priority order (highest unrealized PnL × leverage first, per `LiquidationMath.
    ///         adlPriority`); the contract validates eligibility but NOT global ordering, so an
    ///         off-chain keeper is trusted to honour the queue exposed in the front-end.
    ///
    ///         The combined |size| of the supplied counterparties MUST be ≥ the bad position's
    ///         |size|; the final counterparty is closed partially to match exactly. Reverts
    ///         `ADLInsufficientCounterpartySize` otherwise.
    ///
    /// @param  badPositionId    The bankrupt position to clear.
    /// @param  counterpartyIds  Profitable opposite-side positions, in ADL-priority order.
    function adl(
        bytes32 badPositionId,
        bytes32[] calldata counterpartyIds
    )
        external
        returns (LiquidationResult memory);

    /// @notice Permissionless reset of the partial-attempts counter for a healed position.
    /// @dev    Wave 7 audit Fix #6. A position that was previously partial-liquidated and then
    ///         healed (collateral added, mark recovered, etc.) keeps its `partialAttempts`
    ///         counter from the prior distress cycle. Without this reset, the next distress
    ///         skips straight to full liquidation, bypassing the partial-increment phase the
    ///         spec mandates. The reset is a separate entry point — not auto-fired inside
    ///         `addCollateral` — so the hot path stays cheap and the trader/keeper makes the
    ///         reset explicit. Reverts `PositionNotFound` when `size == 0` and
    ///         `StillUnderBuffer` when the position is still distressed.
    function resetPartialAttempts(bytes32 positionId) external;

    function setConfig(
        uint16 partialIncrementBps,
        uint8 minPartialsBeforeFull,
        uint16 mmRestoreBufferBps,
        uint16 fullBountyBps,
        uint16 socializationCapBps
    )
        external;

    function proposeAddLiquidator(address liquidator) external;
    function activateAddLiquidator(address liquidator) external;
    function cancelAddLiquidator(address liquidator) external;
    function removeLiquidator(address liquidator) external;
    function proposeGovernanceTransfer(address newGov) external;
    function activateGovernanceTransfer() external;
    function cancelGovernanceTransfer() external;

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function partialAttemptsOf(bytes32 positionId) external view returns (uint8);
    function partialIncrementBps() external view returns (uint16);
    function minPartialsBeforeFull() external view returns (uint8);
    function mmRestoreBufferBps() external view returns (uint16);
    function fullBountyBps() external view returns (uint16);
    function socializationCapBps() external view returns (uint16);
    function isLiquidator(address account) external view returns (bool);
    function pendingLiquidatorActivatesAt(address account) external view returns (uint64);
    function governance() external view returns (address);
    function pendingGovernance() external view returns (address account, uint64 activatesAt);
    function timelockDelay() external view returns (uint32);
    function perpEngine() external view returns (address);
    function marginEngine() external view returns (address);
    function lpVault() external view returns (address);
    function insuranceFund() external view returns (address);
}
