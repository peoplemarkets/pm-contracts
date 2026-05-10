// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {VaultStorage} from "../libraries/StorageLib.sol";
import {ILPVault} from "./ILPVault.sol";

/// @title LPVault — single global ERC-4626 USDC counterparty vault.
/// @notice Counterparty to every position across every Person Stock. Share token `pmUSDC`.
///         Locked collateral, insurance fund, and accrued fees are tracked alongside the free
///         LP capital so a depositor can never mint shares against funds they can't redeem.
///
/// @dev    Share-price denominator: this contract overrides `totalAssets()` to return
///         `freeAssets()` instead of `usdc.balanceOf(this)`. The same on-chain USDC backs four
///         distinct buckets (free LP capital, locked position collateral, insurance fund,
///         treasury fees) — only the first one backs LP shares. The override is the *only*
///         deviation from canonical OpenZeppelin ERC-4626 semantics. All `preview*` and `max*`
///         helpers fall through to the same denominator and behave standard-compliantly.
///
/// @dev    Inflation-attack defense: `_decimalsOffset() = 6` matches USDC's decimals and adds
///         the OZ virtual-shares mitigation. Deployment runbook also calls for governance to seed
///         a non-trivial first deposit before opening trading. Donation attacks (direct USDC
///         transfer) inflate `freeAssets`; existing LPs absorb the donation pro rata. No atomic
///         frontrun extraction is possible because share-price math uses the explicit
///         bookkeeper-difference, not `balanceOf`.
contract LPVault is Initializable, UUPSUpgradeable, ERC4626Upgradeable, ReentrancyGuard, ILPVault {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    uint32 public constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 public constant MAX_TIMELOCK_DELAY = 30 days;
    uint8 internal constant DECIMALS_OFFSET = 6;

    /// @dev Cumulative ceiling on `seedInsurance`. 10× the spec's $1M initial seed (§3 line 159)
    ///      gives generous headroom for the floor-mechanic top-up (§3 line 162) without making
    ///      this a daily lever. Lifting the cap requires a UUPS upgrade — high friction by design.
    uint256 public constant MAX_INSURANCE_SEED = 10_000_000 * 1e6;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the vault.
    /// @param  usdc_ Underlying ERC-20. On Base mainnet this is the canonical USDC contract.
    /// @param  governance_ Multi-sig that proposes operator + governance transfers (timelocked).
    /// @param  operator_ Multi-sig that toggles deposit / withdrawal pause flags (no timelock).
    /// @param  timelockDelay_ Seconds. Must lie in [MIN_TIMELOCK_DELAY, MAX_TIMELOCK_DELAY].
    /// @param  name_ ERC-20 share name (e.g. "People Markets LP USDC").
    /// @param  symbol_ ERC-20 share symbol (e.g. "pmUSDC").
    function initialize(
        IERC20 usdc_,
        address governance_,
        address operator_,
        uint32 timelockDelay_,
        string memory name_,
        string memory symbol_
    )
        external
        initializer
    {
        if (address(usdc_) == address(0)) revert InvalidConfig();
        if (governance_ == address(0) || operator_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();

        __ERC20_init(name_, symbol_);
        __ERC4626_init(usdc_);

        VaultStorage.Layout storage s = VaultStorage.load();
        s.governance = governance_;
        s.operator = operator_;
        s.timelockDelay = timelockDelay_;
        // perpEngine is intentionally unset at init — set later via the timelocked proposal flow.
        // This breaks the circular deploy dependency: PerpEngine needs the vault address at
        // construction; the vault sets the engine address afterwards.
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != VaultStorage.load().governance) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != VaultStorage.load().operator) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyPerpEngine() {
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.perpEngine == address(0)) revert PerpEngineNotSet();
        if (msg.sender != s.perpEngine) revert Unauthorized(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // ERC-4626 overrides
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Returns `freeAssets()` — the bucket that LP shares are redeemable from. Locked
    ///      collateral, insurance fund, and treasury fees sit in the same USDC contract balance
    ///      but do not back shares. See contract NatSpec.
    function totalAssets() public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return freeAssets();
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function maxDeposit(address) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (VaultStorage.load().depositsPaused) return 0;
        return type(uint256).max;
    }

    function maxMint(address) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (VaultStorage.load().depositsPaused) return 0;
        return type(uint256).max;
    }

    function maxWithdraw(address ownerAddr)
        public
        view
        virtual
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        if (VaultStorage.load().withdrawalsPaused) return 0;
        // Cap at freeAssets — locked collateral / fees / insurance are not redeemable.
        return Math.min(super.maxWithdraw(ownerAddr), freeAssets());
    }

    function maxRedeem(address ownerAddr)
        public
        view
        virtual
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        if (VaultStorage.load().withdrawalsPaused) return 0;
        uint256 byOwner = super.maxRedeem(ownerAddr);
        // Convert the freeAssets cap into shares using floor rounding so we don't grant more
        // share-redemptions than freeAssets can satisfy.
        uint256 freeAssetsAsShares = _convertToShares(freeAssets(), Math.Rounding.Floor);
        return Math.min(byOwner, freeAssetsAsShares);
    }

    /// @dev Pause state is enforced upstream: `maxWithdraw` and `maxRedeem` return 0 when
    ///      `withdrawalsPaused`, so the inherited `withdraw` / `redeem` revert with the standard
    ///      `ERC4626ExceededMaxWithdraw` / `ERC4626ExceededMaxRedeem` before reaching here. The
    ///      `freeAssets` cap is the load-bearing check: it prevents withdrawals from dipping into
    ///      locked collateral, fees, or insurance funds even on an unanticipated `max*` regression.
    function _withdraw(
        address caller,
        address receiver,
        address ownerAddr,
        uint256 assets,
        uint256 shares
    )
        internal
        virtual
        override
    {
        uint256 free = freeAssets();
        if (assets > free) revert InsufficientFreeAssets(assets, free);
        super._withdraw(caller, receiver, ownerAddr, assets, shares);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        // Pause-state is enforced via `maxDeposit == 0`. AmountZero stays here as a positive
        // guard against share-mint-of-zero, which would otherwise be a silent no-op for the LP.
        if (assets == 0) revert AmountZero();
        super._deposit(caller, receiver, assets, shares);
    }

    // ------------------------------------------------------------------------------------------
    // Slippage-protected wrappers
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILPVault
    function depositWithMinShares(
        uint256 assets,
        address receiver,
        uint256 minShares
    )
        external
        nonReentrant
        returns (uint256 shares)
    {
        shares = deposit(assets, receiver);
        if (shares < minShares) revert MinSharesNotMet(minShares, shares);
    }

    /// @inheritdoc ILPVault
    function withdrawWithMaxAssets(
        uint256 shares,
        address receiver,
        address owner_,
        uint256 maxAssets
    )
        external
        nonReentrant
        returns (uint256 assets)
    {
        assets = redeem(shares, receiver, owner_);
        if (assets > maxAssets) revert MaxAssetsExceeded(maxAssets, assets);
    }

    // ------------------------------------------------------------------------------------------
    // Operator entrypoints (PerpEngine only)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILPVault
    function openPositionFlow(
        address trader,
        uint256 collateralToLock,
        uint256 fee,
        uint256 lpRebate,
        uint256 insuranceShare
    )
        external
        nonReentrant
        onlyPerpEngine
    {
        if (collateralToLock == 0) revert AmountZero();
        if (lpRebate + insuranceShare > fee) revert FeeSplitInvalid(fee, lpRebate, insuranceShare);

        VaultStorage.Layout storage s = VaultStorage.load();

        // Single transferFrom for collateral + fee; cheaper than two pulls.
        IERC20(asset()).safeTransferFrom(trader, address(this), collateralToLock + fee);

        s.positionCollateral += collateralToLock;
        s.insuranceFundBalance += insuranceShare;
        // Residual = fee − lpRebate − insuranceShare. Subtraction-based form ensures rounding
        // dust never disappears: the sum of (lpRebate stays in freeAssets, insuranceShare,
        // residual to accruedFees) exactly equals `fee`.
        s.accruedFees += fee - lpRebate - insuranceShare;

        emit PositionOpenedOnVault(trader, collateralToLock, fee, lpRebate, insuranceShare);
        emit CollateralLocked(trader, collateralToLock);
    }

    /// @inheritdoc ILPVault
    function settlePosition(
        address trader,
        uint256 collateralToRelease,
        int256 pnl,
        uint256 fee,
        uint256 lpRebate,
        uint256 insuranceShare
    )
        external
        nonReentrant
        onlyPerpEngine
    {
        if (collateralToRelease == 0) revert AmountZero();
        if (lpRebate + insuranceShare > fee) revert FeeSplitInvalid(fee, lpRebate, insuranceShare);

        VaultStorage.Layout storage s = VaultStorage.load();
        if (collateralToRelease > s.positionCollateral) {
            revert InsufficientPositionCollateral(collateralToRelease, s.positionCollateral);
        }

        // returnedSigned = collateralToRelease + pnl − fee. Reverts if negative — v0 rejects
        // voluntary close into negative equity; LiquidationEngine handles those (week 14+).
        int256 returnedSigned = int256(collateralToRelease) + pnl - int256(fee);
        if (returnedSigned < 0) revert UnderwaterClose(collateralToRelease, pnl, fee);
        uint256 returned = uint256(returnedSigned);

        s.positionCollateral -= collateralToRelease;
        s.insuranceFundBalance += insuranceShare;
        s.accruedFees += fee - lpRebate - insuranceShare;

        if (returned > 0) {
            IERC20(asset()).safeTransfer(trader, returned);
        }

        emit PositionSettledOnVault(trader, collateralToRelease, pnl, fee, lpRebate, insuranceShare, returned);
        emit CollateralReleased(trader, collateralToRelease);
    }

    /// @inheritdoc ILPVault
    function lockCollateral(address from, uint256 amount) external nonReentrant onlyPerpEngine {
        if (amount == 0) revert AmountZero();
        IERC20(asset()).safeTransferFrom(from, address(this), amount);
        VaultStorage.load().positionCollateral += amount;
        emit CollateralLocked(from, amount);
    }

    /// @inheritdoc ILPVault
    function releaseCollateral(address to, uint256 amount) external nonReentrant onlyPerpEngine {
        if (amount == 0) revert AmountZero();
        VaultStorage.Layout storage s = VaultStorage.load();
        if (amount > s.positionCollateral) revert InsufficientPositionCollateral(amount, s.positionCollateral);
        s.positionCollateral -= amount;
        IERC20(asset()).safeTransfer(to, amount);
        emit CollateralReleased(to, amount);
    }

    // ------------------------------------------------------------------------------------------
    // Insurance fund seeding (Fix #6) — governance only, no timelock, capped cumulatively
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILPVault
    function seedInsurance(uint256 amount) external nonReentrant onlyGovernance {
        if (amount == 0) revert AmountZero();
        VaultStorage.Layout storage s = VaultStorage.load();
        uint256 newCumulative = s.insuranceSeedDeposited + amount;
        if (newCumulative > MAX_INSURANCE_SEED) {
            revert InsuranceSeedCapExceeded(newCumulative, MAX_INSURANCE_SEED);
        }
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        s.insuranceFundBalance += amount;
        s.insuranceSeedDeposited = newCumulative;
        emit InsuranceSeeded(msg.sender, amount, newCumulative);
    }

    // ------------------------------------------------------------------------------------------
    // Treasury fee withdrawal (Fix #5) — governance, timelocked
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILPVault
    /// @dev Spec §3 fee structure leaves a 10% residual unallocated; we route it to `accruedFees`
    ///      and expose it via this timelocked withdrawal flow. Single in-flight per the
    ///      `pendingPerpEngine` pattern. Pause flags do NOT gate this — treasury operations are
    ///      independent of LP deposit/withdrawal halts.
    function proposeFeeWithdrawal(address recipient, uint256 amount) external onlyGovernance {
        if (recipient == address(0)) revert InvalidConfig();
        if (amount == 0) revert AmountZero();
        VaultStorage.Layout storage s = VaultStorage.load();
        if (amount > s.accruedFees) revert InsufficientAccruedFees(amount, s.accruedFees);
        if (s.pendingFeeWithdrawal.exists) revert PendingProposalExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingFeeWithdrawal = VaultStorage.PendingFeeWithdrawal({
            recipient: recipient,
            amount: amount,
            activatesAt: activatesAt,
            exists: true
        });
        emit FeeWithdrawalProposed(recipient, amount, activatesAt);
    }

    /// @inheritdoc ILPVault
    function activateFeeWithdrawal() external nonReentrant {
        VaultStorage.Layout storage s = VaultStorage.load();
        VaultStorage.PendingFeeWithdrawal memory p = s.pendingFeeWithdrawal;
        if (!p.exists) revert NoPendingProposal();
        if (block.timestamp < p.activatesAt) revert TimelockNotElapsed(p.activatesAt);
        // Defensive re-check: between propose and activate the residual could have moved (it
        // only ever grows in v0, but a future contract version could decrement it).
        if (p.amount > s.accruedFees) revert InsufficientAccruedFees(p.amount, s.accruedFees);
        s.accruedFees -= p.amount;
        delete s.pendingFeeWithdrawal;
        IERC20(asset()).safeTransfer(p.recipient, p.amount);
        emit FeeWithdrawalActivated(p.recipient, p.amount);
    }

    /// @inheritdoc ILPVault
    function cancelFeeWithdrawal() external onlyGovernance {
        VaultStorage.Layout storage s = VaultStorage.load();
        VaultStorage.PendingFeeWithdrawal memory p = s.pendingFeeWithdrawal;
        if (!p.exists) revert NoPendingProposal();
        delete s.pendingFeeWithdrawal;
        emit FeeWithdrawalCancelled(p.recipient, p.amount);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: setPerpEngine (timelocked)
    // ------------------------------------------------------------------------------------------

    function proposeSetPerpEngine(address newEngine) external onlyGovernance {
        if (newEngine == address(0)) revert InvalidConfig();
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.pendingPerpEngineActivatesAt != 0) revert PendingProposalExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingPerpEngine = newEngine;
        s.pendingPerpEngineActivatesAt = activatesAt;
        emit PerpEngineProposed(newEngine, activatesAt);
    }

    function activateSetPerpEngine() external {
        VaultStorage.Layout storage s = VaultStorage.load();
        uint64 readyAt = s.pendingPerpEngineActivatesAt;
        if (readyAt == 0) revert NoPendingProposal();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldEngine = s.perpEngine;
        address newEngine = s.pendingPerpEngine;
        s.perpEngine = newEngine;
        delete s.pendingPerpEngine;
        delete s.pendingPerpEngineActivatesAt;
        emit PerpEngineActivated(oldEngine, newEngine);
    }

    function cancelSetPerpEngine() external onlyGovernance {
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.pendingPerpEngineActivatesAt == 0) revert NoPendingProposal();
        address pending = s.pendingPerpEngine;
        delete s.pendingPerpEngine;
        delete s.pendingPerpEngineActivatesAt;
        emit PerpEngineCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: governance transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    function proposeGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidConfig();
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.pendingGovernanceActivatesAt != 0) revert PendingProposalExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingGovernance = newGovernance;
        s.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGovernance, activatesAt);
    }

    function activateGovernanceTransfer() external {
        VaultStorage.Layout storage s = VaultStorage.load();
        uint64 readyAt = s.pendingGovernanceActivatesAt;
        if (readyAt == 0) revert NoPendingProposal();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldGov = s.governance;
        address newGov = s.pendingGovernance;
        s.governance = newGov;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferActivated(oldGov, newGov);
    }

    function cancelGovernanceTransfer() external onlyGovernance {
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.pendingGovernanceActivatesAt == 0) revert NoPendingProposal();
        address pending = s.pendingGovernance;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Operator: pause toggles. Governance: setOperator.
    // ------------------------------------------------------------------------------------------

    function setDepositsPaused(bool paused) external onlyOperator {
        VaultStorage.load().depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

    function setWithdrawalsPaused(bool paused) external onlyOperator {
        VaultStorage.load().withdrawalsPaused = paused;
        emit WithdrawalsPausedSet(paused);
    }

    /// @notice Rotate the operator address. Governance only, NO timelock — the operator's
    ///         power is narrowly scoped to pause toggles, so fast rotation is the right
    ///         emergency response if the operator multi-sig is compromised.
    function setOperator(address newOperator) external onlyGovernance {
        if (newOperator == address(0)) revert InvalidConfig();
        VaultStorage.Layout storage s = VaultStorage.load();
        address old = s.operator;
        s.operator = newOperator;
        emit OperatorSet(old, newOperator);
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILPVault
    /// @dev Computed: `balance(USDC) − positionCollateral − insuranceFundBalance − accruedFees`.
    ///      Saturates at 0 if the bookkeepers somehow exceed balance (invariant break) so this
    ///      view stays callable during incident response. Production state-changing flows still
    ///      enforce solvency via the bookkeeper-decrement-before-transfer ordering.
    function freeAssets() public view returns (uint256) {
        VaultStorage.Layout storage s = VaultStorage.load();
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 booked = s.positionCollateral + s.insuranceFundBalance + s.accruedFees;
        return balance > booked ? balance - booked : 0;
    }

    function positionCollateral() external view returns (uint256) {
        return VaultStorage.load().positionCollateral;
    }

    function insuranceFundBalance() external view returns (uint256) {
        return VaultStorage.load().insuranceFundBalance;
    }

    function accruedFees() external view returns (uint256) {
        return VaultStorage.load().accruedFees;
    }

    function depositsPaused() external view returns (bool) {
        return VaultStorage.load().depositsPaused;
    }

    function withdrawalsPaused() external view returns (bool) {
        return VaultStorage.load().withdrawalsPaused;
    }

    function perpEngine() external view returns (address) {
        return VaultStorage.load().perpEngine;
    }

    function operator() external view returns (address) {
        return VaultStorage.load().operator;
    }

    function governance() external view returns (address) {
        return VaultStorage.load().governance;
    }

    function timelockDelay() external view returns (uint32) {
        return VaultStorage.load().timelockDelay;
    }

    function pendingPerpEngine() external view returns (address account, uint64 activatesAt) {
        VaultStorage.Layout storage s = VaultStorage.load();
        return (s.pendingPerpEngine, s.pendingPerpEngineActivatesAt);
    }

    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        VaultStorage.Layout storage s = VaultStorage.load();
        return (s.pendingGovernance, s.pendingGovernanceActivatesAt);
    }

    function insuranceSeedDeposited() external view returns (uint256) {
        return VaultStorage.load().insuranceSeedDeposited;
    }

    function pendingFeeWithdrawal()
        external
        view
        returns (address recipient, uint256 amount, uint64 activatesAt, bool exists)
    {
        VaultStorage.PendingFeeWithdrawal memory p = VaultStorage.load().pendingFeeWithdrawal;
        return (p.recipient, p.amount, p.activatesAt, p.exists);
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
