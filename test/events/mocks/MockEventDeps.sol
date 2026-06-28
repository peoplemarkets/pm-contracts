// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IFeedbackController} from "../../../src/feedback/IFeedbackController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal LPVault stand-in for EventMarketFactory tests. The factory calls
///         `fundEventMarket` (expects to receive `amount` USDC) and `settleEventMarket` (the factory
///         approves it `returnedAmount` beforehand). We avoid pulling the full perp LPVault into the
///         event-market unit tests; the resolve→settle accounting is covered by the LPVault suite.
contract MockLPVault {
    IERC20 public immutable usdc;
    uint256 public lastSeed;
    uint256 public lastReturned;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    /// @dev Send `amount` USDC to the caller (the factory), modelling seed funding.
    function fundEventMarket(uint256 amount) external {
        usdc.transfer(msg.sender, amount);
    }

    /// @dev Pull `returnedAmount` back from the caller (the factory approved us first).
    function settleEventMarket(uint256 originalSeed, uint256 returnedAmount) external {
        lastSeed = originalSeed;
        lastReturned = returnedAmount;
        if (returnedAmount > 0) {
            usdc.transferFrom(msg.sender, address(this), returnedAmount);
        }
    }
}

/// @notice No-op FeedbackController for event-market tests; the factory calls `applyResolution`
///         on resolve. Feedback math is covered by FeedbackController.t.sol.
contract MockFeedbackController {
    IFeedbackController.ResolutionInput public lastInput;
    bool public called;

    function applyResolution(IFeedbackController.ResolutionInput calldata input) external {
        lastInput = input;
        called = true;
    }
}

/// @notice Mock of the concrete UMAAdapter type the market/factory hold. We only need
///         `proposeAssertion` (no-op) and `latestValue` (settable) for resolution tests, so we cast
///         this address to `UMAAdapter` when wiring the factory. The runtime call dispatches here.
contract MockUMAAdapter {
    uint256 internal _value;
    uint64 internal _ts;

    function setLatestValue(uint256 value_, uint64 ts_) external {
        _value = value_;
        _ts = ts_;
    }

    function proposeAssertion(bytes32, uint256 claimedValue, bytes calldata) external returns (bytes32) {
        // Simulate an immediately-settled truthful assertion for test convenience.
        _value = claimedValue;
        _ts = uint64(block.timestamp);
        return keccak256(abi.encode(claimedValue, block.timestamp));
    }

    function latestValue(bytes32) external view returns (uint256 value, uint64 valueTimestamp) {
        return (_value, _ts);
    }
}

/// @notice Malicious ERC20-callback reentrancy probe. On receiving a transfer it re-enters the
///         market's buyOutcome; the market's nonReentrant guard must revert. Used only to prove the
///         reentrancy guard — real USDC has no transfer hooks.
contract ReentrantToken is IERC20 {
    string public name = "Reentrant";
    string public symbol = "RE";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public attackTarget;
    bool public attackArmed;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function arm(address target) external {
        attackTarget = target;
        attackArmed = true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        // Re-enter on the way in (during the market's safeTransferFrom).
        if (attackArmed && attackTarget != address(0)) {
            attackArmed = false;
            (bool ok,) =
                attackTarget.call(abi.encodeWithSignature("buyOutcome(bool,uint256,uint256)", true, amount, uint256(0)));
            require(ok, "reentry blocked");
        }
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
