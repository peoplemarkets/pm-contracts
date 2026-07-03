// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  TestEventVault — TEST-ONLY minimal seed vault for the World-Cup event stack.
/// @notice DO NOT DEPLOY TO PRODUCTION. This is a stripped-down stand-in for the production
///         {LPVault} that implements only the two entrypoints the {EventMarketFactory} calls:
///         `fundEventMarket` (pay seed liquidity to the factory) and `settleEventMarket` (reclaim
///         the surplus seed after a market resolves). It exists so the private testnet dogfood can
///         stand up a FRESH, isolated event stack with ZERO timelock friction and ZERO risk to the
///         live perp LPVault.
///
/// @dev    The production {LPVault.setEventMarketFactory} flow is timelocked at a hard floor of
///         `MIN_TIMELOCK_DELAY = 1 hour`; wiring the real vault to a fresh factory would force a
///         1-hour wait. This vault wires the factory with a plain owner-only setter — no timelock —
///         and gates both fund/settle calls to that factory so play-money seed can't be drained by
///         a random caller. Fund it by minting/transferring MockUSDC to it before creating markets.
contract TestEventVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public owner;
    address public eventMarketFactory;

    /// @dev Mirrors {LPVault.eventFundedSeed} bookkeeping so tests/operators can sanity-check PnL.
    uint256 public eventFundedSeed;

    event EventMarketFactorySet(address indexed factory);
    event EventMarketFunded(address indexed factory, uint256 amount);
    event EventMarketSettled(address indexed factory, uint256 originalSeed, uint256 returnedAmount, int256 pnl);

    error NotOwner(address caller);
    error NotFactory(address caller);
    error FactoryNotSet();

    constructor(IERC20 usdc_) {
        usdc = usdc_;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    modifier onlyFactory() {
        if (eventMarketFactory == address(0)) revert FactoryNotSet();
        if (msg.sender != eventMarketFactory) revert NotFactory(msg.sender);
        _;
    }

    /// @notice Wire the factory allowed to pull seed liquidity. No timelock (test-only).
    function setEventMarketFactory(address factory_) external onlyOwner {
        eventMarketFactory = factory_;
        emit EventMarketFactorySet(factory_);
    }

    /// @notice Send `amount` USDC seed to the factory (mirrors {LPVault.fundEventMarket}).
    function fundEventMarket(uint256 amount) external onlyFactory {
        eventFundedSeed += amount;
        usdc.safeTransfer(msg.sender, amount);
        emit EventMarketFunded(msg.sender, amount);
    }

    /// @notice Reclaim surplus seed from the factory after a market resolves (mirrors
    ///         {LPVault.settleEventMarket}; the factory approves us `returnedAmount` first).
    function settleEventMarket(uint256 originalSeed, uint256 returnedAmount) external onlyFactory {
        eventFundedSeed -= originalSeed;
        if (returnedAmount > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), returnedAmount);
        }
        emit EventMarketSettled(msg.sender, originalSeed, returnedAmount, int256(returnedAmount) - int256(originalSeed));
    }
}
