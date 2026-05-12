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
