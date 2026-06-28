// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILPVault} from "../core/ILPVault.sol";
import {IFeedbackController} from "../feedback/IFeedbackController.sol";
import {UMAAdapter} from "../oracle/UMAAdapter.sol";
import {EventMarket} from "./EventMarket.sol";
import {IEventMarket} from "./IEventMarket.sol";
import {IEventMarketFactory} from "./IEventMarketFactory.sol";

import {LMSRMath} from "./LMSRMath.sol";

contract EventMarketFactory is Initializable, UUPSUpgradeable, IEventMarketFactory {
    using SafeERC20 for IERC20;

    address public governance;
    address public pendingGovernance;
    uint64 public pendingGovernanceActivatesAt;
    uint32 public timelockDelay;

    ILPVault public lpVault;
    IFeedbackController public feedbackController;
    UMAAdapter public umaAdapter;
    IERC20 public usdc;

    address public marketImplementation;

    mapping(bytes32 => address) public markets;
    mapping(bytes32 => uint256) public marketSeeds;

    // --- Operator allowlist + market registry (engine-relayed `*For` path) ---
    // Appended after the original storage to preserve the upgradeable layout.

    /// @notice Allowlisted operators trusted to relay trades on a trader's behalf. The
    ///         EventMarketRouter is registered here so markets accept its `*For` calls.
    mapping(address => bool) public isOperator;

    /// @notice Timestamp at which a pending operator proposal becomes activatable.
    mapping(address => uint64) public pendingOperatorActivatesAt;

    /// @notice True for every market clone this factory has created. The router checks this
    ///         before pulling trader USDC so it can only ever route into a genuine market.
    mapping(address => bool) public isMarket;

    event MarketCreated(bytes32 indexed eventId, address market, bytes32 subjectId);
    event OperatorProposed(address indexed operator, uint64 activatesAt);
    event OperatorActivated(address indexed operator);
    event OperatorCancelled(address indexed operator);
    event OperatorRemoved(address indexed operator);

    error Unauthorized();
    error InvalidConfig();
    error OperatorAlreadySet(address operator);
    error PendingOperatorExists(address operator);
    error NoPendingOperator(address operator);
    error TimelockNotElapsed(uint64 readyAt);
    error OperatorNotSet(address operator);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address governance_,
        uint32 timelockDelay_,
        ILPVault lpVault_,
        IFeedbackController feedbackController_,
        UMAAdapter umaAdapter_,
        IERC20 usdc_,
        address marketImplementation_
    )
        external
        initializer
    {
        if (governance_ == address(0) || marketImplementation_ == address(0)) revert InvalidConfig();
        governance = governance_;
        timelockDelay = timelockDelay_;
        lpVault = lpVault_;
        feedbackController = feedbackController_;
        umaAdapter = umaAdapter_;
        usdc = usdc_;
        marketImplementation = marketImplementation_;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    function createMarket(
        bytes32 subjectId,
        bytes32 eventId,
        uint8 eventClass,
        string calldata question,
        uint64 resolutionDeadline,
        uint256 initialLiquidity,
        uint256 lmsrB
    )
        external
        onlyGovernance
        returns (address)
    {
        require(markets[eventId] == address(0), "EventMarketFactory: already exists");

        address clone = Clones.clone(marketImplementation);

        // Calculate the initial LMSR seed liquidity
        uint256 originalSeed = LMSRMath.cost(0, 0, lmsrB);
        marketSeeds[eventId] = originalSeed;

        // Pull seed liquidity from LPVault to this factory, then send to the newly cloned market
        lpVault.fundEventMarket(originalSeed);
        usdc.safeTransfer(clone, originalSeed);

        IEventMarket.MarketParams memory params = IEventMarket.MarketParams({
            subjectId: subjectId,
            eventId: eventId,
            eventClass: eventClass,
            question: question,
            resolutionDeadline: resolutionDeadline,
            initialLiquidity: initialLiquidity,
            lmsrB: lmsrB
        });

        EventMarket(clone).initialize(usdc, umaAdapter, params);

        markets[eventId] = clone;
        isMarket[clone] = true;
        emit MarketCreated(eventId, clone, subjectId);

        return clone;
    }

    // ------------------------------------------------------------------------------------------
    // Governance: operator allowlist (timelocked add / immediate remove)
    //
    // Mirrors the perp router allowlist (`proposeAddRouter` / `activateAddRouter` / `removeRouter`).
    // Operators gain the ability to call `*For` entrypoints on every market on activation; a
    // compromised operator is cut off without delay via `removeOperator` (governance kill switch).
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IEventMarketFactory
    function proposeAddOperator(address operator) external onlyGovernance {
        if (operator == address(0)) revert InvalidConfig();
        if (isOperator[operator]) revert OperatorAlreadySet(operator);
        if (pendingOperatorActivatesAt[operator] != 0) revert PendingOperatorExists(operator);
        uint64 activatesAt = uint64(block.timestamp + timelockDelay);
        pendingOperatorActivatesAt[operator] = activatesAt;
        emit OperatorProposed(operator, activatesAt);
    }

    /// @inheritdoc IEventMarketFactory
    function activateAddOperator(address operator) external {
        uint64 readyAt = pendingOperatorActivatesAt[operator];
        if (readyAt == 0) revert NoPendingOperator(operator);
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        delete pendingOperatorActivatesAt[operator];
        isOperator[operator] = true;
        emit OperatorActivated(operator);
    }

    /// @inheritdoc IEventMarketFactory
    function cancelAddOperator(address operator) external onlyGovernance {
        if (pendingOperatorActivatesAt[operator] == 0) revert NoPendingOperator(operator);
        delete pendingOperatorActivatesAt[operator];
        emit OperatorCancelled(operator);
    }

    /// @inheritdoc IEventMarketFactory
    function removeOperator(address operator) external onlyGovernance {
        if (!isOperator[operator]) revert OperatorNotSet(operator);
        delete isOperator[operator];
        emit OperatorRemoved(operator);
    }

    function getMarket(bytes32 eventId) external view returns (address) {
        return markets[eventId];
    }

    function onMarketResolved(
        bytes32 subjectId,
        bytes32 eventId,
        uint8 eventClass,
        int256 outcomeScore_e18,
        uint256 returnedAmount
    )
        external
    {
        address market = markets[eventId];
        require(msg.sender == market, "EventMarketFactory: unauthorized caller");

        uint256 originalSeed = marketSeeds[eventId];

        // Send the returned amount back to LPVault
        usdc.forceApprove(address(lpVault), returnedAmount);
        lpVault.settleEventMarket(originalSeed, returnedAmount);

        // Send resolution feedback
        IFeedbackController.ResolutionInput memory input = IFeedbackController.ResolutionInput({
            subjectId: subjectId,
            eventClass: IFeedbackController.EventClass(eventClass),
            outcomeScore_e18: outcomeScore_e18,
            eventTimestamp: uint64(block.timestamp) // using current timestamp as resolution time
        });
        feedbackController.applyResolution(input);
    }

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
