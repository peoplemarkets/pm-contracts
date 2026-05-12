// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Single global USDC counterparty vault for every People Markets perp position.
/// @dev    ERC-4626 surface inherited; share token is `pmUSDC`. People-Markets-specific extensions
///         govern collateral movement, fee accrual, and pause-aware deposit/withdraw.
///
/// @dev    Roles:
///         - `governance` — slow lever, timelocked. Sets the PerpEngine operator address and
///           transfers itself.
///         - `operator` — fast lever. Toggles deposit / withdrawal pause flags. No timelock.
///         - `perpEngine` — collateral operator. Sole address allowed to move locked collateral,
///           accrue fees, or settle position PnL.
///
/// @dev    Share-price formula uses `freeAssets`, NOT `totalAssets`, as the denominator. The same
///         on-chain USDC balance backs four distinct buckets (free LP capital, locked collateral,
///         insurance fund, treasury fees) so a depositor minting against `totalAssets` would be
///         claiming funds that are not theirs to redeem. `freeAssets()` is computed as the
///         difference `balanceOf(usdc) − positionCollateral − insuranceFundBalance − accruedFees`.
///         Because every accounted bucket is mirrored in storage, a direct USDC transfer to the
///         vault increments `freeAssets` and is captured pro rata by existing share-holders;
///         atomic share-price inflation is impossible.
interface ILPVault is IERC4626 {
    // ------------------------------------------------------------------------------------------
    // Operator entrypoints (only callable by `perpEngine`)
    // ------------------------------------------------------------------------------------------

    /// @notice Open-position flow. Pulls `collateral + fee` from the trader and books each piece.
    /// @dev    PerpEngine has already validated all caps, leverage, IM, and slippage. The vault
    ///         performs a single `transferFrom` and updates the four buckets atomically.
    /// @param  trader            EOA whose USDC funds the open. Must have approved the vault.
    /// @param  collateralToLock  USDC routed into `positionCollateral`.
    /// @param  fee               Total trading fee (taker / maker classification done in PerpEngine).
    /// @param  lpRebate          Portion of `fee` that stays in `freeAssets` (share-price boost).
    /// @param  insuranceShare    Portion of `fee` routed to `insuranceFundBalance`.
    ///                           Residual = fee − lpRebate − insuranceShare goes to `accruedFees`.
    function openPositionFlow(
        address trader,
        uint256 collateralToLock,
        uint256 fee,
        uint256 lpRebate,
        uint256 insuranceShare
    )
        external;

    /// @notice Close-position flow. Releases collateral, books fees, transfers PnL-adjusted return.
    /// @dev    `pnl` is signed: positive means trader profited (vault pays out from `freeAssets`),
    ///         negative means trader lost (`|pnl|` flows into `freeAssets` from the released
    ///         collateral). PerpEngine guarantees `collateralToRelease + pnl − fee >= 0`; the
    ///         vault enforces this invariant defensively and reverts on under-water close.
    /// @param  collateralToRelease  Portion of `positionCollateral` to unwind. Equal to the
    ///                              position's collateral on a full close, prorated on partial.
    function settlePosition(
        address trader,
        uint256 collateralToRelease,
        int256 pnl,
        uint256 fee,
        uint256 lpRebate,
        uint256 insuranceShare
    )
        external;

    /// @notice 3-way settle from the LiquidationEngine via PerpEngine. Releases
    ///         `collateralReleased` from `positionCollateral`, books `signedPnl` against the LP
    ///         side, transfers `traderPayout` to the trader, and transfers `liquidatorBounty` to
    ///         the liquidator. All in one atomic call.
    /// @dev    Caller MUST be the configured `perpEngine`. The LPVault enforces
    ///         `traderPayout + liquidatorBounty == collateralReleased + signedPnl`
    ///         (where `signedPnl` may be negative). Negative pnl that exceeds the released
    ///         collateral implies a shortfall — the LiquidationEngine has already pre-drawn
    ///         InsuranceFund into the vault so `freeAssets` covers any payout above the released
    ///         collateral. The vault reverts `InsufficientFreeAssets` if that pre-funding was
    ///         insufficient.
    function settleLiquidation(
        address trader,
        address liquidator,
        uint256 collateralReleased,
        uint256 traderPayout,
        uint256 liquidatorBounty,
        int256 signedPnl
    )
        external;

