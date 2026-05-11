// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @notice Standalone insurance reserve for People Markets.
/// @dev    Spec §3 line 162 calls for the insurance fund to live under a multi-sig DISTINCT from
///         the LPVault operations multi-sig. The fund holds USDC and exposes three counterparty
///         flows:
///           - `deposit(amount)` — anyone (treasury top-ups, community donations).
///           - `accrue(amount)`  — the live `lpVault` only. Pulls USDC from LPVault on every
///             settle that produced an insurance share. Pre-approval is one governance call on
///             the LPVault (`approveInsuranceFund()`).
///           - `drawShortfall(recipient, amount)` — the live `lpVault` only. v0 has no autonomous
///             liquidation consumer; the LPVault initiates a draw when a payout shortfall is
///             detected.
///
/// @dev    `balance()` returns the contract's internal `trackedBalance` — donation USDC that lands
///         via direct ERC-20 `transfer` (no `deposit` call) is INVISIBLE to the bookkeeper and
///         stays unreachable through normal flows. This is intentional: it shields the cap math on
///         LPVault from donation-driven inflation games. To rescue donated dust, governance must
///         upgrade or extend the contract.
///
/// @dev    Governance is timelocked (propose / activate / cancel). The `lpVault` pointer is
///         governance-only but NOT timelocked — fast rotation is the right emergency response if
///         the LPVault is compromised, matching the `setOperator` pattern on the vault itself.
interface IInsuranceFund {
    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error Unauthorized(address caller);
    error InvalidConfig();
    error InsufficientBalance(uint256 requested, uint256 available);
    error AlreadyMigrated();
    error NotLPVault(address caller);
    error PendingGovernanceTransferExists();
    error NoPendingGovernanceTransfer();
    error TimelockNotElapsed(uint64 readyAt);
    error AmountZero();

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event Initialized(address governance, address lpVault, address usdc);
    event Deposited(address indexed from, uint256 amount, uint256 newBalance);
    event AccruedFromVault(uint256 amount, uint256 newBalance);
    event ShortfallDrawn(address indexed recipient, uint256 amount, uint256 newBalance);
    event LPVaultSet(address indexed oldVault, address indexed newVault);
    event GovernanceTransferProposed(address indexed newGov, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGov, address indexed newGov);
    event GovernanceTransferCancelled(address indexed pendingGov);

    // ------------------------------------------------------------------------------------------
    // External
    // ------------------------------------------------------------------------------------------

    /// @notice Permissionless USDC deposit. Anyone can fund the reserve.
    /// @dev    Spec §3 line 162: "treasury matches floor breaches" — governance routes top-ups
    ///         through this entrypoint. Pulls `amount` via `safeTransferFrom`; updates
    ///         `trackedBalance` and emits `Deposited`.
    function deposit(uint256 amount) external;

    /// @notice Pull `amount` of insurance accrual from LPVault into the fund. Only the configured
    ///         LPVault may call this.
    /// @dev    LPVault pre-approves `type(uint256).max` once via `approveInsuranceFund()` so this
    ///         is a single `safeTransferFrom(lpVault, this, amount)` per settle.
    function accrue(uint256 amount) external;

    /// @notice Pay out a shortfall to `recipient`. Only the configured LPVault may call this.
    /// @dev    `nonReentrant`. Reverts `InsufficientBalance` if `amount > trackedBalance`.
    function drawShortfall(address recipient, uint256 amount) external;

    /// @notice Rotate the LPVault consumer. Governance only, NO timelock.
    /// @dev    Fast lever — if LPVault is compromised, the fund must be able to cut off the draw
    ///         and accrue paths immediately. Mirrors `LPVault.setOperator` (governance, no timelock).
    function setLPVault(address newLPVault) external;

    function proposeGovernanceTransfer(address newGov) external;
    function activateGovernanceTransfer() external;
    function cancelGovernanceTransfer() external;

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function balance() external view returns (uint256);
    function usdc() external view returns (address);
    function lpVault() external view returns (address);
    function governance() external view returns (address);
    function pendingGovernance() external view returns (address account, uint64 activatesAt);
    function timelockDelay() external view returns (uint32);
}
