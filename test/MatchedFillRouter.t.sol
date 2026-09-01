// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test} from "forge-std/Test.sol";

import {IPerpEngine} from "../src/core/IPerpEngine.sol";
import {IMatchedFillRouter} from "../src/routers/IMatchedFillRouter.sol";
import {MatchedFillRouter} from "../src/routers/MatchedFillRouter.sol";

contract MockMatchedPerpEngine {
    error SecondLegFailed();

    struct RecordedCall {
        address trader;
        bytes32 subjectId;
        bytes32 positionId;
        IPerpEngine.Side side;
        IMatchedFillRouter.OrderIntent intent;
        uint256 collateralAmount;
        uint256 quantity;
        uint256 executionPrice;
        uint256 maxMarkDivergenceBps;
        uint256 maxFee;
        uint64 deadline;
        bool isMaker;
    }

    RecordedCall[] private _calls;
    bool public revertOnSecond;
    uint256 public revertOnCall;

    function setRevertOnSecond(bool enabled) external {
        revertOnSecond = enabled;
    }

    function setRevertOnCall(uint256 callNumber) external {
        revertOnCall = callNumber;
    }

    function openPositionForMatched(
        address trader,
        IPerpEngine.MatchedOpenParams calldata p
    )
        external
        returns (bytes32 positionId)
    {
        if ((revertOnSecond && _calls.length == 1) || revertOnCall == _calls.length + 1) {
            revert SecondLegFailed();
        }
        positionId = keccak256(abi.encode(trader, p.subjectId, p.side, p.quantity, p.executionPrice, _calls.length));
        _calls.push(
            RecordedCall({
                trader: trader,
                subjectId: p.subjectId,
                positionId: positionId,
                side: p.side,
                intent: IMatchedFillRouter.OrderIntent.OPEN,
                collateralAmount: p.collateralAmount,
                quantity: p.quantity,
                executionPrice: p.executionPrice,
                maxMarkDivergenceBps: p.maxMarkDivergenceBps,
                maxFee: p.maxFee,
                deadline: p.deadline,
                isMaker: p.isMaker
            })
        );
    }

    function closePositionForMatched(
        address trader,
        IPerpEngine.MatchedCloseParams calldata p
    )
        external
        returns (int256 realizedPnl)
    {
        if ((revertOnSecond && _calls.length == 1) || revertOnCall == _calls.length + 1) {
            revert SecondLegFailed();
        }
        _calls.push(
            RecordedCall({
                trader: trader,
                subjectId: p.subjectId,
                positionId: p.positionId,
                side: p.side,
                intent: IMatchedFillRouter.OrderIntent.CLOSE,
                collateralAmount: 0,
                quantity: p.quantity,
                executionPrice: p.executionPrice,
                maxMarkDivergenceBps: p.maxMarkDivergenceBps,
                maxFee: p.maxFee,
                deadline: p.deadline,
                isMaker: p.isMaker
            })
        );
        return 0;
    }

    function callCount() external view returns (uint256) {
        return _calls.length;
    }

    function callAt(uint256 index) external view returns (RecordedCall memory) {
        return _calls[index];
    }
}

contract MockERC1271Signer {
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    mapping(bytes32 digest => bool approved) public approved;

    function setApproved(bytes32 digest, bool value) external {
        approved[digest] = value;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return approved[digest] ? MAGIC_VALUE : bytes4(0xffffffff);
    }
}

