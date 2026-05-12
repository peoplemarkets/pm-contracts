// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title  IBatchRouter — multi-op atomic-batch perp router.
/// @notice Wave 6C. Executes a sequence of position operations (open / close / add-collateral /
///         remove-collateral) in a single transaction with all-or-nothing semantics. If any leg
///         reverts, the whole batch unwinds via Solidity's call semantics — no manual rollback.
///
/// @dev    The router does NOT hold funds and has no internal position storage. The trader is the
///         position owner on every op; `msg.sender` is forwarded directly to PerpEngine's `*For`
///         family entry-points as the acting trader. The trader must have approved the LPVault for
///         the aggregate collateral + fees required by the OPEN / ADD_COLLATERAL ops.
///
/// @dev    Loop size is bounded by `maxBatchSize` (default 20, hard cap 100) so a single batch
///         cannot DoS the gas budget.
interface IBatchRouter {
    // ------------------------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------------------------

    /// @notice Discriminator for `BatchOp.kind`. `UNSET` is reserved as the zero value so an
    ///         uninitialised op is always rejected.
    enum OpKind {
        UNSET,
        OPEN,
        CLOSE,
        ADD_COLLATERAL,
        REMOVE_COLLATERAL
    }

    /// @notice A single operation inside a batch. Only the fields associated with `kind` are read.
    /// @param  kind        Which sub-op to execute. UNSET reverts.
    /// @param  openData    ABI-encoded `IPerpEngine.OpenParams`. Used only for OPEN.
    /// @param  closeData   ABI-encoded `IPerpEngine.CloseParams`. Used only for CLOSE.
    /// @param  positionId  Target position. Used by ADD_COLLATERAL / REMOVE_COLLATERAL.
    /// @param  amount      USDC (6-dec) amount. Used by ADD_COLLATERAL / REMOVE_COLLATERAL.
    struct BatchOp {
        OpKind kind;
        bytes openData;
        bytes closeData;
        bytes32 positionId;
        uint256 amount;
    }

    struct BatchParams {
        BatchOp[] ops;
        uint64 deadline;
    }

    struct OpResult {
        OpKind kind;
        bytes32 positionId; // OPEN/CLOSE: the position involved. Zero for collateral ops.
        int256 pnl; // CLOSE: realized PnL on the closed slice; zero for other ops.
    }

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error Unauthorized(address caller);
    error InvalidConfig();
    error EmptyBatch();
    error DeadlineExpired(uint64 deadline);
    error InvalidOpKind();
    error BatchTooLarge(uint256 count, uint256 cap);
    error MaxBatchSizeOutOfRange(uint16 size);
    error NoPendingProposal();
    error PendingProposalExists();
    error TimelockNotElapsed(uint64 readyAt);

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event Initialized(address governance, address perpEngine);
    event BatchExecuted(address indexed trader, uint256 opCount);
    event MaxBatchSizeSet(uint16 oldSize, uint16 newSize);
    event GovernanceTransferProposed(address indexed newGov, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGov, address indexed newGov);
    event GovernanceTransferCancelled(address indexed pendingGov);

    // ------------------------------------------------------------------------------------------
    // External
    // ------------------------------------------------------------------------------------------

    /// @notice Execute a batch of position operations atomically. `msg.sender` is the position
    ///         owner for every op. If any op reverts, the whole batch reverts.
    /// @param  params Batch payload. `ops.length` MUST be in [1, maxBatchSize] and
    ///                `block.timestamp` MUST be ≤ `deadline`.
    /// @return results One entry per op, in order. For OPEN this carries the new positionId; for
    ///                 CLOSE the closed positionId and realized PnL; collateral ops carry zeros.
    function executeBatch(BatchParams calldata params) external returns (OpResult[] memory results);

    /// @notice Governance setter for the per-batch op cap. Immediate (no timelock). Bounds [1, 100].
    function setMaxBatchSize(uint16 newMaxBatchSize) external;

    /// @notice Timelocked governance transfer, matching PairTradeRouter / PerpEngine semantics.
    function proposeGovernanceTransfer(address newGovernance) external;
    function activateGovernanceTransfer() external;
    function cancelGovernanceTransfer() external;

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function perpEngine() external view returns (address);
    function governance() external view returns (address);
    function pendingGovernance() external view returns (address account, uint64 activatesAt);
    function timelockDelay() external view returns (uint32);
    function maxBatchSize() external view returns (uint16);
}