    /// @notice LiquidationEngine entrypoint to draw insurance funding into the vault BEFORE
    ///         `settleLiquidation` runs. The vault forwards the draw to `InsuranceFund` and
    ///         the USDC lands in this contract's balance.
    /// @dev    Caller MUST be the configured `liquidationEngine`. The vault MUST have an
    ///         attached `insuranceFund` (post-migration); pre-migration callers must use a
    ///         different code path (the legacy in-vault bookkeeper is sealed at zero).
    function drawFromInsuranceForLiquidation(uint256 amount) external;

    /// @notice Add collateral to an existing position. No fee, no PnL.
    function lockCollateral(address from, uint256 amount) external;

    /// @notice Withdraw collateral from an existing position. No fee, no PnL. PerpEngine has already
    ///         re-checked initial-margin on the residual position.
    function releaseCollateral(address to, uint256 amount) external;

    // ------------------------------------------------------------------------------------------
    // Insurance fund seeding (Fix #6) — governance only, no timelock, capped cumulatively
    // ------------------------------------------------------------------------------------------

    /// @notice Pulls `amount` USDC from `governance` and books it to `insuranceFundBalance`.
    /// @dev    Spec §3 line 159: $1M treasury seed at launch. Spec §3 line 162: floor mechanic
    ///         allows treasury top-up when the fund drops below 5% of TVL. Both flows go through
    ///         this function. Cumulative cap is the contract-level `MAX_INSURANCE_SEED`; lifting
    ///         it requires a UUPS upgrade.
    /// @dev    Reverts `InsuranceFundMigrated` after `migrateInsuranceFund` has run — treasury
    ///         operators must use `IInsuranceFund.deposit()` directly on the new fund contract.
    function seedInsurance(uint256 amount) external;

    function insuranceSeedDeposited() external view returns (uint256);

    // ------------------------------------------------------------------------------------------
    // Wave 6A — InsuranceFund migration (spec §3 line 162)
    // ------------------------------------------------------------------------------------------

    /// @notice One-shot migration of the legacy in-vault `insuranceFundBalance` bookkeeper into
    ///         a standalone `InsuranceFund` contract.
    /// @dev    Governance-only, NO timelock — the destination fund is itself timelocked under a
    ///         separate multi-sig. Transfers `insuranceFundBalance` USDC to `newFund`, zeroes the
    ///         bookkeeper, and stores `newFund`. After this call:
    ///           - `insuranceFundBalance()` view returns `IInsuranceFund.balance()` from the fund.
    ///           - Insurance accruals during `openPositionFlow` / `settlePosition` route into the
    ///             fund via `IInsuranceFund.accrue(amount)`.
    ///           - `seedInsurance` reverts; treasury top-ups go through `IInsuranceFund.deposit()`.
    ///         Reverts `AlreadyMigrated` on the second call.
    function migrateInsuranceFund(address newFund) external;

    /// @notice One-time post-migration approval for the InsuranceFund to `transferFrom` accruals
    ///         out of the LPVault. Governance-only, no timelock.
    /// @dev    Sets the USDC allowance to `type(uint256).max`. The InsuranceFund is `onlyLPVault`
    ///         gated on its `accrue` entrypoint so unlimited approval is safe.
    function approveInsuranceFund() external;

    function insuranceFund() external view returns (address);

    // ------------------------------------------------------------------------------------------
    // Treasury fee withdrawal (Fix #5) — governance, timelocked
    // ------------------------------------------------------------------------------------------

    function proposeFeeWithdrawal(address recipient, uint256 amount) external;
    function activateFeeWithdrawal() external;
    function cancelFeeWithdrawal() external;

    function pendingFeeWithdrawal()
        external
        view
        returns (address recipient, uint256 amount, uint64 activatesAt, bool exists);

    // ------------------------------------------------------------------------------------------
    // Slippage-protected ERC-4626 wrappers
    // ------------------------------------------------------------------------------------------

    function depositWithMinShares(
        uint256 assets,
        address receiver,
        uint256 minShares
    )
        external
        returns (uint256 shares);

    /// @notice Slippage-protected redeem: burns `shares`, reverts if assets received are LESS
    ///         than `minAssets`. The previous wrapper was named `withdrawWithMaxAssets` and
    ///         checked the wrong direction (protected against receiving too many assets — which
    ///         is impossible to harm a redeemer); this is the corrected form.
    function redeemWithMinAssets(
        uint256 shares,
        address receiver,
        address owner_,
        uint256 minAssets
    )
        external
        returns (uint256 assets);

    // ------------------------------------------------------------------------------------------
    // Governance (timelocked) — propose / activate / cancel
    // ------------------------------------------------------------------------------------------

    function proposeSetPerpEngine(address newEngine) external;
    function activateSetPerpEngine() external;
    function cancelSetPerpEngine() external;

