// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IPerpEngine} from "../core/IPerpEngine.sol";

/// @title IMatchedFillRouter
/// @notice EIP-712 authorization and atomic two-sided settlement boundary for the perp CLOB.
interface IMatchedFillRouter {
    enum OrderIntent {
        UNSET,
        OPEN
    }

    /// @notice One trader-authorized order. Every execution-sensitive field is signed.
    /// @dev V1 supports only the zero subaccount and full-fill OPEN orders. Unsupported shapes
    ///      fail closed instead of being reinterpreted. `executor` binds the order to the matching
    ///      operator selected by the trader; the EIP-712 domain binds chain and router.
    struct Order {
        address trader;
        address executor;
        bytes32 subaccount;
        bytes32 subjectId;
        IPerpEngine.Side side;
        OrderIntent intent;
        uint256 sizeNotional;
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

    function settleOpen(
        bytes32 fillId,
        Order calldata maker,
        bytes calldata makerSignature,
        Order calldata taker,
        bytes calldata takerSignature
    )
        external
        returns (MatchResult memory result);

    function cancelOrder(Order calldata order) external;
    function invalidateNoncesBelow(uint256 newMinimum) external;

    function hashOrder(Order calldata order) external view returns (bytes32 digest);
    function filledSize(bytes32 orderHash) external view returns (uint256);
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
    event MatchedOpenSettled(
        bytes32 indexed fillId,
        bytes32 indexed makerOrderHash,
        bytes32 indexed takerOrderHash,
        address maker,
        address taker,
        bytes32 subjectId,
        uint256 executionPrice,
        uint256 sizeNotional,
        bytes32 makerPositionId,
        bytes32 takerPositionId
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
    error ReduceOnlyUnsupported();
    error InvalidLiquidityRole(bool makerPostOnly, bool takerPostOnly);
    error InvalidCounterparties(address maker, address taker);
    error SubjectMismatch(bytes32 makerSubject, bytes32 takerSubject);
    error SideMismatch(IPerpEngine.Side makerSide, IPerpEngine.Side takerSide);
    error FullFillRequired(uint256 makerSize, uint256 takerSize);
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