contract MatchedFillRouterTest is Test {
    MatchedFillRouter internal router;
    MockMatchedPerpEngine internal engine;

    uint256 internal constant MAKER_KEY = 0xA11CE;
    uint256 internal constant MAKER_B_KEY = 0xCAFE;
    uint256 internal constant TAKER_KEY = 0xB0B;
    uint32 internal constant TIMELOCK_DELAY = 1 hours;
    bytes32 internal constant SUBJECT_ID = keccak256("drake");
    bytes32 internal constant SUBJECT_B = keccak256("kendrick");
    uint256 internal constant QUANTITY = 100e6;
    uint256 internal constant QUANTITY_B = 200e6;
    uint256 internal constant MAKER_LIMIT = 100e18;
    uint256 internal constant MAKER_LIMIT_B = 50e18;

    address internal governance = makeAddr("governance");
    address internal executor = makeAddr("executor");
    address internal stranger = makeAddr("stranger");
    address internal makerTrader;
    address internal makerTraderB;
    address internal takerTrader;

    function setUp() public {
        vm.warp(2_000_000_000);
        makerTrader = vm.addr(MAKER_KEY);
        makerTraderB = vm.addr(MAKER_B_KEY);
        takerTrader = vm.addr(TAKER_KEY);
        engine = new MockMatchedPerpEngine();
        router = _deployRouter(address(engine), TIMELOCK_DELAY);
    }

    function _deployRouter(address perpEngine, uint32 delay) internal returns (MatchedFillRouter deployed) {
        MatchedFillRouter implementation = new MatchedFillRouter();
        bytes memory initData = abi.encodeCall(MatchedFillRouter.initialize, (governance, perpEngine, delay));
        deployed = MatchedFillRouter(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _makerOrder() internal view returns (IMatchedFillRouter.Order memory order) {
        order = IMatchedFillRouter.Order({
            trader: makerTrader,
            executor: executor,
            subaccount: bytes32(0),
            subjectId: SUBJECT_ID,
            positionId: bytes32(0),
            side: IPerpEngine.Side.LONG,
            intent: IMatchedFillRouter.OrderIntent.OPEN,
            quantity: QUANTITY,
            collateralAmount: 2_000e6,
            limitPrice: MAKER_LIMIT,
            maxFee: 20e6,
            maxMarkDivergenceBps: 200,
            nonce: 1,
            deadline: uint64(block.timestamp + 1 hours),
            reduceOnly: false,
            postOnly: true
        });
    }

    function _takerOrder() internal view returns (IMatchedFillRouter.Order memory order) {
        order = IMatchedFillRouter.Order({
            trader: takerTrader,
            executor: executor,
            subaccount: bytes32(0),
            subjectId: SUBJECT_ID,
            positionId: bytes32(0),
            side: IPerpEngine.Side.SHORT,
            intent: IMatchedFillRouter.OrderIntent.OPEN,
            quantity: QUANTITY,
            collateralAmount: 2_500e6,
            limitPrice: 99e18,
            maxFee: 20e6,
            maxMarkDivergenceBps: 250,
            nonce: 1,
            deadline: uint64(block.timestamp + 1 hours),
            reduceOnly: false,
            postOnly: false
        });
    }

    function _closeTakerOrder() internal view returns (IMatchedFillRouter.Order memory order) {
        order = _takerOrder();
        order.positionId = keccak256("taker-long-position");
        order.intent = IMatchedFillRouter.OrderIntent.CLOSE;
        order.collateralAmount = 0;
        order.reduceOnly = true;
    }

    function _sign(uint256 privateKey, IMatchedFillRouter.Order memory order) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, router.hashOrder(order));
        return abi.encodePacked(r, s, v);
    }

    function _pairMakerA() internal view returns (IMatchedFillRouter.Order memory order) {
        order = _makerOrder();
        order.side = IPerpEngine.Side.SHORT;
    }

    function _pairMakerB() internal view returns (IMatchedFillRouter.Order memory order) {
        order = _makerOrder();
        order.trader = makerTraderB;
        order.subjectId = SUBJECT_B;
        order.side = IPerpEngine.Side.LONG;
        order.quantity = QUANTITY_B;
        order.limitPrice = MAKER_LIMIT_B;
        order.nonce = 2;
    }

    function _pairOrder() internal view returns (IMatchedFillRouter.PairOrder memory order) {
        order = IMatchedFillRouter.PairOrder({
            trader: takerTrader,
            executor: executor,
            subaccount: bytes32(0),
            legA: IMatchedFillRouter.PairLeg({
                subjectId: SUBJECT_ID,
                side: IPerpEngine.Side.LONG,
                quantity: QUANTITY,
                collateralAmount: 2_000e6,
                limitPrice: 101e18,
                maxFee: 20e6,
                maxMarkDivergenceBps: 200
            }),
            legB: IMatchedFillRouter.PairLeg({
                subjectId: SUBJECT_B,
                side: IPerpEngine.Side.SHORT,
                quantity: QUANTITY_B,
                collateralAmount: 2_000e6,
                limitPrice: 49e18,
                maxFee: 20e6,
                maxMarkDivergenceBps: 200
            }),
            maxNotionalImbalanceBps: 10,
            nonce: 3,
            deadline: uint64(block.timestamp + 1 hours),
            postOnly: false
        });
    }

    function _signPair(
        uint256 privateKey,
        IMatchedFillRouter.PairOrder memory order
    )
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, router.hashPairOrder(order));
        return abi.encodePacked(r, s, v);
    }

    function _settlePair(
        bytes32 fillId,
        IMatchedFillRouter.Order memory makerA,
        bytes memory makerSignatureA,
        IMatchedFillRouter.Order memory makerB,
        bytes memory makerSignatureB,
        IMatchedFillRouter.PairOrder memory pair,
        bytes memory pairSignature
    )
        internal
        returns (IMatchedFillRouter.PairMatchResult memory result)
    {
        vm.prank(executor);
        return router.settlePair(fillId, makerA, makerSignatureA, makerB, makerSignatureB, pair, pairSignature);
    }

    function _settle(
        bytes32 fillId,
        IMatchedFillRouter.Order memory maker,
        bytes memory makerSignature,
        IMatchedFillRouter.Order memory taker,
        bytes memory takerSignature
    )
        internal
        returns (IMatchedFillRouter.MatchResult memory result)
    {
        vm.prank(executor);
        return router.settle(fillId, maker, makerSignature, taker, takerSignature);
    }

    function test_Initialize_StoresConfigAndDomain() public view {
        assertEq(router.governance(), governance);
        assertEq(router.perpEngine(), address(engine));
        assertEq(router.timelockDelay(), TIMELOCK_DELAY);
        assertNotEq(router.domainSeparator(), bytes32(0));
    }

    function test_HashPairOrder_MatchesCanonicalNestedEIP712Encoding() public view {
        IMatchedFillRouter.PairOrder memory pair = _pairOrder();
        bytes32 legTypeHash = keccak256(
            "PairLeg(bytes32 subjectId,uint8 side,uint256 quantity,uint256 collateralAmount,uint256 limitPrice,uint256 maxFee,uint16 maxMarkDivergenceBps)"
        );
        bytes32 orderTypeHash = keccak256(
            "PairOrder(address trader,address executor,bytes32 subaccount,PairLeg legA,PairLeg legB,uint16 maxNotionalImbalanceBps,uint256 nonce,uint64 deadline,bool postOnly)PairLeg(bytes32 subjectId,uint8 side,uint256 quantity,uint256 collateralAmount,uint256 limitPrice,uint256 maxFee,uint16 maxMarkDivergenceBps)"
        );
        bytes32 legHashA = keccak256(
            abi.encode(
                legTypeHash,
                pair.legA.subjectId,
                pair.legA.side,
                pair.legA.quantity,
                pair.legA.collateralAmount,
                pair.legA.limitPrice,
                pair.legA.maxFee,
                pair.legA.maxMarkDivergenceBps
            )
        );
        bytes32 legHashB = keccak256(
            abi.encode(
                legTypeHash,
                pair.legB.subjectId,
                pair.legB.side,
                pair.legB.quantity,
                pair.legB.collateralAmount,
                pair.legB.limitPrice,
                pair.legB.maxFee,
                pair.legB.maxMarkDivergenceBps
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                orderTypeHash,
                pair.trader,
                pair.executor,
                pair.subaccount,
                legHashA,
                legHashB,
                pair.maxNotionalImbalanceBps,
                pair.nonce,
                pair.deadline,
                pair.postOnly
            )
        );
        bytes32 expected = keccak256(abi.encodePacked("\x19\x01", router.domainSeparator(), structHash));

        assertEq(router.PAIR_LEG_TYPEHASH(), legTypeHash);
        assertEq(router.PAIR_ORDER_TYPEHASH(), orderTypeHash);
        assertEq(router.hashPairOrder(pair), expected);
    }

    function test_Initialize_RevertsOnZeroEngine() public {
        MatchedFillRouter implementation = new MatchedFillRouter();
        bytes memory initData = abi.encodeCall(MatchedFillRouter.initialize, (governance, address(0), TIMELOCK_DELAY));
        vm.expectRevert(IMatchedFillRouter.InvalidConfig.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertsOnInvalidTimelock() public {
        MatchedFillRouter implementation = new MatchedFillRouter();
        bytes memory initData =
            abi.encodeCall(MatchedFillRouter.initialize, (governance, address(engine), TIMELOCK_DELAY - 1));
        vm.expectRevert(IMatchedFillRouter.InvalidConfig.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_SettleOpen_HappyPath_UsesMakerPriceAndDerivedRoles() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        bytes32 makerHash = router.hashOrder(maker);
        bytes32 takerHash = router.hashOrder(taker);
        bytes32 fillId = keccak256("fill-1");

        IMatchedFillRouter.MatchResult memory result =
            _settle(fillId, maker, _sign(MAKER_KEY, maker), taker, _sign(TAKER_KEY, taker));

        assertNotEq(result.makerPositionId, bytes32(0));
        assertNotEq(result.takerPositionId, bytes32(0));
        assertTrue(router.isFillUsed(fillId));
        assertEq(router.filledQuantity(makerHash), QUANTITY);
        assertEq(router.filledQuantity(takerHash), QUANTITY);
        assertEq(engine.callCount(), 2);

        MockMatchedPerpEngine.RecordedCall memory makerCall = engine.callAt(0);
        MockMatchedPerpEngine.RecordedCall memory takerCall = engine.callAt(1);
        assertEq(makerCall.trader, makerTrader);
        assertEq(uint8(makerCall.side), uint8(IPerpEngine.Side.LONG));
        assertEq(makerCall.executionPrice, MAKER_LIMIT);
        assertEq(makerCall.quantity, QUANTITY);
        assertEq(makerCall.maxFee, maker.maxFee);
        assertTrue(makerCall.isMaker);
        assertEq(takerCall.trader, takerTrader);
        assertEq(uint8(takerCall.side), uint8(IPerpEngine.Side.SHORT));
        assertEq(takerCall.executionPrice, MAKER_LIMIT);
        assertEq(takerCall.maxFee, taker.maxFee);
        assertFalse(takerCall.isMaker);
    }

    function test_SettleOpen_HappyPath_WhenMakerIsShort() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        maker.side = IPerpEngine.Side.SHORT;
        taker.side = IPerpEngine.Side.LONG;
        taker.limitPrice = 101e18;

        _settle(keccak256("short-maker"), maker, _sign(MAKER_KEY, maker), taker, _sign(TAKER_KEY, taker));

        assertEq(uint8(engine.callAt(0).side), uint8(IPerpEngine.Side.SHORT));
        assertEq(uint8(engine.callAt(1).side), uint8(IPerpEngine.Side.LONG));
        assertEq(engine.callAt(1).executionPrice, MAKER_LIMIT);
    }

    function test_SettleClose_HappyPath_BindsExactPositionAndQuantity() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _closeTakerOrder();

        IMatchedFillRouter.MatchResult memory result =
            _settle(keccak256("close"), maker, _sign(MAKER_KEY, maker), taker, _sign(TAKER_KEY, taker));

        assertNotEq(result.makerPositionId, bytes32(0));
        assertEq(result.takerPositionId, taker.positionId);
        assertEq(engine.callCount(), 2);
        MockMatchedPerpEngine.RecordedCall memory closeCall = engine.callAt(0);
        MockMatchedPerpEngine.RecordedCall memory openCall = engine.callAt(1);
        assertEq(uint8(closeCall.intent), uint8(IMatchedFillRouter.OrderIntent.CLOSE));
        assertEq(closeCall.positionId, taker.positionId);
        assertEq(closeCall.quantity, QUANTITY);
        assertEq(closeCall.collateralAmount, 0);
        assertEq(uint8(closeCall.side), uint8(IPerpEngine.Side.SHORT));
        assertFalse(closeCall.isMaker);
        assertEq(uint8(openCall.intent), uint8(IMatchedFillRouter.OrderIntent.OPEN));
        assertTrue(openCall.isMaker);
    }

    function test_SettleClose_IsAtomicWhenMakerOpenFailsAfterClose() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _closeTakerOrder();
        bytes32 makerHash = router.hashOrder(maker);
        bytes32 takerHash = router.hashOrder(taker);
        bytes32 fillId = keccak256("reverting-close");
        bytes memory makerSignature = _sign(MAKER_KEY, maker);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);
        engine.setRevertOnSecond(true);

        vm.prank(executor);
        vm.expectRevert(MockMatchedPerpEngine.SecondLegFailed.selector);
        router.settle(fillId, maker, makerSignature, taker, takerSignature);

        assertFalse(router.isFillUsed(fillId));
        assertEq(router.filledQuantity(makerHash), 0);
        assertEq(router.filledQuantity(takerHash), 0);
        assertEq(engine.callCount(), 0);
    }

    function test_SettleOpen_SupportsERC1271Trader() public {
        MockERC1271Signer wallet = new MockERC1271Signer();
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        maker.trader = address(wallet);
        bytes32 makerHash = router.hashOrder(maker);
        wallet.setApproved(makerHash, true);

        _settle(keccak256("erc1271"), maker, bytes("wallet-signature"), taker, _sign(TAKER_KEY, taker));

        assertEq(engine.callAt(0).trader, address(wallet));
        assertEq(router.filledQuantity(makerHash), QUANTITY);
    }

    function test_SettleOpen_IsAtomicWhenSecondLegFails() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        bytes32 makerHash = router.hashOrder(maker);
        bytes32 takerHash = router.hashOrder(taker);
        bytes32 fillId = keccak256("reverting-fill");
        bytes memory makerSignature = _sign(MAKER_KEY, maker);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);
        engine.setRevertOnSecond(true);

        vm.prank(executor);
        vm.expectRevert(MockMatchedPerpEngine.SecondLegFailed.selector);
        router.settle(fillId, maker, makerSignature, taker, takerSignature);

        assertFalse(router.isFillUsed(fillId));
        assertEq(router.filledQuantity(makerHash), 0);
        assertEq(router.filledQuantity(takerHash), 0);
        assertEq(engine.callCount(), 0);
    }

    function test_SettleOpen_RejectsFillAndOrderReplay() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        bytes memory makerSignature = _sign(MAKER_KEY, maker);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);
        bytes32 fillId = keccak256("one-shot");
        _settle(fillId, maker, makerSignature, taker, takerSignature);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.FillAlreadyUsed.selector, fillId));
        router.settle(fillId, maker, makerSignature, taker, takerSignature);

        bytes32 makerHash = router.hashOrder(maker);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.OrderUnavailable.selector, makerHash));
        router.settle(keccak256("different-fill"), maker, makerSignature, taker, takerSignature);
    }

    function test_SettleOpen_RejectsInvalidSignature() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        bytes32 makerHash = router.hashOrder(maker);
        bytes memory invalidMakerSignature = _sign(TAKER_KEY, maker);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.InvalidSignature.selector, makerTrader, makerHash));
        router.settle(keccak256("bad-signature"), maker, invalidMakerSignature, taker, takerSignature);
    }

    function test_SettleOpen_RejectsSignatureFromAnotherRouterDomain() public {
        MatchedFillRouter otherRouter = _deployRouter(address(engine), TIMELOCK_DELAY);
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        bytes memory makerSignature = _sign(MAKER_KEY, maker);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);
        bytes32 otherMakerHash = otherRouter.hashOrder(maker);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IMatchedFillRouter.InvalidSignature.selector, makerTrader, otherMakerHash)
        );
        otherRouter.settle(keccak256("wrong-domain"), maker, makerSignature, taker, takerSignature);
    }

    function test_SettleOpen_RejectsUnauthorizedExecutor() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        bytes memory makerSignature = _sign(MAKER_KEY, maker);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.UnauthorizedExecutor.selector, executor, stranger));
        router.settle(keccak256("wrong-executor"), maker, makerSignature, taker, takerSignature);
    }

    function test_SettleOpen_RejectsIncompatiblePair() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        taker.subjectId = keccak256("kendrick");
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IMatchedFillRouter.SubjectMismatch.selector, SUBJECT_ID, taker.subjectId)
        );
        router.settle(keccak256("wrong-subject"), maker, "", taker, "");

        taker = _takerOrder();
        taker.side = maker.side;
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.SideMismatch.selector, maker.side, taker.side));
        router.settle(keccak256("same-side"), maker, "", taker, "");

        taker = _takerOrder();
        taker.quantity -= 1;
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IMatchedFillRouter.FullFillRequired.selector, maker.quantity, taker.quantity)
        );
        router.settle(keccak256("partial"), maker, "", taker, "");
    }

    function test_SettleOpen_RejectsInvalidLiquidityRoles() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        maker.postOnly = false;
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.InvalidLiquidityRole.selector, false, false));
        router.settle(keccak256("wrong-role"), maker, "", taker, "");
    }

    function test_SettleOpen_RejectsTakerLimitViolation() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        taker.limitPrice = 101e18;
        bytes memory makerSignature = _sign(MAKER_KEY, maker);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMatchedFillRouter.LimitPriceExceeded.selector, taker.side, taker.limitPrice, maker.limitPrice
            )
        );
        router.settle(keccak256("bad-price"), maker, makerSignature, taker, takerSignature);
    }

    function test_SettleOpen_FailsClosedOnUnsupportedOrderShapes() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        maker.intent = IMatchedFillRouter.OrderIntent.UNSET;
        bytes memory makerSignature = _sign(MAKER_KEY, maker);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IMatchedFillRouter.InvalidOrderIntent.selector, IMatchedFillRouter.OrderIntent.UNSET)
        );
        router.settle(keccak256("unset"), maker, makerSignature, taker, takerSignature);

        maker = _makerOrder();
        maker.subaccount = keccak256("subaccount");
        makerSignature = _sign(MAKER_KEY, maker);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.UnsupportedSubaccount.selector, maker.subaccount));
        router.settle(keccak256("subaccount"), maker, makerSignature, taker, takerSignature);

        maker = _makerOrder();
        maker.reduceOnly = true;
        makerSignature = _sign(MAKER_KEY, maker);
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMatchedFillRouter.InvalidReduceOnlyForIntent.selector, IMatchedFillRouter.OrderIntent.OPEN, true
            )
        );
        router.settle(keccak256("reduce-only"), maker, makerSignature, taker, takerSignature);
    }

    function test_SettleClose_FailsClosedOnInvalidIntentBindings() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _closeTakerOrder();
        bytes memory makerSignature = _sign(MAKER_KEY, maker);

        taker.positionId = bytes32(0);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMatchedFillRouter.InvalidPositionBinding.selector, IMatchedFillRouter.OrderIntent.CLOSE, bytes32(0)
            )
        );
        router.settle(keccak256("close-no-position"), maker, makerSignature, taker, takerSignature);

        taker = _closeTakerOrder();
        taker.collateralAmount = 1;
        takerSignature = _sign(TAKER_KEY, taker);
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMatchedFillRouter.InvalidCollateralForIntent.selector, IMatchedFillRouter.OrderIntent.CLOSE, uint256(1)
            )
        );
        router.settle(keccak256("close-collateral"), maker, makerSignature, taker, takerSignature);

        taker = _closeTakerOrder();
        taker.reduceOnly = false;
        takerSignature = _sign(TAKER_KEY, taker);
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMatchedFillRouter.InvalidReduceOnlyForIntent.selector, IMatchedFillRouter.OrderIntent.CLOSE, false
            )
        );
        router.settle(keccak256("close-not-reduce-only"), maker, makerSignature, taker, takerSignature);

        taker = _closeTakerOrder();
        taker.postOnly = true;
        takerSignature = _sign(TAKER_KEY, taker);
        vm.prank(executor);
        vm.expectRevert(IMatchedFillRouter.CloseMustBeImmediate.selector);
        router.settle(keccak256("close-post-only"), maker, makerSignature, taker, takerSignature);
    }

    function test_SettleClose_RejectsRestingCloseMaker() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        maker.positionId = keccak256("maker-short-position");
        maker.intent = IMatchedFillRouter.OrderIntent.CLOSE;
        maker.collateralAmount = 0;
        maker.reduceOnly = true;
        bytes memory makerSignature = _sign(MAKER_KEY, maker);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);

        vm.prank(executor);
        vm.expectRevert(IMatchedFillRouter.CloseMakerUnsupported.selector);
        router.settle(keccak256("close-maker"), maker, makerSignature, taker, takerSignature);
    }

    function test_SettleOpen_RejectsExpiredAndOutOfRangeOrders() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        maker.deadline = uint64(block.timestamp - 1);
        bytes memory makerSignature = _sign(MAKER_KEY, maker);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.DeadlineExpired.selector, maker.deadline));
        router.settle(keccak256("expired"), maker, makerSignature, taker, takerSignature);

        maker = _makerOrder();
        maker.maxMarkDivergenceBps = 10_001;
        makerSignature = _sign(MAKER_KEY, maker);
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IMatchedFillRouter.MarkDivergenceBpsOutOfRange.selector, maker.maxMarkDivergenceBps)
        );
        router.settle(keccak256("bad-bps"), maker, makerSignature, taker, takerSignature);
    }

    function test_SettlePair_HappyPath_UsesOneSignedParentAndTwoMakerPrices() public {
        IMatchedFillRouter.Order memory makerA = _pairMakerA();
        IMatchedFillRouter.Order memory makerB = _pairMakerB();
        IMatchedFillRouter.PairOrder memory pair = _pairOrder();
        bytes32 makerHashA = router.hashOrder(makerA);
        bytes32 makerHashB = router.hashOrder(makerB);
        bytes32 pairHash = router.hashPairOrder(pair);
        bytes32 fillId = keccak256("pair-fill");

        IMatchedFillRouter.PairMatchResult memory result = _settlePair(
            fillId,
            makerA,
            _sign(MAKER_KEY, makerA),
            makerB,
            _sign(MAKER_B_KEY, makerB),
            pair,
            _signPair(TAKER_KEY, pair)
        );

        assertTrue(router.isFillUsed(fillId));
        assertTrue(router.isPairOrderFilled(pairHash));
        assertEq(router.filledQuantity(makerHashA), QUANTITY);
        assertEq(router.filledQuantity(makerHashB), QUANTITY_B);
        assertNotEq(result.makerPositionA, bytes32(0));
        assertNotEq(result.makerPositionB, bytes32(0));
        assertNotEq(result.traderPositionA, bytes32(0));
        assertNotEq(result.traderPositionB, bytes32(0));
        assertEq(engine.callCount(), 4);

        MockMatchedPerpEngine.RecordedCall memory makerCallA = engine.callAt(0);
        MockMatchedPerpEngine.RecordedCall memory traderCallA = engine.callAt(1);
        MockMatchedPerpEngine.RecordedCall memory makerCallB = engine.callAt(2);
        MockMatchedPerpEngine.RecordedCall memory traderCallB = engine.callAt(3);
        assertEq(makerCallA.trader, makerTrader);
        assertEq(uint8(makerCallA.side), uint8(IPerpEngine.Side.SHORT));
        assertEq(makerCallA.executionPrice, MAKER_LIMIT);
        assertEq(makerCallA.quantity, QUANTITY);
        assertTrue(makerCallA.isMaker);
        assertEq(traderCallA.trader, takerTrader);
        assertEq(uint8(traderCallA.side), uint8(IPerpEngine.Side.LONG));
        assertEq(traderCallA.executionPrice, MAKER_LIMIT);
        assertFalse(traderCallA.isMaker);
        assertEq(makerCallB.trader, makerTraderB);
        assertEq(uint8(makerCallB.side), uint8(IPerpEngine.Side.LONG));
        assertEq(makerCallB.executionPrice, MAKER_LIMIT_B);
        assertEq(makerCallB.quantity, QUANTITY_B);
        assertTrue(makerCallB.isMaker);
        assertEq(traderCallB.trader, takerTrader);
        assertEq(uint8(traderCallB.side), uint8(IPerpEngine.Side.SHORT));
        assertEq(traderCallB.executionPrice, MAKER_LIMIT_B);
        assertFalse(traderCallB.isMaker);
    }

    function test_SettlePair_IsAtomicWhenFourthPositionFails() public {
        IMatchedFillRouter.Order memory makerA = _pairMakerA();
        IMatchedFillRouter.Order memory makerB = _pairMakerB();
        IMatchedFillRouter.PairOrder memory pair = _pairOrder();
        bytes32 makerHashA = router.hashOrder(makerA);
        bytes32 makerHashB = router.hashOrder(makerB);
        bytes32 pairHash = router.hashPairOrder(pair);
        bytes32 fillId = keccak256("pair-revert");
        bytes memory makerSignatureA = _sign(MAKER_KEY, makerA);
        bytes memory makerSignatureB = _sign(MAKER_B_KEY, makerB);
        bytes memory pairSignature = _signPair(TAKER_KEY, pair);
        engine.setRevertOnCall(4);

        vm.prank(executor);
        vm.expectRevert(MockMatchedPerpEngine.SecondLegFailed.selector);
        router.settlePair(fillId, makerA, makerSignatureA, makerB, makerSignatureB, pair, pairSignature);

        assertFalse(router.isFillUsed(fillId));
        assertFalse(router.isPairOrderFilled(pairHash));
        assertEq(router.filledQuantity(makerHashA), 0);
        assertEq(router.filledQuantity(makerHashB), 0);
        assertEq(engine.callCount(), 0);
    }

    function test_SettlePair_ParentSignatureBindsEveryLegField() public {
        IMatchedFillRouter.Order memory makerA = _pairMakerA();
        IMatchedFillRouter.Order memory makerB = _pairMakerB();
        IMatchedFillRouter.PairOrder memory pair = _pairOrder();
        bytes memory staleSignature = _signPair(TAKER_KEY, pair);
        pair.legB.maxFee += 1;
        bytes32 changedHash = router.hashPairOrder(pair);
        bytes memory makerSignatureA = _sign(MAKER_KEY, makerA);
        bytes memory makerSignatureB = _sign(MAKER_B_KEY, makerB);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.InvalidSignature.selector, takerTrader, changedHash));
        router.settlePair(
            keccak256("mutated-pair"), makerA, makerSignatureA, makerB, makerSignatureB, pair, staleSignature
        );
    }

    function test_SettlePair_RejectsPairReplayWithFreshMakers() public {
        IMatchedFillRouter.Order memory makerA = _pairMakerA();
        IMatchedFillRouter.Order memory makerB = _pairMakerB();
        IMatchedFillRouter.PairOrder memory pair = _pairOrder();
        bytes memory pairSignature = _signPair(TAKER_KEY, pair);
        _settlePair(
            keccak256("pair-once"),
            makerA,
            _sign(MAKER_KEY, makerA),
            makerB,
            _sign(MAKER_B_KEY, makerB),
            pair,
            pairSignature
        );

        makerA.nonce = 101;
        makerB.nonce = 102;
        bytes32 pairHash = router.hashPairOrder(pair);
        bytes memory makerSignatureA = _sign(MAKER_KEY, makerA);
        bytes memory makerSignatureB = _sign(MAKER_B_KEY, makerB);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.OrderUnavailable.selector, pairHash));
        router.settlePair(
            keccak256("pair-twice"), makerA, makerSignatureA, makerB, makerSignatureB, pair, pairSignature
        );
    }

    function test_SettlePair_RejectsInvalidPairShapeBeforeSignatures() public {
        IMatchedFillRouter.Order memory makerA = _pairMakerA();
        IMatchedFillRouter.Order memory makerB = _pairMakerB();
        IMatchedFillRouter.PairOrder memory pair = _pairOrder();

        pair.postOnly = true;
        vm.prank(executor);
        vm.expectRevert(IMatchedFillRouter.PairMustBeImmediate.selector);
        router.settlePair(keccak256("resting-pair"), makerA, "", makerB, "", pair, "");

        pair = _pairOrder();
        pair.legB.subjectId = pair.legA.subjectId;
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMatchedFillRouter.InvalidPairSubjects.selector, pair.legA.subjectId, pair.legB.subjectId
            )
        );
        router.settlePair(keccak256("same-subject-pair"), makerA, "", makerB, "", pair, "");

        pair = _pairOrder();
        pair.legB.side = pair.legA.side;
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IMatchedFillRouter.InvalidPairSides.selector, pair.legA.side, pair.legB.side)
        );
        router.settlePair(keccak256("same-side-pair"), makerA, "", makerB, "", pair, "");
    }

    function test_SettlePair_RejectsMakerMismatchAndSelfTrade() public {
        IMatchedFillRouter.Order memory makerA = _pairMakerA();
        IMatchedFillRouter.Order memory makerB = _pairMakerB();
        IMatchedFillRouter.PairOrder memory pair = _pairOrder();

        makerB.quantity -= 1;
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IMatchedFillRouter.FullFillRequired.selector, makerB.quantity, pair.legB.quantity)
        );
        router.settlePair(keccak256("pair-size-mismatch"), makerA, "", makerB, "", pair, "");

        makerB = _pairMakerB();
        makerB.trader = takerTrader;
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.PairSelfTrade.selector, 1, takerTrader));
        router.settlePair(keccak256("pair-self-trade"), makerA, "", makerB, "", pair, "");

        makerB = _pairMakerB();
        makerB.intent = IMatchedFillRouter.OrderIntent.CLOSE;
        makerB.positionId = keccak256("maker-position");
        makerB.collateralAmount = 0;
        makerB.reduceOnly = true;
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.InvalidPairMaker.selector, 1));
        router.settlePair(keccak256("pair-close-maker"), makerA, "", makerB, "", pair, "");
    }

    function test_SettlePair_RejectsLegLimitViolation() public {
        IMatchedFillRouter.Order memory makerA = _pairMakerA();
        IMatchedFillRouter.Order memory makerB = _pairMakerB();
        IMatchedFillRouter.PairOrder memory pair = _pairOrder();
        pair.legA.limitPrice = 99e18;
        bytes memory makerSignatureA = _sign(MAKER_KEY, makerA);
        bytes memory makerSignatureB = _sign(MAKER_B_KEY, makerB);
        bytes memory pairSignature = _signPair(TAKER_KEY, pair);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMatchedFillRouter.LimitPriceExceeded.selector, pair.legA.side, pair.legA.limitPrice, makerA.limitPrice
            )
        );
        router.settlePair(
            keccak256("pair-limit"), makerA, makerSignatureA, makerB, makerSignatureB, pair, pairSignature
        );
    }

    function test_SettlePair_RejectsNotionalImbalanceBeyondSignedBound() public {
        IMatchedFillRouter.Order memory makerA = _pairMakerA();
        IMatchedFillRouter.Order memory makerB = _pairMakerB();
        IMatchedFillRouter.PairOrder memory pair = _pairOrder();
        makerB.quantity = QUANTITY;
        pair.legB.quantity = QUANTITY;
        bytes memory makerSignatureA = _sign(MAKER_KEY, makerA);
        bytes memory makerSignatureB = _sign(MAKER_B_KEY, makerB);
        bytes memory pairSignature = _signPair(TAKER_KEY, pair);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMatchedFillRouter.NotionalImbalanceExceeded.selector,
                uint256(10_000e6),
                uint256(5_000e6),
                pair.maxNotionalImbalanceBps
            )
        );
        router.settlePair(
            keccak256("pair-imbalance"), makerA, makerSignatureA, makerB, makerSignatureB, pair, pairSignature
        );
    }

    function test_CancelPairOrder_PreventsSettlement() public {
        IMatchedFillRouter.Order memory makerA = _pairMakerA();
        IMatchedFillRouter.Order memory makerB = _pairMakerB();
        IMatchedFillRouter.PairOrder memory pair = _pairOrder();
        bytes32 pairHash = router.hashPairOrder(pair);
        vm.prank(takerTrader);
        router.cancelPairOrder(pair);
        assertTrue(router.isOrderCancelled(pairHash));
        bytes memory makerSignatureA = _sign(MAKER_KEY, makerA);
        bytes memory makerSignatureB = _sign(MAKER_B_KEY, makerB);
        bytes memory pairSignature = _signPair(TAKER_KEY, pair);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.OrderUnavailable.selector, pairHash));
        router.settlePair(
            keccak256("cancelled-pair"), makerA, makerSignatureA, makerB, makerSignatureB, pair, pairSignature
        );
    }

    function test_SettlePair_SupportsERC1271Trader() public {
        MockERC1271Signer wallet = new MockERC1271Signer();
        IMatchedFillRouter.Order memory makerA = _pairMakerA();
        IMatchedFillRouter.Order memory makerB = _pairMakerB();
        IMatchedFillRouter.PairOrder memory pair = _pairOrder();
        pair.trader = address(wallet);
        bytes32 pairHash = router.hashPairOrder(pair);
        wallet.setApproved(pairHash, true);

        _settlePair(
            keccak256("pair-erc1271"),
            makerA,
            _sign(MAKER_KEY, makerA),
            makerB,
            _sign(MAKER_B_KEY, makerB),
            pair,
            bytes("wallet-signature")
        );

        assertEq(engine.callAt(1).trader, address(wallet));
        assertEq(engine.callAt(3).trader, address(wallet));
        assertTrue(router.isPairOrderFilled(pairHash));
    }

    function test_SettlePair_SharesMakerReplayStateWithSingleFill() public {
        IMatchedFillRouter.Order memory makerA = _pairMakerA();
        IMatchedFillRouter.Order memory singleTaker = _takerOrder();
        singleTaker.side = IPerpEngine.Side.LONG;
        singleTaker.limitPrice = 101e18;
        _settle(keccak256("single-first"), makerA, _sign(MAKER_KEY, makerA), singleTaker, _sign(TAKER_KEY, singleTaker));

        IMatchedFillRouter.Order memory makerB = _pairMakerB();
        IMatchedFillRouter.PairOrder memory pair = _pairOrder();
        bytes32 makerHashA = router.hashOrder(makerA);
        bytes memory makerSignatureA = _sign(MAKER_KEY, makerA);
        bytes memory makerSignatureB = _sign(MAKER_B_KEY, makerB);
        bytes memory pairSignature = _signPair(TAKER_KEY, pair);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.OrderUnavailable.selector, makerHashA));
        router.settlePair(
            keccak256("pair-after-single"), makerA, makerSignatureA, makerB, makerSignatureB, pair, pairSignature
        );
    }

    function test_CancelOrder_PreventsSettlement() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        bytes32 makerHash = router.hashOrder(maker);
        vm.prank(makerTrader);
        router.cancelOrder(maker);
        assertTrue(router.isOrderCancelled(makerHash));
        bytes memory makerSignature = _sign(MAKER_KEY, maker);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.OrderUnavailable.selector, makerHash));
        router.settle(keccak256("cancelled"), maker, makerSignature, taker, takerSignature);
    }

    function test_InvalidateNoncesBelow_PreventsSettlement() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        vm.prank(makerTrader);
        router.invalidateNoncesBelow(2);
        assertEq(router.minimumValidNonce(makerTrader), 2);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IMatchedFillRouter.NonceInvalid.selector, makerTrader, maker.nonce, uint256(2))
        );
        router.settle(keccak256("old-nonce"), maker, "", taker, "");
    }

    function test_GovernanceTransfer_IsTimelocked() public {
        address newGovernance = makeAddr("newGovernance");
        vm.prank(governance);
        router.proposeGovernanceTransfer(newGovernance);
        (address pending, uint64 activatesAt) = router.pendingGovernance();
        assertEq(pending, newGovernance);
        assertEq(activatesAt, uint64(block.timestamp + TIMELOCK_DELAY));

        vm.warp(activatesAt);
        router.activateGovernanceTransfer();
        assertEq(router.governance(), newGovernance);
    }

    function test_Upgrade_RevertsForNonGovernance() public {
        MatchedFillRouter newImplementation = new MatchedFillRouter();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.Unauthorized.selector, stranger));
        router.upgradeToAndCall(address(newImplementation), "");
    }

    function test_Upgrade_GovernancePreservesStorage() public {
        MatchedFillRouter newImplementation = new MatchedFillRouter();
        vm.prank(governance);
        router.upgradeToAndCall(address(newImplementation), "");
        assertEq(router.governance(), governance);
        assertEq(router.perpEngine(), address(engine));
        assertEq(router.timelockDelay(), TIMELOCK_DELAY);
    }
}
