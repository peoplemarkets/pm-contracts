// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {EIP712} from "solady/utils/EIP712.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

import {IPerpEngine} from "../core/IPerpEngine.sol";
import {IMatchedFillRouter} from "./IMatchedFillRouter.sol";

/// @title MatchedFillRouter
/// @notice Verifies two trader-signed orders and atomically settles one two-sided CLOB fill.
/// @dev The signed maker limit is the deterministic execution price. An incoming V2 order still
///      fills its exact signed base quantity or not at all, while a larger resting OPEN maker may
///      be consumed in deterministic slices. Maker collateral and fee authority are allocated by
///      cumulative pro-rata deltas so all slices can never exceed the signed totals. The taker may
///      OPEN or CLOSE. This keeps reduce-only orders off the resting book until the matcher has
///      live position-aware cancel logic. Unsupported shapes revert before funds or positions move.
contract MatchedFillRouter is Initializable, UUPSUpgradeable, EIP712, ReentrancyGuard, IMatchedFillRouter {
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address trader,address executor,bytes32 subaccount,bytes32 subjectId,bytes32 positionId,uint8 side,uint8 intent,uint256 quantity,uint256 collateralAmount,uint256 limitPrice,uint256 maxFee,uint16 maxMarkDivergenceBps,uint256 nonce,uint64 deadline,bool reduceOnly,bool postOnly)"
    );
    bytes32 public constant PAIR_LEG_TYPEHASH = keccak256(
        "PairLeg(bytes32 subjectId,uint8 side,uint256 quantity,uint256 collateralAmount,uint256 limitPrice,uint256 maxFee,uint16 maxMarkDivergenceBps)"
    );
    bytes32 public constant PAIR_ORDER_TYPEHASH = keccak256(
        "PairOrder(address trader,address executor,bytes32 subaccount,PairLeg legA,PairLeg legB,uint16 maxNotionalImbalanceBps,uint256 nonce,uint64 deadline,bool postOnly)PairLeg(bytes32 subjectId,uint8 side,uint256 quantity,uint256 collateralAmount,uint256 limitPrice,uint256 maxFee,uint16 maxMarkDivergenceBps)"
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
        mapping(bytes32 orderHash => uint256 quantity) filledQuantity;
        mapping(bytes32 orderHash => bool cancelled) cancelled;
        mapping(bytes32 fillId => bool used) fillUsed;
        mapping(address trader => uint256 minimum) minimumValidNonce;
        mapping(bytes32 pairOrderHash => bool filled) pairFilled;
        mapping(bytes32 orderHash => bytes32 positionId) makerPositionId;
    }

    struct MakerFill {
        bytes32 orderHash;
        uint256 filledBefore;
        uint256 filledAfter;
        uint256 fillQuantity;
        uint256 collateralAmount;
        uint256 maxFee;
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
    function settle(
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
        MakerFill memory makerFill = _prepareMakerFill(s, maker, makerSignature, taker.quantity);
        (bytes32 takerHash, uint256 takerFilledBefore) = _validateOrder(s, taker, takerSignature);
        if (takerFilledBefore != 0) revert OrderUnavailable(takerHash);

        uint256 executionPrice = maker.limitPrice;
        _checkLimit(taker.side, taker.limitPrice, executionPrice);

        // CEI. Any PerpEngine or vault revert unwinds these replay markers and the other leg.
        s.fillUsed[fillId] = true;
        s.filledQuantity[makerFill.orderHash] = makerFill.filledAfter;
        s.filledQuantity[takerHash] = taker.quantity;

        IPerpEngine engine = IPerpEngine(s.perpEngine);
        if (taker.intent == OrderIntent.CLOSE) {
            // Release the existing exposure before opening the replacement leg. This makes the
            // atomic fill respect final-state OI/cap risk instead of failing on a transient gross
            // increase. A later maker revert still unwinds the close and both replay markers.
            result.takerPositionId = _apply(engine, taker, executionPrice, false);
            result.makerPositionId = _applyMaker(s, engine, maker, executionPrice, makerFill);
        } else {
            result.makerPositionId = _applyMaker(s, engine, maker, executionPrice, makerFill);
            result.takerPositionId = _apply(engine, taker, executionPrice, false);
        }

        emit MatchedFillSettled(
            fillId,
            makerFill.orderHash,
            takerHash,
            maker.trader,
            taker.trader,
            maker.subjectId,
            executionPrice,
            taker.quantity,
            maker.intent,
            taker.intent,
            result.makerPositionId,
            result.takerPositionId
        );
    }

    /// @inheritdoc IMatchedFillRouter
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
        nonReentrant
        returns (PairMatchResult memory result)
    {
        Layout storage s = _s();
        if (fillId == bytes32(0)) revert InvalidConfig();
        if (s.fillUsed[fillId]) revert FillAlreadyUsed(fillId);

        _validatePairShape(makerA, makerB, pair);
        MakerFill memory makerFillA = _prepareMakerFill(s, makerA, makerSignatureA, pair.legA.quantity);
        MakerFill memory makerFillB = _prepareMakerFill(s, makerB, makerSignatureB, pair.legB.quantity);
        bytes32 pairHash = _validatePairOrder(s, pair, pairSignature);

        uint256 executionPriceA = makerA.limitPrice;
        uint256 executionPriceB = makerB.limitPrice;
        _checkLimit(pair.legA.side, pair.legA.limitPrice, executionPriceA);
        _checkLimit(pair.legB.side, pair.legB.limitPrice, executionPriceB);
        _checkPairNotionalBalance(pair, executionPriceA, executionPriceB);

        // CEI. Any of the four PerpEngine calls reverting unwinds every replay marker and leg.
        s.fillUsed[fillId] = true;
        s.filledQuantity[makerFillA.orderHash] = makerFillA.filledAfter;
        s.filledQuantity[makerFillB.orderHash] = makerFillB.filledAfter;
        s.pairFilled[pairHash] = true;

        IPerpEngine engine = IPerpEngine(s.perpEngine);
        result.makerPositionA = _applyMaker(s, engine, makerA, executionPriceA, makerFillA);
        result.traderPositionA = _applyPairLeg(engine, pair, pair.legA, executionPriceA);
        result.makerPositionB = _applyMaker(s, engine, makerB, executionPriceB, makerFillB);
        result.traderPositionB = _applyPairLeg(engine, pair, pair.legB, executionPriceB);

        emit PairFillSettled(fillId, pairHash, pair.trader, makerFillA.orderHash, makerFillB.orderHash);
        emit PairLegSettled(
            fillId,
            0,
            makerFillA.orderHash,
            pairHash,
            makerA.trader,
            pair.trader,
            pair.legA.subjectId,
            executionPriceA,
            pair.legA.quantity,
            result.makerPositionA,
            result.traderPositionA
        );
        emit PairLegSettled(
            fillId,
            1,
            makerFillB.orderHash,
            pairHash,
            makerB.trader,
            pair.trader,
            pair.legB.subjectId,
            executionPriceB,
            pair.legB.quantity,
            result.makerPositionB,
            result.traderPositionB
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
        if (maker.quantity == 0 || taker.quantity == 0) revert InvalidConfig();
        if (maker.intent == OrderIntent.CLOSE) revert CloseMakerUnsupported();
        if (taker.intent == OrderIntent.CLOSE && taker.postOnly) revert CloseMustBeImmediate();
        if (!maker.postOnly || taker.postOnly) {
            revert InvalidLiquidityRole(maker.postOnly, taker.postOnly);
        }
        if (maker.limitPrice == 0) revert InvalidConfig();
    }

    function _validatePairShape(Order calldata makerA, Order calldata makerB, PairOrder calldata pair) private view {
        if (pair.trader == address(0)) revert InvalidConfig();
        if (pair.executor == address(0) || msg.sender != pair.executor) {
            revert UnauthorizedExecutor(pair.executor, msg.sender);
        }
        if (pair.subaccount != bytes32(0)) revert UnsupportedSubaccount(pair.subaccount);
        if (pair.postOnly) revert PairMustBeImmediate();
        if (
            pair.legA.subjectId == bytes32(0) || pair.legB.subjectId == bytes32(0)
                || pair.legA.subjectId == pair.legB.subjectId
        ) {
            revert InvalidPairSubjects(pair.legA.subjectId, pair.legB.subjectId);
        }
        if (pair.legA.side == pair.legB.side) {
            revert InvalidPairSides(pair.legA.side, pair.legB.side);
        }
        if (
            pair.legA.quantity == 0 || pair.legB.quantity == 0 || pair.legA.collateralAmount == 0
                || pair.legB.collateralAmount == 0 || pair.legA.limitPrice == 0 || pair.legB.limitPrice == 0
        ) {
            revert InvalidConfig();
        }
        if (pair.legA.maxMarkDivergenceBps > BPS_DENOMINATOR) {
            revert MarkDivergenceBpsOutOfRange(pair.legA.maxMarkDivergenceBps);
        }
        if (pair.legB.maxMarkDivergenceBps > BPS_DENOMINATOR) {
            revert MarkDivergenceBpsOutOfRange(pair.legB.maxMarkDivergenceBps);
        }
        if (pair.maxNotionalImbalanceBps > BPS_DENOMINATOR) {
            revert NotionalImbalanceBpsOutOfRange(pair.maxNotionalImbalanceBps);
        }
        _validatePairMaker(makerA, pair, pair.legA, 0);
        _validatePairMaker(makerB, pair, pair.legB, 1);
    }

    function _validatePairMaker(
        Order calldata maker,
        PairOrder calldata pair,
        PairLeg calldata leg,
        uint8 legIndex
    )
        private
        pure
    {
        if (maker.trader == address(0) || maker.trader == pair.trader) {
            revert PairSelfTrade(legIndex, maker.trader);
        }
        if (maker.executor != pair.executor) {
            revert UnauthorizedExecutor(pair.executor, maker.executor);
        }
        if (maker.subjectId != leg.subjectId) {
            revert SubjectMismatch(maker.subjectId, leg.subjectId);
        }
        if (maker.side == leg.side) revert SideMismatch(maker.side, leg.side);
        if (maker.intent != OrderIntent.OPEN || !maker.postOnly || maker.reduceOnly || maker.positionId != bytes32(0)) {
            revert InvalidPairMaker(legIndex);
        }
    }

    function _validatePairOrder(
        Layout storage s,
        PairOrder calldata pair,
        bytes calldata signature
    )
        private
        view
        returns (bytes32 digest)
    {
        if (block.timestamp > pair.deadline) revert DeadlineExpired(pair.deadline);
        uint256 minimum = s.minimumValidNonce[pair.trader];
        if (pair.nonce < minimum) revert NonceInvalid(pair.trader, pair.nonce, minimum);
        digest = _hashPairOrder(pair);
        if (s.cancelled[digest] || s.pairFilled[digest]) revert OrderUnavailable(digest);
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(pair.trader, digest, signature)) {
            revert InvalidSignature(pair.trader, digest);
        }
    }

    function _checkPairNotionalBalance(
        PairOrder calldata pair,
        uint256 executionPriceA,
        uint256 executionPriceB
    )
        private
        pure
    {
        uint256 notionalA = Math.mulDiv(pair.legA.quantity, executionPriceA, 1e18);
        uint256 notionalB = Math.mulDiv(pair.legB.quantity, executionPriceB, 1e18);
        if (notionalA == 0 || notionalB == 0) revert InvalidConfig();
        uint256 larger = notionalA > notionalB ? notionalA : notionalB;
        uint256 difference = notionalA > notionalB ? notionalA - notionalB : notionalB - notionalA;
        uint256 actualBps = Math.mulDiv(difference, BPS_DENOMINATOR, larger);
        if (actualBps > pair.maxNotionalImbalanceBps) {
            revert NotionalImbalanceExceeded(notionalA, notionalB, pair.maxNotionalImbalanceBps);
        }
    }

    function _validateOrder(
        Layout storage s,
        Order calldata order,
        bytes calldata signature
    )
        private
        view
        returns (bytes32 digest, uint256 filledBefore)
    {
        if (order.intent == OrderIntent.UNSET) revert InvalidOrderIntent(order.intent);
        if (order.subaccount != bytes32(0)) revert UnsupportedSubaccount(order.subaccount);
        if (order.intent == OrderIntent.OPEN) {
            if (order.positionId != bytes32(0)) revert InvalidPositionBinding(order.intent, order.positionId);
            if (order.collateralAmount == 0) {
                revert InvalidCollateralForIntent(order.intent, order.collateralAmount);
            }
            if (order.reduceOnly) revert InvalidReduceOnlyForIntent(order.intent, order.reduceOnly);
        } else if (order.intent == OrderIntent.CLOSE) {
            if (order.positionId == bytes32(0)) revert InvalidPositionBinding(order.intent, order.positionId);
            if (order.collateralAmount != 0) {
                revert InvalidCollateralForIntent(order.intent, order.collateralAmount);
            }
            if (!order.reduceOnly) revert InvalidReduceOnlyForIntent(order.intent, order.reduceOnly);
            if (order.postOnly) revert CloseMustBeImmediate();
        } else {
            revert InvalidOrderIntent(order.intent);
        }
        if (order.limitPrice == 0 || order.quantity == 0) revert InvalidConfig();
        if (order.maxMarkDivergenceBps > BPS_DENOMINATOR) {
            revert MarkDivergenceBpsOutOfRange(order.maxMarkDivergenceBps);
        }
        if (block.timestamp > order.deadline) revert DeadlineExpired(order.deadline);
        uint256 minimum = s.minimumValidNonce[order.trader];
        if (order.nonce < minimum) revert NonceInvalid(order.trader, order.nonce, minimum);
        digest = _hashOrder(order);
        filledBefore = s.filledQuantity[digest];
        if (s.cancelled[digest] || filledBefore >= order.quantity) revert OrderUnavailable(digest);
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(order.trader, digest, signature)) {
            revert InvalidSignature(order.trader, digest);
        }
    }

    function _prepareMakerFill(
        Layout storage s,
        Order calldata maker,
        bytes calldata signature,
        uint256 fillQuantity
    )
        private
        view
        returns (MakerFill memory fill)
    {
        (fill.orderHash, fill.filledBefore) = _validateOrder(s, maker, signature);
        uint256 remaining = maker.quantity - fill.filledBefore;
        if (fillQuantity == 0 || fillQuantity > remaining) {
            revert InsufficientRemainingQuantity(fill.orderHash, remaining, fillQuantity);
        }

        fill.fillQuantity = fillQuantity;
        fill.filledAfter = fill.filledBefore + fillQuantity;
        uint256 collateralBefore = Math.mulDiv(maker.collateralAmount, fill.filledBefore, maker.quantity);
        uint256 collateralAfter = Math.mulDiv(maker.collateralAmount, fill.filledAfter, maker.quantity);
        fill.collateralAmount = collateralAfter - collateralBefore;
        if (fill.collateralAmount == 0) {
            revert FillAllocationTooSmall(fill.orderHash, fillQuantity);
        }
        uint256 feeBefore = Math.mulDiv(maker.maxFee, fill.filledBefore, maker.quantity);
        uint256 feeAfter = Math.mulDiv(maker.maxFee, fill.filledAfter, maker.quantity);
        fill.maxFee = feeAfter - feeBefore;
    }

    function _apply(
        IPerpEngine engine,
        Order calldata order,
        uint256 executionPrice,
        bool isMaker
    )
        private
        returns (bytes32 positionId)
    {
        if (order.intent == OrderIntent.OPEN) {
            return engine.openPositionForMatched(
                order.trader,
                _matchedOpenParams(order, executionPrice, order.quantity, order.collateralAmount, order.maxFee, isMaker)
            );
        }
        engine.closePositionForMatched(order.trader, _matchedCloseParams(order, executionPrice, isMaker));
        return order.positionId;
    }

    function _applyMaker(
        Layout storage s,
        IPerpEngine engine,
        Order calldata maker,
        uint256 executionPrice,
        MakerFill memory fill
    )
        private
        returns (bytes32 positionId)
    {
        IPerpEngine.MatchedOpenParams memory params =
            _matchedOpenParams(maker, executionPrice, fill.fillQuantity, fill.collateralAmount, fill.maxFee, true);
        if (fill.filledBefore == 0) {
            positionId = engine.openPositionForMatched(maker.trader, params);
            s.makerPositionId[fill.orderHash] = positionId;
            return positionId;
        }
        positionId = s.makerPositionId[fill.orderHash];
        if (positionId == bytes32(0)) revert InvalidConfig();
        bytes32 actualPositionId = engine.openPositionForMatched(maker.trader, params);
        if (actualPositionId != positionId) {
            revert MakerPositionChanged(fill.orderHash, positionId, actualPositionId);
        }
        return positionId;
    }

    function _applyPairLeg(
        IPerpEngine engine,
        PairOrder calldata pair,
        PairLeg calldata leg,
        uint256 executionPrice
    )
        private
        returns (bytes32 positionId)
    {
        return engine.openPositionForMatched(
            pair.trader,
            IPerpEngine.MatchedOpenParams({
                subjectId: leg.subjectId,
                side: leg.side,
                collateralAmount: leg.collateralAmount,
                quantity: leg.quantity,
                executionPrice: executionPrice,
                maxMarkDivergenceBps: leg.maxMarkDivergenceBps,
                maxFee: leg.maxFee,
                deadline: pair.deadline,
                isMaker: false
            })
        );
    }

    function _matchedOpenParams(
        Order calldata order,
        uint256 executionPrice,
        uint256 quantity,
        uint256 collateralAmount,
        uint256 maxFee,
        bool isMaker
    )
        private
        pure
        returns (IPerpEngine.MatchedOpenParams memory p)
    {
        p = IPerpEngine.MatchedOpenParams({
            subjectId: order.subjectId,
            side: order.side,
            collateralAmount: collateralAmount,
            quantity: quantity,
            executionPrice: executionPrice,
            maxMarkDivergenceBps: order.maxMarkDivergenceBps,
            maxFee: maxFee,
            deadline: order.deadline,
            isMaker: isMaker
        });
    }

    function _matchedCloseParams(
        Order calldata order,
        uint256 executionPrice,
        bool isMaker
    )
        private
        pure
        returns (IPerpEngine.MatchedCloseParams memory p)
    {
        p = IPerpEngine.MatchedCloseParams({
            subjectId: order.subjectId,
            positionId: order.positionId,
            side: order.side,
            quantity: order.quantity,
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
    function cancelPairOrder(PairOrder calldata order) external {
        if (msg.sender != order.trader) revert Unauthorized(msg.sender);
        bytes32 digest = _hashPairOrder(order);
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

    /// @inheritdoc IMatchedFillRouter
    function hashPairOrder(PairOrder calldata order) external view returns (bytes32 digest) {
        return _hashPairOrder(order);
    }

    function _hashOrder(Order calldata order) private view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.trader,
                order.executor,
                order.subaccount,
                order.subjectId,
                order.positionId,
                order.side,
                order.intent,
                order.quantity,
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

    function _hashPairOrder(PairOrder calldata order) private view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(
                PAIR_ORDER_TYPEHASH,
                order.trader,
                order.executor,
                order.subaccount,
                _hashPairLeg(order.legA),
                _hashPairLeg(order.legB),
                order.maxNotionalImbalanceBps,
                order.nonce,
                order.deadline,
                order.postOnly
            )
        );
        return _hashTypedData(structHash);
    }

    function _hashPairLeg(PairLeg calldata leg) private pure returns (bytes32 digest) {
        return keccak256(
            abi.encode(
                PAIR_LEG_TYPEHASH,
                leg.subjectId,
                leg.side,
                leg.quantity,
                leg.collateralAmount,
                leg.limitPrice,
                leg.maxFee,
                leg.maxMarkDivergenceBps
            )
        );
    }

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        return ("PeopleMarketsMatchedOrders", "2");
    }

    /// @inheritdoc IMatchedFillRouter
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    /// @inheritdoc IMatchedFillRouter
    function filledQuantity(bytes32 orderHash) external view returns (uint256) {
        return _s().filledQuantity[orderHash];
    }

    /// @inheritdoc IMatchedFillRouter
    function makerPositionId(bytes32 orderHash) external view returns (bytes32) {
        return _s().makerPositionId[orderHash];
    }

    /// @inheritdoc IMatchedFillRouter
    function isPairOrderFilled(bytes32 orderHash) external view returns (bool) {
        return _s().pairFilled[orderHash];
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
