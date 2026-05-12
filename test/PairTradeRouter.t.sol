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

import {IPairTradeRouter} from "../src/routers/IPairTradeRouter.sol";
import {PairTradeRouter} from "../src/routers/PairTradeRouter.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev Full-stack wiring identical to PerpEngine.t.sol's setUp, plus the PairTradeRouter UUPS
///      proxy and its registration on PerpEngine. Exercises happy paths, rejects, atomicity, and
///      tier interactions through the router.
contract PairTradeRouterTest is Test {
    PerpEngine internal engine;
    MarginEngine internal marginEngine;
    LPVault internal vault;
    SubjectRegistry internal registry;
    MockUSDC internal usdc;
    PairTradeRouter internal router;

    address internal governance = makeAddr("governance");
    address internal vaultOperator = makeAddr("vaultOperator");
    address internal regAdmin = makeAddr("regAdmin");
    address internal regGuardian = makeAddr("regGuardian");
    address internal kycWriter = makeAddr("kycWriter");
    address internal markWriter = makeAddr("markWriter");

    address internal alice = makeAddr("alice"); // LP
    address internal trader = makeAddr("trader");
    address internal trader2 = makeAddr("trader2");
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

        // 5. PairTradeRouter.
        {
            PairTradeRouter impl = new PairTradeRouter();
            bytes memory initData =
                abi.encodeCall(PairTradeRouter.initialize, (governance, address(engine), TIMELOCK_DELAY));
            router = PairTradeRouter(address(new ERC1967Proxy(address(impl), initData)));
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

        // 8. Configure SubjectRegistry: list subjects, KYC tiers.
        vm.startPrank(regAdmin);
        registry.listSubject(SUBJECT_A, CATEGORY_ID);
        registry.listSubject(SUBJECT_B, CATEGORY_ID);
        vm.stopPrank();
        vm.startPrank(kycWriter);
        registry.setKycTier(trader, 2); // T2 → $250K per-subject, $1M combined
        registry.setKycTier(trader2, 1); // T1 → $50K per-subject, $200K combined
        vm.stopPrank();

        // 9. MarginEngine caps + delta cap + mark writer.
        vm.startPrank(governance);
        marginEngine.setKycCaps(1, 50_000 * ONE_USDC, 200_000 * ONE_USDC);
        marginEngine.setKycCaps(2, 250_000 * ONE_USDC, 1_000_000 * ONE_USDC);
        marginEngine.setKycCaps(3, 1_000_000 * ONE_USDC, 4_000_000 * ONE_USDC);
        engine.setMarkMaxDeltaBps(5_000);
        engine.proposeAddMarkWriter(markWriter);
        // Register the router on PerpEngine (timelocked).
        engine.proposeAddRouter(address(router));
        vm.stopPrank();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateAddMarkWriter(markWriter);
        engine.activateAddRouter(address(router));

        // 10. Push initial marks.
        vm.startPrank(markWriter);
        engine.pushMark(SUBJECT_A, INITIAL_MARK);
        engine.pushMark(SUBJECT_B, INITIAL_MARK);
        vm.stopPrank();

        // 11. Fund actors + approve vault.
        usdc.mint(alice, USDC_10M);
        usdc.mint(trader, USDC_1M);
        usdc.mint(trader2, USDC_1M);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader2);
        usdc.approve(address(vault), type(uint256).max);

        // 12. Seed LP and prime cap snapshot.
        vm.prank(alice);
        vault.deposit(USDC_10M, alice); // $10M so 5% per-subject cap = $500K
        engine.pokeCappedTvl();
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    /// @dev Sensible default pair: $10K long Drake + $10K short Taylor, $50K notional each at
    ///      $100 mark. Trader (T2) is well under the $250K per-subject cap and the $1M combined.
    function _baseParams() internal view returns (IPairTradeRouter.PairParams memory p) {
        p = IPairTradeRouter.PairParams({
            longSubjectId: SUBJECT_A,
            longCollateral: 10_000 * ONE_USDC,
            longSizeNotional: 50_000 * ONE_USDC,
            longExpectedMark: INITIAL_MARK,
            longMaxSlippageBps: 100,
            longIsMaker: false,
            shortSubjectId: SUBJECT_B,
            shortCollateral: 10_000 * ONE_USDC,
            shortSizeNotional: 50_000 * ONE_USDC,
            shortExpectedMark: INITIAL_MARK,
            shortMaxSlippageBps: 100,
            shortIsMaker: false,
            maxTotalCollateral: 25_000 * ONE_USDC,
            deadline: uint64(block.timestamp + 1 hours)
        });
    }

    function _openPair(IPairTradeRouter.PairParams memory p)
        internal
        returns (IPairTradeRouter.PairResult memory result)
    {
        vm.prank(trader);
        return router.openPair(p);
    }

    // ------------------------------------------------------------------------------------------
    // initialize
    // ------------------------------------------------------------------------------------------

    function test_Initialize_StoresParams() public view {
        assertEq(router.governance(), governance);
        assertEq(router.perpEngine(), address(engine));
        assertEq(router.timelockDelay(), TIMELOCK_DELAY);
        (address pendGov, uint64 pendTs) = router.pendingGovernance();
        assertEq(pendGov, address(0));
        assertEq(pendTs, 0);
    }

    function test_Initialize_RevertOnZeroGovernance() public {
        PairTradeRouter impl = new PairTradeRouter();
        bytes memory initData =
            abi.encodeCall(PairTradeRouter.initialize, (address(0), address(engine), TIMELOCK_DELAY));
        vm.expectRevert(IPairTradeRouter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroEngine() public {
        PairTradeRouter impl = new PairTradeRouter();
        bytes memory initData = abi.encodeCall(PairTradeRouter.initialize, (governance, address(0), TIMELOCK_DELAY));
        vm.expectRevert(IPairTradeRouter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooShort() public {
        PairTradeRouter impl = new PairTradeRouter();
        bytes memory initData =
            abi.encodeCall(PairTradeRouter.initialize, (governance, address(engine), uint32(1 minutes)));
        vm.expectRevert(IPairTradeRouter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooLong() public {
        PairTradeRouter impl = new PairTradeRouter();
        bytes memory initData =
            abi.encodeCall(PairTradeRouter.initialize, (governance, address(engine), uint32(60 days)));
        vm.expectRevert(IPairTradeRouter.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_DoubleInitReverts() public {
        vm.expectRevert();
        router.initialize(governance, address(engine), TIMELOCK_DELAY);
    }

    // ------------------------------------------------------------------------------------------
    // openPair — happy paths
    // ------------------------------------------------------------------------------------------

    function test_OpenPair_HappyPath_BothPositionsExist() public {
        IPairTradeRouter.PairParams memory p = _baseParams();
        IPairTradeRouter.PairResult memory result = _openPair(p);

        // Long leg.
        IPerpEngine.Position memory posL = engine.positionOf(result.longPositionId);
        assertEq(posL.owner, trader);
        assertEq(posL.subjectId, SUBJECT_A);
        assertGt(posL.size, 0);
        assertEq(posL.collateral, p.longCollateral);

        // Short leg.
        IPerpEngine.Position memory posS = engine.positionOf(result.shortPositionId);
        assertEq(posS.owner, trader);
        assertEq(posS.subjectId, SUBJECT_B);
        assertLt(posS.size, 0);
        assertEq(posS.collateral, p.shortCollateral);

        // Result echoes combined collateral.
        assertEq(result.totalCollateralLocked, p.longCollateral + p.shortCollateral);

        // PerpEngine indices wired up.
        assertEq(engine.positionIdOf(trader, SUBJECT_A), result.longPositionId);
        assertEq(engine.positionIdOf(trader, SUBJECT_B), result.shortPositionId);

        // OI counters reflect both legs.
        (uint256 longA, uint256 shortA) = engine.openInterestOf(SUBJECT_A);
        assertEq(longA, p.longSizeNotional);
        assertEq(shortA, 0);
        (uint256 longB, uint256 shortB) = engine.openInterestOf(SUBJECT_B);
        assertEq(longB, 0);
        assertEq(shortB, p.shortSizeNotional);
    }

    function test_OpenPair_EmitsPairOpened() public {
        IPairTradeRouter.PairParams memory p = _baseParams();
        // The position ids are computed via the engine's monotonic nonce; we can't predict the
        // exact ids without re-running the open path, so check selectively (topic1=trader,
        // data=totalCollateralLocked + subject ids).
        vm.recordLogs();
        IPairTradeRouter.PairResult memory result = _openPair(p);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("PairOpened(address,bytes32,bytes32,bytes32,bytes32,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            if (logs[i].emitter != address(router)) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), trader);
            assertEq(logs[i].topics[2], result.longPositionId);
            assertEq(logs[i].topics[3], result.shortPositionId);
            (bytes32 longSubject, bytes32 shortSubject, uint256 total) =
                abi.decode(logs[i].data, (bytes32, bytes32, uint256));
            assertEq(longSubject, SUBJECT_A);
            assertEq(shortSubject, SUBJECT_B);
            assertEq(total, p.longCollateral + p.shortCollateral);
            found = true;
            break;
        }
        assertTrue(found, "PairOpened not emitted");
    }

    function test_OpenPair_TraderFundsDebited() public {
        // Both legs pull collateral + fee from the trader. Verify USDC.balanceOf(trader) drops
        // by exactly (longCollateral + shortCollateral + longFee + shortFee).
        IPairTradeRouter.PairParams memory p = _baseParams();
        uint256 longFee = (p.longSizeNotional * 750) / 1_000_000;
        uint256 shortFee = (p.shortSizeNotional * 750) / 1_000_000;
        uint256 traderBalBefore = usdc.balanceOf(trader);
        uint256 routerBalBefore = usdc.balanceOf(address(router));

        _openPair(p);

        assertEq(usdc.balanceOf(trader), traderBalBefore - p.longCollateral - p.shortCollateral - longFee - shortFee);
        // Router never touches funds.
        assertEq(usdc.balanceOf(address(router)), routerBalBefore);
    }

    function test_OpenPair_MakerFeeLeg() public {
        IPairTradeRouter.PairParams memory p = _baseParams();
        p.longIsMaker = true; // maker leg long; short stays taker
        uint256 longFee = (p.longSizeNotional * 250) / 1_000_000; // 0.025% maker
        uint256 shortFee = (p.shortSizeNotional * 750) / 1_000_000;
        uint256 traderBalBefore = usdc.balanceOf(trader);

        _openPair(p);

        assertEq(usdc.balanceOf(trader), traderBalBefore - p.longCollateral - p.shortCollateral - longFee - shortFee);
    }

    // ------------------------------------------------------------------------------------------
    // openPair — reverts
    // ------------------------------------------------------------------------------------------

    function test_OpenPair_RevertOnSameSubject() public {
        IPairTradeRouter.PairParams memory p = _baseParams();
        p.shortSubjectId = p.longSubjectId;
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPairTradeRouter.SameSubject.selector, SUBJECT_A));
        router.openPair(p);
    }

    function test_OpenPair_RevertOnDeadlineExpired() public {
        IPairTradeRouter.PairParams memory p = _baseParams();
        uint64 dl = uint64(block.timestamp) - 1;
        p.deadline = dl;
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPairTradeRouter.DeadlineExpired.selector, dl));
        router.openPair(p);
    }

    function test_OpenPair_RevertOnTotalCapExceeded() public {
        IPairTradeRouter.PairParams memory p = _baseParams();
        p.maxTotalCollateral = p.longCollateral + p.shortCollateral - 1;
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPairTradeRouter.TotalCollateralTooHigh.selector,
                p.longCollateral + p.shortCollateral,
                p.maxTotalCollateral
            )
        );
        router.openPair(p);
    }

    function test_OpenPair_RevertOnZeroLongCollateral() public {
        IPairTradeRouter.PairParams memory p = _baseParams();
        p.longCollateral = 0;
        vm.prank(trader);
        vm.expectRevert(IPairTradeRouter.InvalidConfig.selector);
        router.openPair(p);
    }

    function test_OpenPair_RevertOnZeroShortCollateral() public {
        IPairTradeRouter.PairParams memory p = _baseParams();
        p.shortCollateral = 0;
        vm.prank(trader);
        vm.expectRevert(IPairTradeRouter.InvalidConfig.selector);
        router.openPair(p);
    }

    function test_OpenPair_RevertOnZeroLongSize() public {
        IPairTradeRouter.PairParams memory p = _baseParams();
        p.longSizeNotional = 0;
        vm.prank(trader);
        vm.expectRevert(IPairTradeRouter.InvalidConfig.selector);
        router.openPair(p);
    }

    function test_OpenPair_RevertOnZeroShortSize() public {
        IPairTradeRouter.PairParams memory p = _baseParams();
        p.shortSizeNotional = 0;
        vm.prank(trader);
        vm.expectRevert(IPairTradeRouter.InvalidConfig.selector);
        router.openPair(p);
    }

    // ------------------------------------------------------------------------------------------
    // Atomicity — leg B revert must roll back leg A
    // ------------------------------------------------------------------------------------------

    function test_OpenPair_LegBRevert_LegADoesNotPersist() public {
        // Send the second leg to a subject that doesn't exist → registry's requireTradeable
        // reverts. Verify the first leg was rolled back: no Drake position, OI cleared.
        IPairTradeRouter.PairParams memory p = _baseParams();
        bytes32 missing = keccak256("nonexistent");
        p.shortSubjectId = missing;

        vm.prank(trader);
        vm.expectRevert();
        router.openPair(p);

        // Confirm atomicity:
        assertEq(engine.positionIdOf(trader, SUBJECT_A), bytes32(0));
        assertEq(engine.positionIdOf(trader, missing), bytes32(0));
        (uint256 longA, uint256 shortA) = engine.openInterestOf(SUBJECT_A);
        assertEq(longA, 0);
        assertEq(shortA, 0);
    }

    function test_OpenPair_LegARevertPropagates() public {
        // First leg: subject paused → requireTradeable reverts. Whole tx reverts.
        vm.prank(regGuardian);
        registry.setAutoPaused(SUBJECT_A, 1);

        IPairTradeRouter.PairParams memory p = _baseParams();
        vm.prank(trader);
        vm.expectRevert();
        router.openPair(p);

        // Nothing opened on either leg.
        assertEq(engine.positionIdOf(trader, SUBJECT_A), bytes32(0));
        assertEq(engine.positionIdOf(trader, SUBJECT_B), bytes32(0));
    }

    function test_OpenPair_LegBSlippage_RollsBackLegA() public {
        // Push subject B's mark out of bounds before opening; the slippage check on leg B fires
        // and the tx unwinds.
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_B, 120 * ONE_18); // +20%, beyond 1% slippage tolerance

        IPairTradeRouter.PairParams memory p = _baseParams();
        // shortExpectedMark still set to INITIAL_MARK; slippage delta is 20% vs 1% bound.
        vm.prank(trader);
        vm.expectRevert();
        router.openPair(p);

        assertEq(engine.positionIdOf(trader, SUBJECT_A), bytes32(0));
        assertEq(engine.positionIdOf(trader, SUBJECT_B), bytes32(0));
    }

    // ------------------------------------------------------------------------------------------
    // Cap interactions (combined-exposure + tier-aware)
    // ------------------------------------------------------------------------------------------

    function test_OpenPair_T1_BothLegsWithinPerSubjectCap_Succeeds() public {
        // T1 trader: $50K per-subject cap, $200K combined. $50K long + $50K short = $100K total.
        // Each leg at exactly the per-subject cap. IM at 20% = $10K each. Total = $20K.
        IPairTradeRouter.PairParams memory p = _baseParams();
        p.longSizeNotional = 50_000 * ONE_USDC;
        p.shortSizeNotional = 50_000 * ONE_USDC;
        p.longCollateral = 10_000 * ONE_USDC;
        p.shortCollateral = 10_000 * ONE_USDC;
        p.maxTotalCollateral = 25_000 * ONE_USDC;

        vm.prank(trader2); // T1
        IPairTradeRouter.PairResult memory result = router.openPair(p);
        assertTrue(result.longPositionId != bytes32(0));
        assertTrue(result.shortPositionId != bytes32(0));
    }

    function test_OpenPair_LegBExceedsCombinedCap_Reverts() public {
        // Tighten T2 combined cap so a $250K + $250K pair would breach the combined cap on the
        // second leg. Per-subject cap stays at $250K so each leg individually is allowed; the
        // combined cap is the binding constraint.
        vm.prank(governance);
        marginEngine.setKycCaps(2, 250_000 * ONE_USDC, 400_000 * ONE_USDC); // combined < 2×per-subject

        IPairTradeRouter.PairParams memory p = _baseParams();
        p.longSizeNotional = 250_000 * ONE_USDC;
        p.shortSizeNotional = 250_000 * ONE_USDC;
        p.longCollateral = 50_000 * ONE_USDC; // 20% IM
        p.shortCollateral = 50_000 * ONE_USDC;
        p.maxTotalCollateral = 110_000 * ONE_USDC;

        vm.prank(trader);
        // Combined would be 500K > 400K → engine reverts CombinedExposureCapExceeded on leg B.
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarginEngine.CombinedExposureCapExceeded.selector, trader, 500_000 * ONE_USDC, 400_000 * ONE_USDC
            )
        );
        router.openPair(p);

        // Both legs rolled back atomically.
        assertEq(engine.positionIdOf(trader, SUBJECT_A), bytes32(0));
        assertEq(engine.positionIdOf(trader, SUBJECT_B), bytes32(0));
    }

    function test_OpenPair_T2_LargePair_Succeeds() public {
        // T2 trader: $250K per-subject, $1M combined. Pair $250K + $250K = $500K total,
        // well under $1M combined. Per-subject side OI cap on $10M vault @ 5% = $500K so each
        // leg fits (and contributes only its own notional to its subject's side OI).
        IPairTradeRouter.PairParams memory p = _baseParams();
        p.longSizeNotional = 250_000 * ONE_USDC;
        p.shortSizeNotional = 250_000 * ONE_USDC;
        p.longCollateral = 50_000 * ONE_USDC; // 20% IM
        p.shortCollateral = 50_000 * ONE_USDC;
        p.maxTotalCollateral = 110_000 * ONE_USDC;

        vm.prank(trader);
        IPairTradeRouter.PairResult memory result = router.openPair(p);
        assertEq(result.totalCollateralLocked, 100_000 * ONE_USDC);
    }

    // ------------------------------------------------------------------------------------------
    // Router registration on PerpEngine
    // ------------------------------------------------------------------------------------------

    function test_OpenPair_RevertsIfRouterNotRegisteredOnEngine() public {
        // Deploy a second router that is NOT registered on the engine. Calling openPair should
        // bubble up `OnlyRouter` from PerpEngine on the first leg.
        PairTradeRouter impl = new PairTradeRouter();
        bytes memory initData =
            abi.encodeCall(PairTradeRouter.initialize, (governance, address(engine), TIMELOCK_DELAY));
        PairTradeRouter unregistered = PairTradeRouter(address(new ERC1967Proxy(address(impl), initData)));

        IPairTradeRouter.PairParams memory p = _baseParams();
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyRouter.selector, address(unregistered)));
        unregistered.openPair(p);
    }

    function test_OpenPair_RouterRevokedAtEngine_Reverts() public {
        // Revoke the router at the engine; subsequent openPair must revert at leg A.
        vm.prank(governance);
        engine.removeRouter(address(router));

        IPairTradeRouter.PairParams memory p = _baseParams();
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyRouter.selector, address(router)));
        router.openPair(p);
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
        vm.expectRevert(abi.encodeWithSelector(IPairTradeRouter.Unauthorized.selector, stranger));
        router.proposeGovernanceTransfer(makeAddr("x"));
    }

    function test_Governance_ProposeRevertsOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IPairTradeRouter.InvalidConfig.selector);
        router.proposeGovernanceTransfer(address(0));
    }

    function test_Governance_ProposeRevertsOnPendingExists() public {
        vm.startPrank(governance);
        router.proposeGovernanceTransfer(makeAddr("a"));
        vm.expectRevert(IPairTradeRouter.PendingProposalExists.selector);
        router.proposeGovernanceTransfer(makeAddr("b"));
        vm.stopPrank();
    }

    function test_Governance_ActivateRevertsOnNoPending() public {
        vm.expectRevert(IPairTradeRouter.NoPendingProposal.selector);
        router.activateGovernanceTransfer();
    }

    function test_Governance_ActivateRevertsOnTimelockNotElapsed() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        router.proposeGovernanceTransfer(newGov);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(IPairTradeRouter.TimelockNotElapsed.selector, readyAt));
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
        vm.expectRevert(IPairTradeRouter.NoPendingProposal.selector);
        router.cancelGovernanceTransfer();
    }

    // ------------------------------------------------------------------------------------------
    // UUPS upgrade authorization
    // ------------------------------------------------------------------------------------------

    function test_Upgrade_RevertOnNonGovernance() public {
        PairTradeRouter newImpl = new PairTradeRouter();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPairTradeRouter.Unauthorized.selector, stranger));
        router.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_GovernanceCanUpgrade() public {
        PairTradeRouter newImpl = new PairTradeRouter();
        vm.prank(governance);
        router.upgradeToAndCall(address(newImpl), "");
        // Storage preserved across upgrade — governance still set, perpEngine still wired.
        assertEq(router.governance(), governance);
        assertEq(router.perpEngine(), address(engine));
    }
}
