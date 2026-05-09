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

    function setMarginParams(uint16 imBps, uint16 mmBps, uint16 bufBps, uint16 maxLevBps) external;
    function setKycCaps(uint8 tier, uint256 perSubjectCap, uint256 combinedCap) external;
    function setMarkStaleAfter(uint32 seconds_) external;

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
    function isMarginOk(bytes32 positionId) external view returns (bool);

    function isMarkWriter(address account) external view returns (bool);
    function globalHalt() external view returns (bool);
    function governance() external view returns (address);
    function timelockDelay() external view returns (uint32);
    function markStaleAfter() external view returns (uint32);

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
    event MarginParamsSet(uint16 imBps, uint16 mmBps, uint16 bufBps, uint16 maxLevBps);
    event KycCapsSet(uint8 tier, uint256 perSubjectCap, uint256 combinedCap);
    event MarkStaleAfterSet(uint32 seconds_);
    event GovernanceTransferProposed(address indexed newGovernance, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceTransferCancelled(address indexed pendingGovernance);

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
}