    /// @notice Timelocked rotation of the LiquidationEngine pointer. Until activated,
    ///         `drawFromInsuranceForLiquidation` reverts at the `onlyLiquidationEngine` modifier.
    function proposeSetLiquidationEngine(address newEngine) external;
    function activateSetLiquidationEngine() external;
    function cancelSetLiquidationEngine() external;

    function proposeGovernanceTransfer(address newGovernance) external;
    function activateGovernanceTransfer() external;
    function cancelGovernanceTransfer() external;

    // ------------------------------------------------------------------------------------------
    // Operator (no timelock) — emergency pause
    // ------------------------------------------------------------------------------------------

    function setDepositsPaused(bool paused) external;
    function setWithdrawalsPaused(bool paused) external;
    function setOperator(address newOperator) external; // governance-only, no timelock

    // ------------------------------------------------------------------------------------------
    // Tier-1 insurance cap + floor (governance, no timelock — matches other parameter setters)
    // ------------------------------------------------------------------------------------------

    /// @notice Governance setter for the insurance bookkeeper cap, basis points of `totalAssets()`.
    /// @dev    Spec §3 lines 157–158. Default 1000 (10%), bounds [100, 5000].
    function setInsuranceCapBps(uint16 bps) external;

    /// @notice Governance setter for the insurance bookkeeper floor, basis points of `totalAssets()`.
    /// @dev    Spec §3 lines 161–163. Default 500 (5%), bounds [0, 1000]. MUST be strictly below
    ///         the cap. The floor is informational — `InsuranceFloorBreached` is emitted on
    ///         crossing; no auto-debit. Treasury responds off-chain.
    function setInsuranceFloorBps(uint16 bps) external;

    /// @notice Permissionless: emit `InsuranceFloorBreached` if the insurance bookkeeper is
    ///         currently under the floor. Off-chain bots / the treasury multi-sig poke this
    ///         to surface the breach without waiting for the next settle event.
    function checkInsuranceFloor() external;

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function freeAssets() external view returns (uint256);
    function positionCollateral() external view returns (uint256);
    function insuranceFundBalance() external view returns (uint256);
    function accruedFees() external view returns (uint256);
    function depositsPaused() external view returns (bool);
    function withdrawalsPaused() external view returns (bool);
    function perpEngine() external view returns (address);
    function operator() external view returns (address);
    function governance() external view returns (address);
    function timelockDelay() external view returns (uint32);
    function pendingPerpEngine() external view returns (address account, uint64 activatesAt);
    function pendingGovernance() external view returns (address account, uint64 activatesAt);

    /// @notice Configured LiquidationEngine (Wave 5B). `address(0)` until rotated in.
    function liquidationEngine() external view returns (address);

    /// @notice Pending LiquidationEngine rotation (zero address + zero timestamp when none).
    function pendingLiquidationEngine() external view returns (address account, uint64 activatesAt);

    /// @notice Current insurance cap, basis points of `totalAssets()`. Default 1000 (10%).
    function insuranceCapBps() external view returns (uint16);

    /// @notice Current insurance floor, basis points of `totalAssets()`. Default 500 (5%).
    function insuranceFloorBps() external view returns (uint16);

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event CollateralLocked(address indexed trader, uint256 amount);
    event CollateralReleased(address indexed trader, uint256 amount);
    event PositionOpenedOnVault(
        address indexed trader, uint256 collateral, uint256 fee, uint256 lpRebate, uint256 insuranceShare
    );
    event PositionSettledOnVault(
        address indexed trader,
        uint256 collateralReleased,
        int256 pnl,
        uint256 fee,
        uint256 lpRebate,
        uint256 insuranceShare,
        uint256 returned
    );

    event PerpEngineProposed(address indexed newEngine, uint64 activatesAt);
    event PerpEngineActivated(address indexed oldEngine, address indexed newEngine);
    event PerpEngineCancelled(address indexed pendingEngine);
    event LiquidationEngineProposed(address indexed newEngine, uint64 activatesAt);
    event LiquidationEngineActivated(address indexed oldEngine, address indexed newEngine);
    event LiquidationEngineCancelled(address indexed pendingEngine);

    /// @notice Emitted on every `settleLiquidation`. Mirrors `PositionSettledOnVault` but
    ///         distinguishes the liquidator bounty payout.
    event LiquidationSettledOnVault(
        address indexed trader,
        address indexed liquidator,
        uint256 collateralReleased,
        uint256 traderPayout,
        uint256 liquidatorBounty,
        int256 signedPnl
    );

