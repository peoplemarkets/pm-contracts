// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IPerpEngine} from "../core/IPerpEngine.sol";

/// @title IMatchedFillRouter
/// @notice EIP-712 authorization and atomic two-sided settlement boundary for the perp CLOB.
interface IMatchedFillRouter {
    enum OrderIntent {
        UNSET,
        OPEN,
        CLOSE
    }

    /// @notice One trader-authorized order. Every execution-sensitive field is signed.
    /// @dev V2 supports the zero subaccount and resting OPEN or immediate reduce-only CLOSE
    ///      orders. `quantity` is the signed maximum absolute base quantity in the same units as
    ///      `Position.size`. An OPEN maker may be consumed in deterministic slices while the
    ///      incoming taker still fills its signed quantity completely or not at all.
    ///      A close binds the exact position id so an old resting signature cannot unwind a later
    ///      position. Unsupported shapes fail closed instead of being reinterpreted. `executor`
    ///      binds the order to the matching operator; the EIP-712 domain binds chain and router.
    struct Order {
        address trader;
        address executor;
        bytes32 subaccount;
        bytes32 subjectId;
        bytes32 positionId;
        IPerpEngine.Side side;
        OrderIntent intent;
        uint256 quantity;
        uint256 collateralAmount;
        uint256 limitPrice;
        uint256 maxFee;
        uint16 maxMarkDivergenceBps;
        uint256 nonce;
        uint64 deadline;
        bool reduceOnly;
        bool postOnly;
    }

    struct MatchResult {
        bytes32 makerPositionId;
        bytes32 takerPositionId;
    }

    /// @notice One signed leg in an immediate two-market pair order.
    /// @dev Quantity is exact 1e6 base exposure; price is 1e18 quote/base. The pair trader may
    ///      choose different quantities per leg so equal-dollar exposure does not assume equal
    ///      subject prices.
    struct PairLeg {
        bytes32 subjectId;
        IPerpEngine.Side side;
        uint256 quantity;
        uint256 collateralAmount;
        uint256 limitPrice;
        uint256 maxFee;
        uint16 maxMarkDivergenceBps;
    }

    /// @notice One trader-authorized multileg order consumed against two resting OPEN makers.
    /// @dev The two legs are a single contingency: both execute or neither executes. V1 pair
    ///      orders are immediate and full-fill; they never rest independently in either book.
    struct PairOrder {
        address trader;
        address executor;
        bytes32 subaccount;
        PairLeg legA;
        PairLeg legB;
        uint16 maxNotionalImbalanceBps;
        uint256 nonce;
        uint64 deadline;
        bool postOnly;
    }

    struct PairMatchResult {
        bytes32 makerPositionA;
        bytes32 makerPositionB;
        bytes32 traderPositionA;
        bytes32 traderPositionB;
    }

    function settle(
        bytes32 fillId,
        Order calldata maker,
        bytes calldata makerSignature,
        Order calldata taker,
        bytes calldata takerSignature
    )
        external
        returns (MatchResult memory result);

    function settlePair(
        bytes32 fillId,
        Order calldata makerA,
        bytes calldata makerSignatureA,
        Order calldata makerB,
        bytes calldata makerSignatureB,
        PairOrder calldata pair,
        bytes calldata pairSignature
    )
        external
        returns (PairMatchResult memory result);

    function cancelOrder(Order calldata order) external;
    function cancelPairOrder(PairOrder calldata order) external;
    function invalidateNoncesBelow(uint256 newMinimum) external;

    function hashOrder(Order calldata order) external view returns (bytes32 digest);
    function hashPairOrder(PairOrder calldata order) external view returns (bytes32 digest);
    function filledQuantity(bytes32 orderHash) external view returns (uint256);
    function makerPositionId(bytes32 orderHash) external view returns (bytes32);
    function isPairOrderFilled(bytes32 orderHash) external view returns (bool);
    function isOrderCancelled(bytes32 orderHash) external view returns (bool);
    function isFillUsed(bytes32 fillId) external view returns (bool);
    function minimumValidNonce(address trader) external view returns (uint256);
    function perpEngine() external view returns (address);
    function governance() external view returns (address);
    function pendingGovernance() external view returns (address account, uint64 activatesAt);
    function timelockDelay() external view returns (uint32);
    function domainSeparator() external view returns (bytes32);

