// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {IInsuranceFund} from "./IInsuranceFund.sol";

/// @title InsuranceFund — standalone USDC reserve for People Markets (spec §3 line 162).
/// @notice Holds the insurance USDC under a multi-sig DISTINCT from the LPVault operations
///         multi-sig. LPVault is the only address allowed to accrue or draw; anyone may deposit.
///
/// @dev    UUPS upgradeable, namespaced storage at `keccak256("people.markets.insurancefund.v1")`.
///         The contract tracks its own `trackedBalance` instead of trusting `usdc.balanceOf(this)`:
///           - `deposit` / `accrue` / `drawShortfall` mutate `trackedBalance` in lock-step with USDC
///             transfers.
///           - Direct ERC-20 transfers to this contract (donation games) inflate `balanceOf` but
///             NOT `trackedBalance`. The LPVault cap math reads `balance()` (which returns
///             `trackedBalance`), so donation-driven cap inflation is structurally impossible.
///
/// @dev    Governance + timelock pattern mirrors `FundingEngine`: propose / activate / cancel,
///         bounds [1h, 30d]. `setLPVault` is governance-only but NOT timelocked — matches the
///         `setOperator` fast-lever on LPVault for compromised-key cut-off.
contract InsuranceFund is Initializable, UUPSUpgradeable, ReentrancyGuard, IInsuranceFund {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    uint32 public constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 public constant MAX_TIMELOCK_DELAY = 30 days;

    // ------------------------------------------------------------------------------------------
    // Namespaced storage
    // ------------------------------------------------------------------------------------------

    bytes32 internal constant INSURANCE_FUND_SLOT = keccak256("people.markets.insurancefund.v1");

    /// @custom:storage-location erc7201:people.markets.insurancefund.v1
    struct Layout {
        // governance + timelock
        address governance;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        uint32 timelockDelay;
        // USDC token. Immutable after init.
        IERC20 usdc;
        // LP vault that may call `accrue` and `drawShortfall`. Governance-rotatable, no timelock.
        address lpVault;
        // Tracked balance. Equals `usdc.balanceOf(this)` minus donation USDC (we ignore donations).
        uint256 trackedBalance;
    }

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = INSURANCE_FUND_SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ------------------------------------------------------------------------------------------
    // Initializer
    // ------------------------------------------------------------------------------------------

    /// @notice Initialize the fund. One-time, called via the proxy.
    /// @param  governance_     Insurance multi-sig — distinct from the LPVault governance per spec
    ///                         §3 line 162. Timelocked admin.
    /// @param  lpVault_        Live LPVault address. Only this address may `accrue` or
    ///                         `drawShortfall`. Pre-approval (`LPVault.approveInsuranceFund`) is a
    ///                         one-time governance call after deploy.
    /// @param  usdc_           Underlying ERC-20. On Base mainnet this is canonical USDC.
    /// @param  timelockDelay_  Seconds. Bounds [1h, 30d].
    function initialize(
        address governance_,
        address lpVault_,
        IERC20 usdc_,
        uint32 timelockDelay_
    )
        external
        initializer
    {
        if (governance_ == address(0) || lpVault_ == address(0) || address(usdc_) == address(0)) {
            revert InvalidConfig();
        }
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();

        Layout storage s = _s();
        s.governance = governance_;
        s.lpVault = lpVault_;
        s.usdc = usdc_;
        s.timelockDelay = timelockDelay_;

        emit Initialized(governance_, lpVault_, address(usdc_));
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != _s().governance) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyLPVault() {
        if (msg.sender != _s().lpVault) revert NotLPVault(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // Counterparty flows
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IInsuranceFund
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();
        Layout storage s = _s();
        s.usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 newBalance = s.trackedBalance + amount;
        s.trackedBalance = newBalance;
        emit Deposited(msg.sender, amount, newBalance);
    }

    /// @inheritdoc IInsuranceFund
    function accrue(uint256 amount) external nonReentrant onlyLPVault {
        if (amount == 0) revert AmountZero();
        Layout storage s = _s();
        // Pull USDC from the configured LPVault. LPVault pre-approves `type(uint256).max` via
        // `approveInsuranceFund()`. The transferFrom + bookkeeper bump happen atomically; if the
        // pull fails (e.g. approval revoked) the whole settle reverts on the LPVault side.
        // slither-disable-next-line arbitrary-send-erc20 -- onlyLPVault; `from` is the configured, pre-approved vault.
        s.usdc.safeTransferFrom(s.lpVault, address(this), amount);
        uint256 newBalance = s.trackedBalance + amount;
        s.trackedBalance = newBalance;
        emit AccruedFromVault(amount, newBalance);
    }

    /// @inheritdoc IInsuranceFund
    function drawShortfall(address recipient, uint256 amount) external nonReentrant onlyLPVault {
        if (amount == 0) revert AmountZero();
        if (recipient == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        uint256 tracked = s.trackedBalance;
        if (amount > tracked) revert InsufficientBalance(amount, tracked);
        uint256 newBalance = tracked - amount;
        s.trackedBalance = newBalance;
        s.usdc.safeTransfer(recipient, amount);
        emit ShortfallDrawn(recipient, amount, newBalance);
    }

    // ------------------------------------------------------------------------------------------
    // Governance
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IInsuranceFund
    /// @dev Governance-only, NO timelock — fast cut-off mirrors LPVault.setOperator.
    function setLPVault(address newLPVault) external onlyGovernance {
        if (newLPVault == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        address old = s.lpVault;
        s.lpVault = newLPVault;
        emit LPVaultSet(old, newLPVault);
    }

    /// @inheritdoc IInsuranceFund
    function proposeGovernanceTransfer(address newGov) external onlyGovernance {
        if (newGov == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        if (s.pendingGovernanceActivatesAt != 0) revert PendingGovernanceTransferExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingGovernance = newGov;
        s.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGov, activatesAt);
    }

    /// @inheritdoc IInsuranceFund
    function activateGovernanceTransfer() external {
        Layout storage s = _s();
        uint64 readyAt = s.pendingGovernanceActivatesAt;
        if (readyAt == 0) revert NoPendingGovernanceTransfer();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldGov = s.governance;
        address newGov = s.pendingGovernance;
        s.governance = newGov;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferActivated(oldGov, newGov);
    }

    /// @inheritdoc IInsuranceFund
    function cancelGovernanceTransfer() external onlyGovernance {
        Layout storage s = _s();
        if (s.pendingGovernanceActivatesAt == 0) revert NoPendingGovernanceTransfer();
        address pending = s.pendingGovernance;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IInsuranceFund
    function balance() external view returns (uint256) {
        return _s().trackedBalance;
    }

    /// @inheritdoc IInsuranceFund
    function usdc() external view returns (address) {
        return address(_s().usdc);
    }

    /// @inheritdoc IInsuranceFund
    function lpVault() external view returns (address) {
        return _s().lpVault;
    }

    /// @inheritdoc IInsuranceFund
    function governance() external view returns (address) {
        return _s().governance;
    }

    /// @inheritdoc IInsuranceFund
    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        Layout storage s = _s();
        return (s.pendingGovernance, s.pendingGovernanceActivatesAt);
    }

    /// @inheritdoc IInsuranceFund
    function timelockDelay() external view returns (uint32) {
        return _s().timelockDelay;
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