    /// @notice Emitted on every `drawFromInsuranceForLiquidation`. The vault forwards the draw
    ///         to `InsuranceFund`; the USDC lands on the vault balance available for the next
    ///         `settleLiquidation`.
    event InsuranceDrawnForLiquidation(uint256 amount, uint256 newInsuranceBalance);
    event GovernanceTransferProposed(address indexed newGovernance, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceTransferCancelled(address indexed pendingGovernance);
    event OperatorSet(address indexed oldOperator, address indexed newOperator);

    event DepositsPausedSet(bool paused);
    event WithdrawalsPausedSet(bool paused);

    event InsuranceSeeded(address indexed from, uint256 amount, uint256 cumulative);
    event FeeWithdrawalProposed(address indexed recipient, uint256 amount, uint64 activatesAt);
    event FeeWithdrawalActivated(address indexed recipient, uint256 amount);
    event FeeWithdrawalCancelled(address indexed recipient, uint256 amount);

    // --- Tier-1 insurance cap + floor ---
    /// @notice Excess insurance accrual was redirected to the LP share pool (cap was binding).
    event InsuranceCapOverflow(uint256 excess, uint256 newInsuranceBalance, uint256 vaultTvl);
    /// @notice The insurance bookkeeper is currently below the configured floor. Informational —
    ///         off-chain treasury operations respond by calling `seedInsurance`.
    event InsuranceFloorBreached(uint256 currentBalance, uint256 floor, uint256 vaultTvl);
    /// @notice Governance updated the insurance cap.
    event InsuranceCapBpsSet(uint16 oldBps, uint16 newBps);
    /// @notice Governance updated the insurance floor.
    event InsuranceFloorBpsSet(uint16 oldBps, uint16 newBps);

    // --- Wave 6A: InsuranceFund migration ---
    /// @notice The in-vault bookkeeper has been migrated to the standalone `InsuranceFund`.
    ///         Pre-call `insuranceFundBalance` USDC was transferred to `newFund` and the local
    ///         bookkeeper was zeroed.
    event InsuranceFundMigrated(uint256 amount, address indexed newFund);
    /// @notice LPVault granted the `InsuranceFund` an unlimited USDC allowance so subsequent
    ///         insurance accruals can be pulled atomically.
    event InsuranceFundApproved(address indexed fund);

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error Unauthorized(address caller);
    error InvalidConfig();
    error AmountZero();
    error InsufficientFreeAssets(uint256 requested, uint256 available);
    error InsufficientPositionCollateral(uint256 requested, uint256 available);
    error MinSharesNotMet(uint256 minShares, uint256 received);
    error MinAssetsNotMet(uint256 minAssets, uint256 received);
    error PerpEngineNotSet();
    error FeeSplitInvalid(uint256 fee, uint256 lpRebate, uint256 insuranceShare);
    error UnderwaterClose(uint256 collateralReleased, int256 pnl, uint256 fee);
    error NoPendingProposal();
    error PendingProposalExists();
    error TimelockNotElapsed(uint64 readyAt);
    error InsufficientAccruedFees(uint256 requested, uint256 available);
    error InsuranceSeedCapExceeded(uint256 attempted, uint256 cap);
    // --- Tier-1 insurance cap + floor ---
    error InsuranceCapBpsOutOfRange();
    error InsuranceFloorBpsOutOfRange();
    error InsuranceFloorNotBelowCap();
    // --- Wave 6A: InsuranceFund migration ---
    /// @notice Thrown when a legacy in-vault insurance entrypoint (e.g. `seedInsurance`) is called
    ///         after `migrateInsuranceFund` has run. Use `IInsuranceFund.deposit()` instead.
    error InsuranceFundAlreadyMigrated();
    /// @notice Thrown by `migrateInsuranceFund` on the second call. One-shot.
    error InsuranceFundAlreadySet();
    /// @notice Thrown when an operation requires the InsuranceFund to be wired but it isn't.
    error InsuranceFundNotSet();
    // --- Wave 5B: LiquidationEngine wiring ---
    error OnlyLiquidationEngine(address caller);
    error LiquidationEngineNotSet();
    /// @notice Thrown when `settleLiquidation` is called with `trader == liquidator`. The vault
    ///         transfers the bounty and the trader payout in two separate sends, and a self-
    ///         liquidation would book the same address twice. Disallowed at the boundary.
    error LiquidatorIsTrader(address account);
    /// @notice Thrown when `settleLiquidation` payouts (`traderPayout + liquidatorBounty`) do not
    ///         match the slice's `collateralReleased + signedPnl`. Indicates a LiquidationEngine
    ///         accounting bug.
    error LiquidationPayoutMismatch(int256 expected, int256 actual);
}
