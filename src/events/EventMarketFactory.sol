// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IEventMarketFactory} from "./IEventMarketFactory.sol";
import {IEventMarket} from "./IEventMarket.sol";
import {EventMarket} from "./EventMarket.sol";
import {ILPVault} from "../core/ILPVault.sol";
import {IFeedbackController} from "../feedback/IFeedbackController.sol";
import {UMAAdapter} from "../oracle/UMAAdapter.sol";
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

    event MarketCreated(bytes32 indexed eventId, address market, bytes32 subjectId);

    error Unauthorized();
    error InvalidConfig();

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
    ) external initializer {
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
    ) external onlyGovernance returns (address) {
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
        emit MarketCreated(eventId, clone, subjectId);

        return clone;
    }

    function getMarket(bytes32 eventId) external view returns (address) {
        return markets[eventId];
    }

    function onMarketResolved(bytes32 subjectId, bytes32 eventId, uint8 eventClass, int256 outcomeScore_e18, uint256 returnedAmount) external {
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