    function proposeGovernanceTransfer(address newGovernance) external;
    function activateGovernanceTransfer() external;
    function cancelGovernanceTransfer() external;

    event Initialized(address governance, address perpEngine);
    event MatchedFillSettled(
        bytes32 indexed fillId,
        bytes32 indexed makerOrderHash,
        bytes32 indexed takerOrderHash,
        address maker,
        address taker,
        bytes32 subjectId,
        uint256 executionPrice,
        uint256 quantity,
        OrderIntent makerIntent,
        OrderIntent takerIntent,
        bytes32 makerPositionId,
        bytes32 takerPositionId
    );
    event PairFillSettled(
        bytes32 indexed fillId,
        bytes32 indexed pairOrderHash,
        address indexed trader,
        bytes32 makerAOrderHash,
        bytes32 makerBOrderHash
    );
    event PairLegSettled(
        bytes32 indexed fillId,
        uint8 indexed legIndex,
        bytes32 indexed makerOrderHash,
        bytes32 pairOrderHash,
        address maker,
        address trader,
        bytes32 subjectId,
        uint256 executionPrice,
        uint256 quantity,
        bytes32 makerPositionId,
        bytes32 traderPositionId
    );
    event OrderCancelled(address indexed trader, bytes32 indexed orderHash, uint256 nonce);
    event MinimumValidNonceSet(address indexed trader, uint256 oldMinimum, uint256 newMinimum);
    event GovernanceTransferProposed(address indexed newGovernance, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceTransferCancelled(address indexed pendingGovernance);

    error Unauthorized(address caller);
    error InvalidConfig();
    error PendingProposalExists();
    error NoPendingProposal();
    error TimelockNotElapsed(uint64 readyAt);
    error InvalidOrderIntent(OrderIntent intent);
    error UnsupportedSubaccount(bytes32 subaccount);
    error InvalidPositionBinding(OrderIntent intent, bytes32 positionId);
    error InvalidCollateralForIntent(OrderIntent intent, uint256 collateralAmount);
    error InvalidReduceOnlyForIntent(OrderIntent intent, bool reduceOnly);
    error CloseMustBeImmediate();
    error PairMustBeImmediate();
    error CloseMakerUnsupported();
    error InvalidPairSubjects(bytes32 subjectA, bytes32 subjectB);
    error InvalidPairSides(IPerpEngine.Side sideA, IPerpEngine.Side sideB);
    error InvalidPairMaker(uint8 legIndex);
    error PairSelfTrade(uint8 legIndex, address trader);
    error NotionalImbalanceBpsOutOfRange(uint16 bps);
    error NotionalImbalanceExceeded(uint256 notionalA, uint256 notionalB, uint16 maximumBps);
    error InvalidLiquidityRole(bool makerPostOnly, bool takerPostOnly);
    error InvalidCounterparties(address maker, address taker);
    error SubjectMismatch(bytes32 makerSubject, bytes32 takerSubject);
    error SideMismatch(IPerpEngine.Side makerSide, IPerpEngine.Side takerSide);
    error FullFillRequired(uint256 makerQuantity, uint256 takerQuantity);
    error InsufficientRemainingQuantity(bytes32 orderHash, uint256 remaining, uint256 requested);
    error FillAllocationTooSmall(bytes32 orderHash, uint256 fillQuantity);
    error MakerPositionChanged(bytes32 orderHash, bytes32 expectedPositionId, bytes32 actualPositionId);
    error DeadlineExpired(uint64 deadline);
    error UnauthorizedExecutor(address expected, address actual);
    error LimitPriceExceeded(IPerpEngine.Side side, uint256 limitPrice, uint256 executionPrice);
    error MarkDivergenceBpsOutOfRange(uint16 bps);
    error NonceInvalid(address trader, uint256 nonce, uint256 minimum);
    error NonceFloorNotIncreasing(uint256 currentMinimum, uint256 attemptedMinimum);
    error OrderUnavailable(bytes32 orderHash);
    error InvalidSignature(address trader, bytes32 orderHash);
    error FillAlreadyUsed(bytes32 fillId);
}
