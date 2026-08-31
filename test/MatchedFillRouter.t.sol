// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test} from "forge-std/Test.sol";

import {IPerpEngine} from "../src/core/IPerpEngine.sol";
import {IMatchedFillRouter} from "../src/routers/IMatchedFillRouter.sol";
import {MatchedFillRouter} from "../src/routers/MatchedFillRouter.sol";

contract MockMatchedPerpEngine {
    error SecondLegFailed();

    struct RecordedOpen {
        address trader;
        bytes32 subjectId;
        IPerpEngine.Side side;
        uint256 collateralAmount;
        uint256 sizeNotional;
        uint256 executionPrice;
        uint256 maxMarkDivergenceBps;
        uint256 maxFee;
        uint64 deadline;
        bool isMaker;
    }

    RecordedOpen[] private _calls;
    bool public revertOnSecond;

    function setRevertOnSecond(bool enabled) external {
        revertOnSecond = enabled;
    }

    function openPositionForMatched(
        address trader,
        IPerpEngine.MatchedOpenParams calldata p
    )
        external
        returns (bytes32 positionId)
    {
        if (revertOnSecond && _calls.length == 1) revert SecondLegFailed();
        positionId = keccak256(abi.encode(trader, p.subjectId, p.side, p.sizeNotional, p.executionPrice, _calls.length));
        _calls.push(
            RecordedOpen({
                trader: trader,
                subjectId: p.subjectId,
                side: p.side,
                collateralAmount: p.collateralAmount,
                sizeNotional: p.sizeNotional,
                executionPrice: p.executionPrice,
                maxMarkDivergenceBps: p.maxMarkDivergenceBps,
                maxFee: p.maxFee,
                deadline: p.deadline,
                isMaker: p.isMaker
            })
        );
    }

    function callCount() external view returns (uint256) {
        return _calls.length;
    }

    function callAt(uint256 index) external view returns (RecordedOpen memory) {
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
    uint256 internal constant TAKER_KEY = 0xB0B;
    uint32 internal constant TIMELOCK_DELAY = 1 hours;
    bytes32 internal constant SUBJECT_ID = keccak256("drake");
    uint256 internal constant SIZE_NOTIONAL = 10_000e6;
    uint256 internal constant MAKER_LIMIT = 100e18;

    address internal governance = makeAddr("governance");
    address internal executor = makeAddr("executor");
    address internal stranger = makeAddr("stranger");
    address internal makerTrader;
    address internal takerTrader;

    function setUp() public {
        vm.warp(2_000_000_000);
        makerTrader = vm.addr(MAKER_KEY);
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
            side: IPerpEngine.Side.LONG,
            intent: IMatchedFillRouter.OrderIntent.OPEN,
            sizeNotional: SIZE_NOTIONAL,
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
            side: IPerpEngine.Side.SHORT,
            intent: IMatchedFillRouter.OrderIntent.OPEN,
            sizeNotional: SIZE_NOTIONAL,
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

    function _sign(uint256 privateKey, IMatchedFillRouter.Order memory order) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, router.hashOrder(order));
        return abi.encodePacked(r, s, v);
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
        return router.settleOpen(fillId, maker, makerSignature, taker, takerSignature);
    }

    function test_Initialize_StoresConfigAndDomain() public view {
        assertEq(router.governance(), governance);
        assertEq(router.perpEngine(), address(engine));
        assertEq(router.timelockDelay(), TIMELOCK_DELAY);
        assertNotEq(router.domainSeparator(), bytes32(0));
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
        assertEq(router.filledSize(makerHash), SIZE_NOTIONAL);
        assertEq(router.filledSize(takerHash), SIZE_NOTIONAL);
        assertEq(engine.callCount(), 2);

        MockMatchedPerpEngine.RecordedOpen memory makerCall = engine.callAt(0);
        MockMatchedPerpEngine.RecordedOpen memory takerCall = engine.callAt(1);
        assertEq(makerCall.trader, makerTrader);
        assertEq(uint8(makerCall.side), uint8(IPerpEngine.Side.LONG));
        assertEq(makerCall.executionPrice, MAKER_LIMIT);
        assertEq(makerCall.sizeNotional, SIZE_NOTIONAL);
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

    function test_SettleOpen_SupportsERC1271Trader() public {
        MockERC1271Signer wallet = new MockERC1271Signer();
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        maker.trader = address(wallet);
        bytes32 makerHash = router.hashOrder(maker);
        wallet.setApproved(makerHash, true);

        _settle(keccak256("erc1271"), maker, bytes("wallet-signature"), taker, _sign(TAKER_KEY, taker));

        assertEq(engine.callAt(0).trader, address(wallet));
        assertEq(router.filledSize(makerHash), SIZE_NOTIONAL);
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
        router.settleOpen(fillId, maker, makerSignature, taker, takerSignature);

        assertFalse(router.isFillUsed(fillId));
        assertEq(router.filledSize(makerHash), 0);
        assertEq(router.filledSize(takerHash), 0);
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
        router.settleOpen(fillId, maker, makerSignature, taker, takerSignature);

        bytes32 makerHash = router.hashOrder(maker);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.OrderUnavailable.selector, makerHash));
        router.settleOpen(keccak256("different-fill"), maker, makerSignature, taker, takerSignature);
    }

    function test_SettleOpen_RejectsInvalidSignature() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        bytes32 makerHash = router.hashOrder(maker);
        bytes memory invalidMakerSignature = _sign(TAKER_KEY, maker);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.InvalidSignature.selector, makerTrader, makerHash));
        router.settleOpen(keccak256("bad-signature"), maker, invalidMakerSignature, taker, takerSignature);
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
        otherRouter.settleOpen(keccak256("wrong-domain"), maker, makerSignature, taker, takerSignature);
    }

    function test_SettleOpen_RejectsUnauthorizedExecutor() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        bytes memory makerSignature = _sign(MAKER_KEY, maker);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.UnauthorizedExecutor.selector, executor, stranger));
        router.settleOpen(keccak256("wrong-executor"), maker, makerSignature, taker, takerSignature);
    }

    function test_SettleOpen_RejectsIncompatiblePair() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        taker.subjectId = keccak256("kendrick");
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IMatchedFillRouter.SubjectMismatch.selector, SUBJECT_ID, taker.subjectId)
        );
        router.settleOpen(keccak256("wrong-subject"), maker, "", taker, "");

        taker = _takerOrder();
        taker.side = maker.side;
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.SideMismatch.selector, maker.side, taker.side));
        router.settleOpen(keccak256("same-side"), maker, "", taker, "");

        taker = _takerOrder();
        taker.sizeNotional -= 1;
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IMatchedFillRouter.FullFillRequired.selector, maker.sizeNotional, taker.sizeNotional)
        );
        router.settleOpen(keccak256("partial"), maker, "", taker, "");
    }

    function test_SettleOpen_RejectsInvalidLiquidityRoles() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        maker.postOnly = false;
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.InvalidLiquidityRole.selector, false, false));
        router.settleOpen(keccak256("wrong-role"), maker, "", taker, "");
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
        router.settleOpen(keccak256("bad-price"), maker, makerSignature, taker, takerSignature);
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
        router.settleOpen(keccak256("unset"), maker, makerSignature, taker, takerSignature);

        maker = _makerOrder();
        maker.subaccount = keccak256("subaccount");
        makerSignature = _sign(MAKER_KEY, maker);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.UnsupportedSubaccount.selector, maker.subaccount));
        router.settleOpen(keccak256("subaccount"), maker, makerSignature, taker, takerSignature);

        maker = _makerOrder();
        maker.reduceOnly = true;
        makerSignature = _sign(MAKER_KEY, maker);
        vm.prank(executor);
        vm.expectRevert(IMatchedFillRouter.ReduceOnlyUnsupported.selector);
        router.settleOpen(keccak256("reduce-only"), maker, makerSignature, taker, takerSignature);
    }

    function test_SettleOpen_RejectsExpiredAndOutOfRangeOrders() public {
        IMatchedFillRouter.Order memory maker = _makerOrder();
        IMatchedFillRouter.Order memory taker = _takerOrder();
        maker.deadline = uint64(block.timestamp - 1);
        bytes memory makerSignature = _sign(MAKER_KEY, maker);
        bytes memory takerSignature = _sign(TAKER_KEY, taker);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IMatchedFillRouter.DeadlineExpired.selector, maker.deadline));
        router.settleOpen(keccak256("expired"), maker, makerSignature, taker, takerSignature);

        maker = _makerOrder();
        maker.maxMarkDivergenceBps = 10_001;
        makerSignature = _sign(MAKER_KEY, maker);
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IMatchedFillRouter.MarkDivergenceBpsOutOfRange.selector, maker.maxMarkDivergenceBps)
        );
        router.settleOpen(keccak256("bad-bps"), maker, makerSignature, taker, takerSignature);
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
        router.settleOpen(keccak256("cancelled"), maker, makerSignature, taker, takerSignature);
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
        router.settleOpen(keccak256("old-nonce"), maker, "", taker, "");
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
