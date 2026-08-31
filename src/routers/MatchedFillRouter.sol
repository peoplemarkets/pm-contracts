// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {EIP712} from "solady/utils/EIP712.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

import {IPerpEngine} from "../core/IPerpEngine.sol";
import {IMatchedFillRouter} from "./IMatchedFillRouter.sol";

/// @title MatchedFillRouter
/// @notice Verifies two trader-signed orders and atomically opens both sides of one CLOB fill.
/// @dev The signed maker limit is the deterministic execution price. V1 deliberately accepts
///      full-fill OPEN orders only: the current one-position model cannot safely account for
///      partial increases without per-lot entry/funding state. Unsupported shapes revert before
///      any funds or positions move.
contract MatchedFillRouter is Initializable, UUPSUpgradeable, EIP712, ReentrancyGuard, IMatchedFillRouter {
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address trader,address executor,bytes32 subaccount,bytes32 subjectId,uint8 side,uint8 intent,uint256 sizeNotional,uint256 collateralAmount,uint256 limitPrice,uint256 maxFee,uint16 maxMarkDivergenceBps,uint256 nonce,uint64 deadline,bool reduceOnly,bool postOnly)"
    );

    bytes32 internal constant MATCHED_FILL_ROUTER_SLOT =
        0x8d07586d1978584bbfd5d7b39268b56d9debb43a3da63d03c80e1cd8bdb58400;
    uint32 internal constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 internal constant MAX_TIMELOCK_DELAY = 30 days;
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @custom:storage-location erc7201:people.markets.matchedfillrouter.v1
    struct Layout {
        address governance;
        uint32 timelockDelay;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        address perpEngine;
        mapping(bytes32 orderHash => uint256 size) filledSize;
        mapping(bytes32 orderHash => bool cancelled) cancelled;
        mapping(bytes32 fillId => bool used) fillUsed;
        mapping(address trader => uint256 minimum) minimumValidNonce;
    }

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = MATCHED_FILL_ROUTER_SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address governance_, address perpEngine_, uint32 timelockDelay_) external initializer {
        if (governance_ == address(0) || perpEngine_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) {
            revert InvalidConfig();
        }
        Layout storage s = _s();
        s.governance = governance_;
        s.perpEngine = perpEngine_;
        s.timelockDelay = timelockDelay_;
        emit Initialized(governance_, perpEngine_);
    }

    modifier onlyGovernance() {
        _requireGovernance();
        _;
    }

    function _requireGovernance() private view {
        if (msg.sender != _s().governance) revert Unauthorized(msg.sender);
    }

    /// @inheritdoc IMatchedFillRouter
    function settleOpen(
        bytes32 fillId,
        Order calldata maker,
        bytes calldata makerSignature,
        Order calldata taker,
        bytes calldata takerSignature
    )
        external
        nonReentrant
        returns (MatchResult memory result)
    {
        Layout storage s = _s();
        if (fillId == bytes32(0)) revert InvalidConfig();
        if (s.fillUsed[fillId]) revert FillAlreadyUsed(fillId);

        _validatePair(maker, taker);
        bytes32 makerHash = _validateOrder(s, maker, makerSignature);
        bytes32 takerHash = _validateOrder(s, taker, takerSignature);

        uint256 executionPrice = maker.limitPrice;
        _checkLimit(taker.side, taker.limitPrice, executionPrice);

        // CEI. Any PerpEngine or vault revert unwinds these replay markers and the other leg.
        s.fillUsed[fillId] = true;
        s.filledSize[makerHash] = maker.sizeNotional;
        s.filledSize[takerHash] = taker.sizeNotional;

        IPerpEngine engine = IPerpEngine(s.perpEngine);
        result.makerPositionId =
            engine.openPositionForMatched(maker.trader, _matchedParams(maker, executionPrice, true));
        result.takerPositionId =
            engine.openPositionForMatched(taker.trader, _matchedParams(taker, executionPrice, false));

        emit MatchedOpenSettled(
            fillId,
            makerHash,
            takerHash,
            maker.trader,
            taker.trader,
            maker.subjectId,
            executionPrice,
            maker.sizeNotional,
            result.makerPositionId,
            result.takerPositionId
        );
    }

    function _validatePair(Order calldata maker, Order calldata taker) private view {
        if (maker.trader == address(0) || taker.trader == address(0) || maker.trader == taker.trader) {
            revert InvalidCounterparties(maker.trader, taker.trader);
        }
        if (maker.executor == address(0) || maker.executor != taker.executor || msg.sender != maker.executor) {
            revert UnauthorizedExecutor(maker.executor, msg.sender);
        }
        if (maker.subjectId != taker.subjectId) {
            revert SubjectMismatch(maker.subjectId, taker.subjectId);
        }
        if (maker.side == taker.side) revert SideMismatch(maker.side, taker.side);
        if (maker.sizeNotional == 0 || maker.sizeNotional != taker.sizeNotional) {
            revert FullFillRequired(maker.sizeNotional, taker.sizeNotional);
        }
        if (!maker.postOnly || taker.postOnly) {
            revert InvalidLiquidityRole(maker.postOnly, taker.postOnly);
        }
        if (maker.limitPrice == 0) revert InvalidConfig();
    }

    function _validateOrder(
        Layout storage s,
        Order calldata order,
        bytes calldata signature
    )
        private
        view
        returns (bytes32 digest)
    {
        if (order.intent != OrderIntent.OPEN) revert InvalidOrderIntent(order.intent);
        if (order.subaccount != bytes32(0)) revert UnsupportedSubaccount(order.subaccount);
        if (order.reduceOnly) revert ReduceOnlyUnsupported();
        if (order.collateralAmount == 0 || order.limitPrice == 0) revert InvalidConfig();
        if (order.maxMarkDivergenceBps > BPS_DENOMINATOR) {
            revert MarkDivergenceBpsOutOfRange(order.maxMarkDivergenceBps);
        }
        if (block.timestamp > order.deadline) revert DeadlineExpired(order.deadline);
        uint256 minimum = s.minimumValidNonce[order.trader];
        if (order.nonce < minimum) revert NonceInvalid(order.trader, order.nonce, minimum);
        digest = _hashOrder(order);
        if (s.cancelled[digest] || s.filledSize[digest] != 0) revert OrderUnavailable(digest);
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(order.trader, digest, signature)) {
            revert InvalidSignature(order.trader, digest);
        }
    }

    function _matchedParams(
        Order calldata order,
        uint256 executionPrice,
        bool isMaker
    )
        private
        pure
        returns (IPerpEngine.MatchedOpenParams memory p)
    {
        p = IPerpEngine.MatchedOpenParams({
            subjectId: order.subjectId,
            side: order.side,
            collateralAmount: order.collateralAmount,
            sizeNotional: order.sizeNotional,
            executionPrice: executionPrice,
            maxMarkDivergenceBps: order.maxMarkDivergenceBps,
            maxFee: order.maxFee,
            deadline: order.deadline,
            isMaker: isMaker
        });
    }

    function _checkLimit(IPerpEngine.Side side, uint256 limitPrice, uint256 executionPrice) private pure {
        bool violated = side == IPerpEngine.Side.LONG ? executionPrice > limitPrice : executionPrice < limitPrice;
        if (violated) revert LimitPriceExceeded(side, limitPrice, executionPrice);
    }

    /// @inheritdoc IMatchedFillRouter
    function cancelOrder(Order calldata order) external {
        if (msg.sender != order.trader) revert Unauthorized(msg.sender);
        bytes32 digest = _hashOrder(order);
        _s().cancelled[digest] = true;
        emit OrderCancelled(msg.sender, digest, order.nonce);
    }

    /// @inheritdoc IMatchedFillRouter
    function invalidateNoncesBelow(uint256 newMinimum) external {
        Layout storage s = _s();
        uint256 oldMinimum = s.minimumValidNonce[msg.sender];
        if (newMinimum <= oldMinimum) revert NonceFloorNotIncreasing(oldMinimum, newMinimum);
        s.minimumValidNonce[msg.sender] = newMinimum;
        emit MinimumValidNonceSet(msg.sender, oldMinimum, newMinimum);
    }

    /// @inheritdoc IMatchedFillRouter
    function hashOrder(Order calldata order) external view returns (bytes32 digest) {
        return _hashOrder(order);
    }

    function _hashOrder(Order calldata order) private view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.trader,
                order.executor,
                order.subaccount,
                order.subjectId,
                order.side,
                order.intent,
                order.sizeNotional,
                order.collateralAmount,
                order.limitPrice,
                order.maxFee,
                order.maxMarkDivergenceBps,
                order.nonce,
                order.deadline,
                order.reduceOnly,
                order.postOnly
            )
        );
        return _hashTypedData(structHash);
    }

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        return ("PeopleMarketsMatchedOrders", "1");
    }

    /// @inheritdoc IMatchedFillRouter
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    /// @inheritdoc IMatchedFillRouter
    function filledSize(bytes32 orderHash) external view returns (uint256) {
        return _s().filledSize[orderHash];
    }

    /// @inheritdoc IMatchedFillRouter
    function isOrderCancelled(bytes32 orderHash) external view returns (bool) {
        return _s().cancelled[orderHash];
    }

    /// @inheritdoc IMatchedFillRouter
    function isFillUsed(bytes32 fillId) external view returns (bool) {
        return _s().fillUsed[fillId];
    }

    /// @inheritdoc IMatchedFillRouter
    function minimumValidNonce(address trader) external view returns (uint256) {
        return _s().minimumValidNonce[trader];
    }

    /// @inheritdoc IMatchedFillRouter
    function perpEngine() external view returns (address) {
        return _s().perpEngine;
    }

    /// @inheritdoc IMatchedFillRouter
    function governance() external view returns (address) {
        return _s().governance;
    }

    /// @inheritdoc IMatchedFillRouter
    function timelockDelay() external view returns (uint32) {
        return _s().timelockDelay;
    }

    /// @inheritdoc IMatchedFillRouter
    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        Layout storage s = _s();
        return (s.pendingGovernance, s.pendingGovernanceActivatesAt);
    }

    /// @inheritdoc IMatchedFillRouter
    function proposeGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        if (s.pendingGovernanceActivatesAt != 0) revert PendingProposalExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingGovernance = newGovernance;
        s.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGovernance, activatesAt);
    }

    /// @inheritdoc IMatchedFillRouter
    function activateGovernanceTransfer() external {
        Layout storage s = _s();
        uint64 readyAt = s.pendingGovernanceActivatesAt;
        if (readyAt == 0) revert NoPendingProposal();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldGovernance = s.governance;
        address newGovernance = s.pendingGovernance;
        s.governance = newGovernance;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferActivated(oldGovernance, newGovernance);
    }

    /// @inheritdoc IMatchedFillRouter
    function cancelGovernanceTransfer() external onlyGovernance {
        Layout storage s = _s();
        if (s.pendingGovernanceActivatesAt == 0) revert NoPendingProposal();
        address pending = s.pendingGovernance;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferCancelled(pending);
    }

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
