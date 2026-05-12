// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title  IPairTradeRouter — atomic long-A / short-B perp pair trade router.
/// @notice Spec §0 "Pair Trades" — the headline UX. A pair trade opens two perp positions in
///         a single transaction: long on subject A and short on subject B, same trader, same
///         KYC tier, all-or-nothing. Either both legs succeed or the whole tx reverts.
///
/// @dev    The router does NOT hold funds. The trader (msg.sender) approves the LPVault for the
///         combined collateral + fee; the router orchestrates two calls into
///         `PerpEngine.openPositionFor(trader, params)`, where the engine debits the trader
///         directly. Solidity's tx-level revert semantics provide atomicity for free — no manual
///         rollback needed.
interface IPairTradeRouter {
    // ------------------------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------------------------

    /// @notice Atomic long-A / short-B pair trade params. The trader (msg.sender) opens BOTH
    ///         positions in one tx; either both succeed or both revert. Collateral is pulled
    ///         from the trader via LPVault.openPositionFlow as usual.
    struct PairParams {
        // Leg A — long.
        bytes32 longSubjectId;
        uint256 longCollateral;
        uint256 longSizeNotional;
        uint256 longExpectedMark;
        uint16 longMaxSlippageBps;
        bool longIsMaker;
        // Leg B — short.
        bytes32 shortSubjectId;
        uint256 shortCollateral;
        uint256 shortSizeNotional;
        uint256 shortExpectedMark;
        uint16 shortMaxSlippageBps;
        bool shortIsMaker;
        // Pair-level
        uint256 maxTotalCollateral; // safety: combined collateral + fee must not exceed this
        uint64 deadline;
    }

    struct PairResult {
        bytes32 longPositionId;
        bytes32 shortPositionId;
        uint256 totalCollateralLocked;
    }

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error Unauthorized(address caller);
    error InvalidConfig();
    error SameSubject(bytes32 subjectId);
    error TotalCollateralTooHigh(uint256 actual, uint256 cap);
    error DeadlineExpired(uint64 deadline);
    error LegFailed(uint8 leg, bytes reason); // leg 0 = long, 1 = short
    error NoPendingProposal();
    error PendingProposalExists();
    error TimelockNotElapsed(uint64 readyAt);

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event PairOpened(
        address indexed trader,
        bytes32 indexed longPositionId,
        bytes32 longSubjectId,
        bytes32 indexed shortPositionId,
        bytes32 shortSubjectId,
        uint256 totalCollateralLocked
    );

    event GovernanceTransferProposed(address indexed newGovernance, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceTransferCancelled(address indexed pendingGovernance);

    // ------------------------------------------------------------------------------------------
    // External
    // ------------------------------------------------------------------------------------------

    /// @notice Atomic long-A / short-B pair open. msg.sender is the position owner for both legs.
    ///         The trader MUST have approved the LPVault for at least
    ///         `longCollateral + shortCollateral + combined fee`. If either leg reverts (slippage,
    ///         cap, KYC, balance, allowance, etc.) the entire tx reverts and no position is
    ///         created.
    /// @param  p Pair trade parameters. `longSubjectId` MUST differ from `shortSubjectId`. The
    ///           sum of leg collaterals MUST be ≤ `p.maxTotalCollateral`. `block.timestamp` MUST
    ///           be ≤ `p.deadline`.
    /// @return result Position ids for both legs + the combined collateral locked across them
    ///                (collateral only — fees are not echoed by the engine return path).
    function openPair(PairParams calldata p) external returns (PairResult memory result);

    function perpEngine() external view returns (address);
    function governance() external view returns (address);
    function timelockDelay() external view returns (uint32);
    function pendingGovernance() external view returns (address account, uint64 activatesAt);

    /// @notice Propose a timelocked governance transfer. Same shape as PerpEngine's.
    function proposeGovernanceTransfer(address newGovernance) external;
    function activateGovernanceTransfer() external;
    function cancelGovernanceTransfer() external;
}
