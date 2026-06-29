// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IMarginEngine} from "../src/core/IMarginEngine.sol";
import {IPerpEngine} from "../src/core/IPerpEngine.sol";
import {LPVault} from "../src/core/LPVault.sol";
import {MarginEngine} from "../src/core/MarginEngine.sol";
import {PerpEngine} from "../src/core/PerpEngine.sol";

import {SubjectRegistry} from "../src/registry/SubjectRegistry.sol";

import {BatchRouter} from "../src/routers/BatchRouter.sol";
import {IBatchRouter} from "../src/routers/IBatchRouter.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev Full-stack wiring mirroring PairTradeRouter.t.sol with BatchRouter swapped in. Covers
///      initialize, every OpKind, all-or-nothing semantics, governance levers, and the underlying
///      `*For` access gate on PerpEngine.
contract BatchRouterTest is Test {
    PerpEngine internal engine;
    MarginEngine internal marginEngine;
    LPVault internal vault;
    SubjectRegistry internal registry;
    MockUSDC internal usdc;
    BatchRouter internal router;

    address internal governance = makeAddr("governance");
    address internal vaultOperator = makeAddr("vaultOperator");
    address internal regAdmin = makeAddr("regAdmin");
    address internal regGuardian = makeAddr("regGuardian");
    address internal kycWriter = makeAddr("kycWriter");
    address internal markWriter = makeAddr("markWriter");

    address internal alice = makeAddr("alice"); // LP
    address internal trader = makeAddr("trader");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant SUBJECT_A = keccak256("drake");
    bytes32 internal constant SUBJECT_B = keccak256("taylor");
    bytes32 internal constant CATEGORY_ID = keccak256("musician");

    uint32 internal constant TIMELOCK_DELAY = 2 days;
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant USDC_1M = 1_000_000 * ONE_USDC;
    uint256 internal constant USDC_10M = 10 * USDC_1M;
    uint256 internal constant ONE_18 = 1e18;
    uint256 internal constant INITIAL_MARK = 100 * ONE_18;

    // ------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------

    function setUp() public {
        vm.warp(2_000_000_000);

        usdc = new MockUSDC();

        // 1. SubjectRegistry.
        {
            SubjectRegistry impl = new SubjectRegistry();
            address[] memory admins = new address[](1);
            admins[0] = regAdmin;
            address[] memory guardians = new address[](1);
            guardians[0] = regGuardian;
            address[] memory writers = new address[](1);
            writers[0] = kycWriter;
            bytes memory initData =
                abi.encodeCall(SubjectRegistry.initialize, (governance, TIMELOCK_DELAY, admins, guardians, writers));
            registry = SubjectRegistry(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 2. LPVault.
        {
            LPVault impl = new LPVault();
            bytes memory initData = abi.encodeCall(
                LPVault.initialize,
                (IERC20(address(usdc)), governance, vaultOperator, TIMELOCK_DELAY, "People Markets LP USDC", "pmUSDC")
            );
            vault = LPVault(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 3. PerpEngine.
        {
            PerpEngine impl = new PerpEngine();
            bytes memory initData =
                abi.encodeCall(PerpEngine.initialize, (governance, TIMELOCK_DELAY, address(registry), address(vault)));
            engine = PerpEngine(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 4. MarginEngine.
        {
            MarginEngine impl = new MarginEngine();
            bytes memory initData =
                abi.encodeCall(MarginEngine.initialize, (governance, address(engine), TIMELOCK_DELAY));
            marginEngine = MarginEngine(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 5. BatchRouter.
        {
            BatchRouter impl = new BatchRouter();
            bytes memory initData =
                abi.encodeCall(BatchRouter.initialize, (governance, address(engine), TIMELOCK_DELAY));
            router = BatchRouter(address(new ERC1967Proxy(address(impl), initData)));
        }

        // 6. Wire LPVault → PerpEngine.
        vm.prank(governance);
        vault.proposeSetPerpEngine(address(engine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateSetPerpEngine();

        // 7. Wire PerpEngine → MarginEngine.
        vm.prank(governance);
        engine.proposeSetMarginEngine(address(marginEngine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetMarginEngine();

        // 8. SubjectRegistry: list subjects, KYC tiers.
        vm.startPrank(regAdmin);
        registry.listSubject(SUBJECT_A, CATEGORY_ID);
        registry.listSubject(SUBJECT_B, CATEGORY_ID);
        vm.stopPrank();
        vm.startPrank(kycWriter);
        registry.setKycTier(trader, 2); // T2 → $250K per-subject, $1M combined
        vm.stopPrank();

        // 9. Margin caps + delta cap + mark writer + router registration.
        vm.startPrank(governance);
        marginEngine.setKycCaps(1, 50_000 * ONE_USDC, 200_000 * ONE_USDC);
        marginEngine.setKycCaps(2, 250_000 * ONE_USDC, 1_000_000 * ONE_USDC);
        marginEngine.setKycCaps(3, 1_000_000 * ONE_USDC, 4_000_000 * ONE_USDC);
        engine.setMarkMaxDeltaBps(5_000);
        engine.proposeAddMarkWriter(markWriter);
        engine.proposeAddRouter(address(router));
        vm.stopPrank();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateAddMarkWriter(markWriter);
        engine.activateAddRouter(address(router));

        // 10. Initial marks.
        vm.startPrank(markWriter);
        engine.pushMark(SUBJECT_A, INITIAL_MARK);
        engine.pushMark(SUBJECT_B, INITIAL_MARK);
        vm.stopPrank();

        // 11. Fund actors + approve vault.
        usdc.mint(alice, USDC_10M);
        usdc.mint(trader, USDC_1M);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);

        // 12. Seed LP and prime cap snapshot.
        vm.prank(alice);
        vault.deposit(USDC_10M, alice);
        engine.pokeCappedTvl();
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _baseOpen(bytes32 subjectId, IPerpEngine.Side side) internal view returns (IPerpEngine.OpenParams memory) {
        return IPerpEngine.OpenParams({
            subjectId: subjectId,
            side: side,
            collateralAmount: 10_000 * ONE_USDC,
            sizeNotional: 50_000 * ONE_USDC,
            expectedMark: INITIAL_MARK,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
    }

    function _baseClose(bytes32 subjectId) internal view returns (IPerpEngine.CloseParams memory) {
        return IPerpEngine.CloseParams({
            subjectId: subjectId,
            sizeFractionBps: 10_000,
            expectedMark: INITIAL_MARK,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
    }

    function _openOp(bytes32 subjectId, IPerpEngine.Side side) internal view returns (IBatchRouter.BatchOp memory) {
        return IBatchRouter.BatchOp({
            kind: IBatchRouter.OpKind.OPEN,
            openData: abi.encode(_baseOpen(subjectId, side)),
            closeData: bytes(""),
            positionId: bytes32(0),
            amount: 0
        });
    }

    function _closeOp(bytes32 subjectId) internal view returns (IBatchRouter.BatchOp memory) {
        return IBatchRouter.BatchOp({
            kind: IBatchRouter.OpKind.CLOSE,
            openData: bytes(""),
            closeData: abi.encode(_baseClose(subjectId)),
            positionId: bytes32(0),
            amount: 0
        });
    }

    function _addOp(bytes32 positionId, uint256 amount) internal pure returns (IBatchRouter.BatchOp memory) {
        return IBatchRouter.BatchOp({
            kind: IBatchRouter.OpKind.ADD_COLLATERAL,
            openData: bytes(""),
            closeData: bytes(""),
            positionId: positionId,
            amount: amount
        });
    }

    function _removeOp(bytes32 positionId, uint256 amount) internal pure returns (IBatchRouter.BatchOp memory) {
        return IBatchRouter.BatchOp({
            kind: IBatchRouter.OpKind.REMOVE_COLLATERAL,
            openData: bytes(""),
            closeData: bytes(""),
            positionId: positionId,
            amount: amount
        });
    }

    function _batch(IBatchRouter.BatchOp[] memory ops) internal view returns (IBatchRouter.BatchParams memory) {
        return IBatchRouter.BatchParams({ops: ops, deadline: uint64(block.timestamp + 1 hours)});
    }

    function _execute(IBatchRouter.BatchOp[] memory ops) internal returns (IBatchRouter.OpResult[] memory) {
        vm.prank(trader);
        return router.executeBatch(_batch(ops));
    }

    // ------------------------------------------------------------------------------------------
    // initialize
    // ------------------------------------------------------------------------------------------

    function test_Initialize_StoresParams() public view {
        assertEq(router.governance(), governance);
        assertEq(router.perpEngine(), address(engine));
        assertEq(router.timelockDelay(), TIMELOCK_DELAY);
        assertEq(router.maxBatchSize(), 20);
        (address pendGov, uint64 pendTs) = router.pendingGovernance();
        assertEq(pendGov, address(0));
        assertEq(pendTs, 0);
    }

    function test_Initialize_RevertOnZeroGovernance() public {
        BatchRouter impl = new BatchRouter();
        bytes memory initData = abi.encodeCall(BatchRouter.initialize, (address(0), address(engine), TIMELOCK_DELAY));
        vm.expectRevert(IBatchRouter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroEngine() public {
        BatchRouter impl = new BatchRouter();
        bytes memory initData = abi.encodeCall(BatchRouter.initialize, (governance, address(0), TIMELOCK_DELAY));
        vm.expectRevert(IBatchRouter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooShort() public {
        BatchRouter impl = new BatchRouter();
        bytes memory initData = abi.encodeCall(BatchRouter.initialize, (governance, address(engine), uint32(1 minutes)));
        vm.expectRevert(IBatchRouter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooLong() public {
        BatchRouter impl = new BatchRouter();
        bytes memory initData = abi.encodeCall(BatchRouter.initialize, (governance, address(engine), uint32(60 days)));
        vm.expectRevert(IBatchRouter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_DoubleInitReverts() public {
        vm.expectRevert();
        router.initialize(governance, address(engine), TIMELOCK_DELAY);
    }

    // ------------------------------------------------------------------------------------------
    // executeBatch — happy paths
    // ------------------------------------------------------------------------------------------

    function test_ExecuteBatch_SingleOpen() public {
        IBatchRouter.BatchOp[] memory ops = new IBatchRouter.BatchOp[](1);
        ops[0] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);

        IBatchRouter.OpResult[] memory results = _execute(ops);
        assertEq(results.length, 1);
        assertTrue(results[0].kind == IBatchRouter.OpKind.OPEN);
        assertTrue(results[0].positionId != bytes32(0));
        assertEq(results[0].pnl, int256(0));

        IPerpEngine.Position memory pos = engine.positionOf(results[0].positionId);
        assertEq(pos.owner, trader);
        assertEq(pos.subjectId, SUBJECT_A);
        assertGt(pos.size, 0);
    }

    function test_ExecuteBatch_SingleClose() public {
        // Seed: open via the router so trader owns a position.
        IBatchRouter.BatchOp[] memory openOps = new IBatchRouter.BatchOp[](1);
        openOps[0] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);
        bytes32 openedId = _execute(openOps)[0].positionId;

        IBatchRouter.BatchOp[] memory closeOps = new IBatchRouter.BatchOp[](1);
        closeOps[0] = _closeOp(SUBJECT_A);

        IBatchRouter.OpResult[] memory results = _execute(closeOps);
        assertEq(results.length, 1);
        assertTrue(results[0].kind == IBatchRouter.OpKind.CLOSE);
        assertEq(results[0].positionId, openedId);
        assertEq(results[0].pnl, int256(0)); // mark unchanged → 0 PnL

        // Position is gone.
        assertEq(engine.positionIdOf(trader, SUBJECT_A), bytes32(0));
    }

    function test_ExecuteBatch_SingleAddCollateral() public {
        IBatchRouter.BatchOp[] memory openOps = new IBatchRouter.BatchOp[](1);
        openOps[0] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);
        bytes32 positionId = _execute(openOps)[0].positionId;

        IBatchRouter.BatchOp[] memory addOps = new IBatchRouter.BatchOp[](1);
        addOps[0] = _addOp(positionId, 5_000 * ONE_USDC);
        IBatchRouter.OpResult[] memory results = _execute(addOps);
        assertTrue(results[0].kind == IBatchRouter.OpKind.ADD_COLLATERAL);
        assertEq(results[0].positionId, positionId);
        assertEq(engine.positionOf(positionId).collateral, 15_000 * ONE_USDC);
    }

    function test_ExecuteBatch_SingleRemoveCollateral() public {
        // Open with extra collateral so we can remove some.
        IPerpEngine.OpenParams memory openParams = _baseOpen(SUBJECT_A, IPerpEngine.Side.LONG);
        openParams.collateralAmount = 20_000 * ONE_USDC;
        IBatchRouter.BatchOp[] memory openOps = new IBatchRouter.BatchOp[](1);
        openOps[0] = IBatchRouter.BatchOp({
            kind: IBatchRouter.OpKind.OPEN,
            openData: abi.encode(openParams),
            closeData: bytes(""),
            positionId: bytes32(0),
            amount: 0
        });
        bytes32 positionId = _execute(openOps)[0].positionId;

        IBatchRouter.BatchOp[] memory removeOps = new IBatchRouter.BatchOp[](1);
        removeOps[0] = _removeOp(positionId, 9_000 * ONE_USDC);
        IBatchRouter.OpResult[] memory results = _execute(removeOps);
        assertTrue(results[0].kind == IBatchRouter.OpKind.REMOVE_COLLATERAL);
        assertEq(engine.positionOf(positionId).collateral, 11_000 * ONE_USDC);
    }

    function test_ExecuteBatch_PairTrade_LongAShortB() public {
        IBatchRouter.BatchOp[] memory ops = new IBatchRouter.BatchOp[](2);
        ops[0] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);
        ops[1] = _openOp(SUBJECT_B, IPerpEngine.Side.SHORT);

        IBatchRouter.OpResult[] memory results = _execute(ops);
        assertEq(results.length, 2);

        IPerpEngine.Position memory posA = engine.positionOf(results[0].positionId);
        IPerpEngine.Position memory posB = engine.positionOf(results[1].positionId);
        assertEq(posA.subjectId, SUBJECT_A);
        assertGt(posA.size, 0);
        assertEq(posB.subjectId, SUBJECT_B);
        assertLt(posB.size, 0);
    }

    function test_ExecuteBatch_OpenThenAddCollateral_SamePosition() public {
        // Open + add in one tx. The router's open op returns the positionId, but inside a single
        // BatchParams we have to use the openPositionId mapping after the open lands — we can't
        // forward the positionId between ops in this version (each op is self-describing). Use
        // positionIdOf via subjectId by adding a single OPEN first, then submit an ADD pointing
        // at the (now known) id in the SAME executeBatch call constructed beforehand. We use a
        // 2-tx style: open, then build the add against the resulting id.
        IBatchRouter.BatchOp[] memory openOps = new IBatchRouter.BatchOp[](1);
        openOps[0] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);
        bytes32 positionId = _execute(openOps)[0].positionId;

        // Now combine open + add in one tx on a different subject; the add references the SAME
        // existing positionId on A.
        IBatchRouter.BatchOp[] memory ops = new IBatchRouter.BatchOp[](2);
        ops[0] = _openOp(SUBJECT_B, IPerpEngine.Side.LONG);
        ops[1] = _addOp(positionId, 5_000 * ONE_USDC);
        _execute(ops);

        assertEq(engine.positionOf(positionId).collateral, 15_000 * ONE_USDC);
        assertTrue(engine.positionIdOf(trader, SUBJECT_B) != bytes32(0));
    }

    function test_ExecuteBatch_CloseThenOpen_Sequential() public {
        // Seed: open A.
        IBatchRouter.BatchOp[] memory seed = new IBatchRouter.BatchOp[](1);
        seed[0] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);
        _execute(seed);

        // Batch: close A, then open A again (same subject). Possible because the close runs first
        // and clears the one-position-per-(trader, subject) lock.
        IBatchRouter.BatchOp[] memory ops = new IBatchRouter.BatchOp[](2);
        ops[0] = _closeOp(SUBJECT_A);
        ops[1] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);
        IBatchRouter.OpResult[] memory results = _execute(ops);

        assertTrue(results[0].kind == IBatchRouter.OpKind.CLOSE);
        assertTrue(results[1].kind == IBatchRouter.OpKind.OPEN);
        assertTrue(engine.positionIdOf(trader, SUBJECT_A) != bytes32(0));
        assertTrue(engine.positionIdOf(trader, SUBJECT_A) == results[1].positionId);
    }

    function test_ExecuteBatch_EmitsBatchExecuted() public {
        IBatchRouter.BatchOp[] memory ops = new IBatchRouter.BatchOp[](2);
        ops[0] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);
        ops[1] = _openOp(SUBJECT_B, IPerpEngine.Side.SHORT);

        vm.recordLogs();
        _execute(ops);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("BatchExecuted(address,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            if (logs[i].emitter != address(router)) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), trader);
            uint256 count = abi.decode(logs[i].data, (uint256));
            assertEq(count, 2);
            found = true;
            break;
        }
        assertTrue(found, "BatchExecuted not emitted");
    }

    // ------------------------------------------------------------------------------------------
    // executeBatch — reverts
    // ------------------------------------------------------------------------------------------

    function test_ExecuteBatch_RevertOnEmpty() public {
        IBatchRouter.BatchOp[] memory ops = new IBatchRouter.BatchOp[](0);
        vm.prank(trader);
        vm.expectRevert(IBatchRouter.EmptyBatch.selector);
        router.executeBatch(_batch(ops));
    }

    function test_ExecuteBatch_RevertOnBatchTooLarge() public {
        // Shrink the cap so we can trip BatchTooLarge with a small batch.
        vm.prank(governance);
        router.setMaxBatchSize(2);

        IBatchRouter.BatchOp[] memory ops = new IBatchRouter.BatchOp[](3);
        ops[0] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);
        ops[1] = _openOp(SUBJECT_B, IPerpEngine.Side.SHORT);
        ops[2] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IBatchRouter.BatchTooLarge.selector, 3, 2));
        router.executeBatch(_batch(ops));
    }

    function test_ExecuteBatch_RevertOnDeadlineExpired() public {
        IBatchRouter.BatchOp[] memory ops = new IBatchRouter.BatchOp[](1);
        ops[0] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);

        IBatchRouter.BatchParams memory params =
            IBatchRouter.BatchParams({ops: ops, deadline: uint64(block.timestamp) - 1});
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IBatchRouter.DeadlineExpired.selector, params.deadline));
        router.executeBatch(params);
    }

    function test_ExecuteBatch_RevertOnUnsetOpKind() public {
        IBatchRouter.BatchOp[] memory ops = new IBatchRouter.BatchOp[](1);
        ops[0] = IBatchRouter.BatchOp({
            kind: IBatchRouter.OpKind.UNSET,
            openData: bytes(""),
            closeData: bytes(""),
            positionId: bytes32(0),
            amount: 0
        });

        vm.prank(trader);
        vm.expectRevert(IBatchRouter.InvalidOpKind.selector);
        router.executeBatch(_batch(ops));
    }

    // ------------------------------------------------------------------------------------------
    // executeBatch — atomicity: leg failure rolls back preceding legs
    // ------------------------------------------------------------------------------------------

    function test_ExecuteBatch_FailingLegRollsBackPreviousLegs() public {
        // Leg A succeeds (open long Drake). Leg B forces a revert by passing a tiny collateral
        // that fails IM. Verify Leg A is unwound — no position on Drake.
        IBatchRouter.BatchOp[] memory ops = new IBatchRouter.BatchOp[](2);
        ops[0] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);

        IPerpEngine.OpenParams memory bad = _baseOpen(SUBJECT_B, IPerpEngine.Side.LONG);
        bad.collateralAmount = 1; // way below IM
        ops[1] = IBatchRouter.BatchOp({
            kind: IBatchRouter.OpKind.OPEN,
            openData: abi.encode(bad),
            closeData: bytes(""),
            positionId: bytes32(0),
            amount: 0
        });

        vm.prank(trader);
        vm.expectRevert();
        router.executeBatch(_batch(ops));

        // Atomicity check.
        assertEq(engine.positionIdOf(trader, SUBJECT_A), bytes32(0));
        assertEq(engine.positionIdOf(trader, SUBJECT_B), bytes32(0));
    }

    function test_ExecuteBatch_FailingCloseRollsBackOpen() public {
        // Open Drake in batch, then attempt to close a non-existent Taylor position — close
        // reverts on PositionNotOpen and the entire batch unwinds.
        IBatchRouter.BatchOp[] memory ops = new IBatchRouter.BatchOp[](2);
        ops[0] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);
        ops[1] = _closeOp(SUBJECT_B); // no Taylor position exists

        vm.prank(trader);
        vm.expectRevert();
        router.executeBatch(_batch(ops));

        assertEq(engine.positionIdOf(trader, SUBJECT_A), bytes32(0));
    }

    // ------------------------------------------------------------------------------------------
    // PerpEngine `*For` access gates
    // ------------------------------------------------------------------------------------------

    function test_RouterRevokedAtEngine_BatchReverts() public {
        vm.prank(governance);
        engine.removeRouter(address(router));

        IBatchRouter.BatchOp[] memory ops = new IBatchRouter.BatchOp[](1);
        ops[0] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyRouter.selector, address(router)));
        router.executeBatch(_batch(ops));
    }

    function test_UnregisteredRouter_BatchReverts() public {
        // Deploy a second router NOT registered on the engine. Each `*For` call must bubble
        // OnlyRouter on the first leg.
        BatchRouter impl = new BatchRouter();
        bytes memory initData = abi.encodeCall(BatchRouter.initialize, (governance, address(engine), TIMELOCK_DELAY));
        BatchRouter unregistered = BatchRouter(address(new ERC1967Proxy(address(impl), initData)));

        IBatchRouter.BatchOp[] memory ops = new IBatchRouter.BatchOp[](1);
        ops[0] = _openOp(SUBJECT_A, IPerpEngine.Side.LONG);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyRouter.selector, address(unregistered)));
        unregistered.executeBatch(_batch(ops));
    }

    // ------------------------------------------------------------------------------------------
    // setMaxBatchSize
    // ------------------------------------------------------------------------------------------

    function test_SetMaxBatchSize_HappyPath() public {
        vm.prank(governance);
        router.setMaxBatchSize(50);
        assertEq(router.maxBatchSize(), 50);
    }

    function test_SetMaxBatchSize_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IBatchRouter.Unauthorized.selector, stranger));
        router.setMaxBatchSize(50);
    }

    function test_SetMaxBatchSize_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IBatchRouter.MaxBatchSizeOutOfRange.selector, uint16(0)));
        router.setMaxBatchSize(0);
    }

    function test_SetMaxBatchSize_RevertOnTooLarge() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IBatchRouter.MaxBatchSizeOutOfRange.selector, uint16(101)));
        router.setMaxBatchSize(101);
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    function test_Governance_TransferIsTimelocked() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        router.proposeGovernanceTransfer(newGov);
        (address pendGov, uint64 pendTs) = router.pendingGovernance();
        assertEq(pendGov, newGov);
        assertEq(pendTs, uint64(block.timestamp + TIMELOCK_DELAY));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        router.activateGovernanceTransfer();
        assertEq(router.governance(), newGov);
        (pendGov, pendTs) = router.pendingGovernance();
        assertEq(pendGov, address(0));
        assertEq(pendTs, 0);
    }

    function test_Governance_ProposeRevertsOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IBatchRouter.Unauthorized.selector, stranger));
        router.proposeGovernanceTransfer(makeAddr("x"));
    }

    function test_Governance_ProposeRevertsOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IBatchRouter.InvalidConfig.selector);
        router.proposeGovernanceTransfer(address(0));
    }

    function test_Governance_ProposeRevertsOnPendingExists() public {
        vm.startPrank(governance);
        router.proposeGovernanceTransfer(makeAddr("a"));
        vm.expectRevert(IBatchRouter.PendingProposalExists.selector);
        router.proposeGovernanceTransfer(makeAddr("b"));
        vm.stopPrank();
    }

    function test_Governance_ActivateRevertsOnNoPending() public {
        vm.expectRevert(IBatchRouter.NoPendingProposal.selector);
        router.activateGovernanceTransfer();
    }

    function test_Governance_ActivateRevertsOnTimelockNotElapsed() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        router.proposeGovernanceTransfer(newGov);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(IBatchRouter.TimelockNotElapsed.selector, readyAt));
        router.activateGovernanceTransfer();
    }

    function test_Governance_CancelHappyPath() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        router.proposeGovernanceTransfer(newGov);
        vm.prank(governance);
        router.cancelGovernanceTransfer();
        (address pendGov, uint64 pendTs) = router.pendingGovernance();
        assertEq(pendGov, address(0));
        assertEq(pendTs, 0);
    }

    function test_Governance_CancelRevertsOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(IBatchRouter.NoPendingProposal.selector);
        router.cancelGovernanceTransfer();
    }

    // ------------------------------------------------------------------------------------------
    // UUPS upgrade authorization
    // ------------------------------------------------------------------------------------------

    function test_Upgrade_RevertOnNonGovernance() public {
        BatchRouter newImpl = new BatchRouter();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IBatchRouter.Unauthorized.selector, stranger));
        router.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_GovernanceCanUpgrade() public {
        BatchRouter newImpl = new BatchRouter();
        vm.prank(governance);
        router.upgradeToAndCall(address(newImpl), "");
        // Storage preserved across upgrade.
        assertEq(router.governance(), governance);
        assertEq(router.perpEngine(), address(engine));
        assertEq(router.maxBatchSize(), 20);
    }
}
