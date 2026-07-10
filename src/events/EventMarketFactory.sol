// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILPVault} from "../core/ILPVault.sol";
import {IFeedbackController} from "../feedback/IFeedbackController.sol";
import {IOracleRouter} from "../oracle/IOracleRouter.sol";
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

    // --- Market implementation setter (governance-timelocked) ---
    // APPEND-ONLY. `isMarket` occupies slot 11; the two fields below PACK into a single new word,
    // slot 12 (address at offset 0 + uint64 at offset 20 = 28 bytes). Slot 13 stays free. They
    // MUST stay at the end of storage so this contract stays layout-compatible when upgraded onto
    // the live proxy (0xb73f) — do NOT reorder or insert anything above them.

    /// @notice Market implementation pending activation (0 if none). `createMarket` keeps cloning
    ///         `marketImplementation` until `activateSetMarketImplementation` promotes this pending
    ///         value once its timelock has elapsed. Slot 12.
    address public pendingMarketImplementation;

    /// @notice Timestamp at which `pendingMarketImplementation` becomes activatable (0 if none).
    ///         Packed into slot 12 at byte offset 20 (alongside `pendingMarketImplementation`).
    uint64 public pendingMarketImplementationActivatesAt;

    event MarketCreated(bytes32 indexed eventId, address market, bytes32 subjectId);
    event OperatorProposed(address indexed operator, uint64 activatesAt);
    event OperatorActivated(address indexed operator);
    event OperatorCancelled(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event MarketImplementationProposed(address indexed newImplementation, uint64 activatesAt);
    event MarketImplementationActivated(address indexed oldImplementation, address indexed newImplementation);
    event MarketImplementationCancelled(address indexed newImplementation);

    error Unauthorized();
    error InvalidConfig();
    error OperatorAlreadySet(address operator);
    error PendingOperatorExists(address operator);
    error NoPendingOperator(address operator);
    error TimelockNotElapsed(uint64 readyAt);
    error OperatorNotSet(address operator);
    error PendingImplementationExists(address implementation);
    error NoPendingImplementation();
    /// @dev Fix D (resolution-readiness gate): thrown by `createMarket*` when the market's
    ///      resolution metric is not yet registered/ready, so it could never settle. `id` is the
    ///      UMA `eventId` (UMA source) or the OracleRouter `metricId` (ORACLE_ROUTER source).
    error MetricNotReady(bytes32 id);

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

    /// @notice Create a market resolved via the DEFAULT UMA path (unchanged 7-arg signature; ABI +
    ///         existing tests untouched). Reverts `MetricNotReady` if the UMA metric for `eventId`
    ///         is not yet registered (Fix D readiness gate — closes the trapped-funds trap on the
    ///         default path too).
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
        // Empty ResolutionConfig => source == UMA (zero-value default). The legacy behaviour.
        IEventMarket.ResolutionConfig memory rc;
        return _create(subjectId, eventId, eventClass, question, resolutionDeadline, initialLiquidity, lmsrB, rc);
    }

    /// @notice Create a market with an explicit resolution source. Pass `rc.source == UMA` for the
    ///         subjective path (`rc`'s other fields ignored) or `rc.source == ORACLE_ROUTER` for an
    ///         objective numeric metric + threshold + comparator. Same first 7 args as `createMarket`
    ///         plus the config; a distinct selector so the legacy ABI is preserved. Reverts
    ///         `MetricNotReady` if the declared metric is not registered/active (Fix D).
    function createMarketWithResolution(
        bytes32 subjectId,
        bytes32 eventId,
        uint8 eventClass,
        string calldata question,
        uint64 resolutionDeadline,
        uint256 initialLiquidity,
        uint256 lmsrB,
        IEventMarket.ResolutionConfig calldata rc
    )
        external
        onlyGovernance
        returns (address)
    {
        return _create(subjectId, eventId, eventClass, question, resolutionDeadline, initialLiquidity, lmsrB, rc);
    }

    /// @dev Shared creation path for both entrypoints. Runs the Fix D resolution-readiness gate
    ///      BEFORE any cloning/funding, then clones + `initializeV2`s + seeds the market. Funnelling
    ///      both public entrypoints through here guarantees the readiness gate cannot be bypassed.
    function _create(
        bytes32 subjectId,
        bytes32 eventId,
        uint8 eventClass,
        string memory question,
        uint64 resolutionDeadline,
        uint256 initialLiquidity,
        uint256 lmsrB,
        IEventMarket.ResolutionConfig memory rc
    )
        internal
        returns (address)
    {
        require(markets[eventId] == address(0), "EventMarketFactory: already exists");

        // --- Fix D: resolution-readiness gate. A market whose metric can never settle would trap
        // funds forever; refuse to create it. Checked for BOTH sources, BEFORE cloning/funding. ---
        if (rc.source == IEventMarket.ResolutionSource.UMA) {
            // eventId IS the UMA metricId. It must be registered (propose->activate on UMAAdapter).
            if (!umaAdapter.metricOf(eventId).registered) revert MetricNotReady(eventId);
        } else {
            // ORACLE_ROUTER: the metric must be registered/active on the router.
            if (IOracleRouter(rc.oracleRouter).configOf(rc.metricId).sourceType == IOracleRouter.SourceType.UNSET) {
                revert MetricNotReady(rc.metricId);
            }
            // Coherence: an objective settle guarded by settleNotBefore must be reachable at/after
            // the market's own resolution deadline.
            require(rc.settleNotBefore <= resolutionDeadline, "EventMarketFactory: settleNotBefore > deadline");
        }

        address clone = Clones.clone(marketImplementation);

        // Calculate the initial LMSR seed liquidity
        uint256 originalSeed = LMSRMath.cost(0, 0, lmsrB);
        marketSeeds[eventId] = originalSeed;

        IEventMarket.MarketParams memory params = IEventMarket.MarketParams({
            subjectId: subjectId,
            eventId: eventId,
            eventClass: eventClass,
            question: question,
            resolutionDeadline: resolutionDeadline,
            initialLiquidity: initialLiquidity,
            lmsrB: lmsrB
        });

        // Initialize the clone BEFORE it is registered/funded, so that the moment the vault marks it
        // live (`fundEventMarket`) the clone can already answer `currentRecoverable()` (needs usdc /
        // umaAdapter / eventId set). The brief intra-tx window where a registered clone holds 0 USDC
        // is harmless: it is atomic and no external `freeAssets`/NAV read happens between the calls.
        // initializeV2 with rc.source == UMA is byte-for-byte the legacy behaviour.
        EventMarket(clone).initializeV2(usdc, umaAdapter, params, rc);

        // Pull seed liquidity from LPVault (registers `clone` in the live NAV set), then forward it.
        lpVault.fundEventMarket(clone, originalSeed);
        usdc.safeTransfer(clone, originalSeed);

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

    // ------------------------------------------------------------------------------------------
    // Governance: market implementation setter (timelocked)
    //
    // Mirrors the operator allowlist timelock (`proposeAddOperator` / `activateAddOperator` /
    // `cancelAddOperator`). `marketImplementation` is the template every future market clone runs,
    // so installing a new one is the most security-sensitive action on this contract and is gated
    // behind the same two-step `timelockDelay` as operator adds. Existing market clones are frozen
    // at creation time and are unaffected; only markets created AFTER activation use the new impl.
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IEventMarketFactory
    function proposeSetMarketImplementation(address newImpl) external onlyGovernance {
        if (newImpl == address(0) || newImpl.code.length == 0) revert InvalidConfig();
        if (pendingMarketImplementationActivatesAt != 0) {
            revert PendingImplementationExists(pendingMarketImplementation);
        }
        uint64 activatesAt = uint64(block.timestamp + timelockDelay);
        pendingMarketImplementation = newImpl;
        pendingMarketImplementationActivatesAt = activatesAt;
        emit MarketImplementationProposed(newImpl, activatesAt);
    }

    /// @inheritdoc IEventMarketFactory
    function activateSetMarketImplementation() external {
        uint64 readyAt = pendingMarketImplementationActivatesAt;
        if (readyAt == 0) revert NoPendingImplementation();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldImpl = marketImplementation;
        address newImpl = pendingMarketImplementation;
        marketImplementation = newImpl;
        delete pendingMarketImplementation;
        delete pendingMarketImplementationActivatesAt;
        emit MarketImplementationActivated(oldImpl, newImpl);
    }

    /// @inheritdoc IEventMarketFactory
    function cancelSetMarketImplementation() external onlyGovernance {
        if (pendingMarketImplementationActivatesAt == 0) revert NoPendingImplementation();
        address newImpl = pendingMarketImplementation;
        delete pendingMarketImplementation;
        delete pendingMarketImplementationActivatesAt;
        emit MarketImplementationCancelled(newImpl);
    }

    function getMarket(bytes32 eventId) external view returns (address) {
        return markets[eventId];
    }

    function onMarketResolved(
        bytes32 subjectId,
        bytes32 eventId,
        uint8 eventClass,
        int256 outcomeScore_e18,
        uint256 returnedAmount,
        uint256 lockedSurplus
    )
        external
    {
        address market = markets[eventId];
        require(msg.sender == market, "EventMarketFactory: unauthorized caller");

        uint256 originalSeed = marketSeeds[eventId];

        // Send the returned amount back to LPVault and de-register the market from the live NAV set.
        // `lockedSurplus` (the floor→exact surplus) is routed into the vault's receive-only vesting
        // bucket rather than snapped pro-rata to current shareholders.
        usdc.forceApprove(address(lpVault), returnedAmount);
        lpVault.settleEventMarket(market, originalSeed, returnedAmount, lockedSurplus);

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
