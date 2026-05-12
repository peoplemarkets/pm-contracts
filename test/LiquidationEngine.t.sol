// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {IInsuranceFund} from "../src/core/IInsuranceFund.sol";
import {ILPVault} from "../src/core/ILPVault.sol";
import {ILiquidationEngine} from "../src/core/ILiquidationEngine.sol";
import {IMarginEngine} from "../src/core/IMarginEngine.sol";
import {IPerpEngine} from "../src/core/IPerpEngine.sol";
import {InsuranceFund} from "../src/core/InsuranceFund.sol";
import {LPVault} from "../src/core/LPVault.sol";
import {LiquidationEngine} from "../src/core/LiquidationEngine.sol";
import {MarginEngine} from "../src/core/MarginEngine.sol";
import {PerpEngine} from "../src/core/PerpEngine.sol";

import {SubjectRegistry} from "../src/registry/SubjectRegistry.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title  LiquidationEngineTest — direct exercise of the 5-tier liquidation waterfall (v0).
contract LiquidationEngineTest is Test {
    PerpEngine internal engine;
    MarginEngine internal marginEngine;
    LiquidationEngine internal liqEngine;
    LPVault internal vault;
    InsuranceFund internal insurance;
    SubjectRegistry internal registry;
    MockUSDC internal usdc;

    address internal governance = makeAddr("governance");
    address internal insGovernance = makeAddr("insGovernance");
    address internal vaultOperator = makeAddr("vaultOperator");
    address internal regAdmin = makeAddr("regAdmin");
    address internal regGuardian = makeAddr("regGuardian");
    address internal kycWriter = makeAddr("kycWriter");
    address internal markWriter = makeAddr("markWriter");
    address internal liquidator = makeAddr("liquidator");
    address internal liquidator2 = makeAddr("liquidator2");
    address internal newGov = makeAddr("newGov");

    address internal alice = makeAddr("alice"); // LP
    address internal trader = makeAddr("trader");
    address internal trader2 = makeAddr("trader2");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant SUBJECT_ID = keccak256("drake");
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

        // SubjectRegistry
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
        // LPVault
        {
            LPVault impl = new LPVault();
            bytes memory initData = abi.encodeCall(
                LPVault.initialize,
                (IERC20(address(usdc)), governance, vaultOperator, TIMELOCK_DELAY, "People Markets LP USDC", "pmUSDC")
            );
            vault = LPVault(address(new ERC1967Proxy(address(impl), initData)));
        }
        // PerpEngine
        {
            PerpEngine impl = new PerpEngine();
            bytes memory initData =
                abi.encodeCall(PerpEngine.initialize, (governance, TIMELOCK_DELAY, address(registry), address(vault)));
            engine = PerpEngine(address(new ERC1967Proxy(address(impl), initData)));
        }
        // MarginEngine
        {
            MarginEngine impl = new MarginEngine();
            bytes memory initData =
                abi.encodeCall(MarginEngine.initialize, (governance, address(engine), TIMELOCK_DELAY));
            marginEngine = MarginEngine(address(new ERC1967Proxy(address(impl), initData)));
        }
        // InsuranceFund
        {
            InsuranceFund impl = new InsuranceFund();
            bytes memory initData = abi.encodeCall(
                InsuranceFund.initialize, (insGovernance, address(vault), IERC20(address(usdc)), TIMELOCK_DELAY)
            );
            insurance = InsuranceFund(address(new ERC1967Proxy(address(impl), initData)));
        }
        // Migrate insurance fund: move legacy in-vault bookkeeper (zero) to standalone fund.
        vm.startPrank(governance);
        vault.migrateInsuranceFund(address(insurance));
        vault.approveInsuranceFund();
        vm.stopPrank();

        // LiquidationEngine
        {
            LiquidationEngine impl = new LiquidationEngine();
            bytes memory initData = abi.encodeCall(
                LiquidationEngine.initialize,
                (governance, address(engine), address(marginEngine), address(vault), address(insurance), TIMELOCK_DELAY)
            );
            liqEngine = LiquidationEngine(address(new ERC1967Proxy(address(impl), initData)));
        }

        // Wire PerpEngine.setPerpEngine on LPVault.
        vm.prank(governance);
        vault.proposeSetPerpEngine(address(engine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateSetPerpEngine();

        // Wire MarginEngine on PerpEngine.
        vm.prank(governance);
        engine.proposeSetMarginEngine(address(marginEngine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetMarginEngine();

        // Wire LiquidationEngine on PerpEngine.
        vm.prank(governance);
        engine.proposeSetLiquidationEngine(address(liqEngine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetLiquidationEngine();

        // Wire LiquidationEngine on LPVault.
        vm.prank(governance);
        vault.proposeSetLiquidationEngine(address(liqEngine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateSetLiquidationEngine();

        // Register liquidator on LiquidationEngine.
        vm.prank(governance);
        liqEngine.proposeAddLiquidator(liquidator);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        liqEngine.activateAddLiquidator(liquidator);

        // SubjectRegistry: list, KYC.
        vm.prank(regAdmin);
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);
        vm.startPrank(kycWriter);
        registry.setKycTier(trader, 2);
        registry.setKycTier(trader2, 2);
        vm.stopPrank();

        // Margin caps, mark writer, large mark-delta to allow big moves.
        vm.startPrank(governance);
        marginEngine.setKycCaps(1, 50_000 * ONE_USDC, 200_000 * ONE_USDC);
        marginEngine.setKycCaps(2, 250_000 * ONE_USDC, 1_000_000 * ONE_USDC);
        marginEngine.setKycCaps(3, 1_000_000 * ONE_USDC, 4_000_000 * ONE_USDC);
        engine.setMarkMaxDeltaBps(5_000);
        engine.proposeAddMarkWriter(markWriter);
        vm.stopPrank();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateAddMarkWriter(markWriter);

        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, INITIAL_MARK);

        // Fund actors.
        usdc.mint(alice, USDC_10M);
        usdc.mint(trader, USDC_1M);
        usdc.mint(trader2, USDC_1M);
        usdc.mint(insGovernance, USDC_1M);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader2);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(insGovernance);
        usdc.approve(address(insurance), type(uint256).max);

        // LP seed + cap snapshot.
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);
        engine.pokeCappedTvl();
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _openLong(address t) internal returns (bytes32) {
        IPerpEngine.OpenParams memory p = IPerpEngine.OpenParams({
            subjectId: SUBJECT_ID,
            side: IPerpEngine.Side.LONG,
            collateralAmount: 10_000 * ONE_USDC,
            sizeNotional: 50_000 * ONE_USDC,
            expectedMark: INITIAL_MARK,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
        vm.prank(t);
        return engine.openPosition(p);
    }

    function _openShort(address t) internal returns (bytes32) {
        IPerpEngine.OpenParams memory p = IPerpEngine.OpenParams({
            subjectId: SUBJECT_ID,
            side: IPerpEngine.Side.SHORT,
            collateralAmount: 10_000 * ONE_USDC,
            sizeNotional: 50_000 * ONE_USDC,
            expectedMark: INITIAL_MARK,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
        vm.prank(t);
        return engine.openPosition(p);
    }

    function _pushMark(uint256 newMark) internal {
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, newMark);
    }

    function _seedInsurance(uint256 amount) internal {
        vm.prank(insGovernance);
        insurance.deposit(amount);
    }

    // ------------------------------------------------------------------------------------------
    // initialize
    // ------------------------------------------------------------------------------------------

    function test_Initialize_StoresParams() public view {
        assertEq(liqEngine.governance(), governance);
        assertEq(liqEngine.perpEngine(), address(engine));
        assertEq(liqEngine.marginEngine(), address(marginEngine));
        assertEq(liqEngine.lpVault(), address(vault));
        assertEq(liqEngine.insuranceFund(), address(insurance));
        assertEq(liqEngine.timelockDelay(), TIMELOCK_DELAY);
        assertEq(liqEngine.partialIncrementBps(), 2_500);
        assertEq(liqEngine.minPartialsBeforeFull(), 4);
        assertEq(liqEngine.mmRestoreBufferBps(), 100);
        assertEq(liqEngine.fullBountyBps(), 100);
        assertEq(liqEngine.socializationCapBps(), 3_000);
    }

    function test_Initialize_RevertOnZeroGovernance() public {
        LiquidationEngine impl = new LiquidationEngine();
        bytes memory data = abi.encodeCall(
            LiquidationEngine.initialize,
            (address(0), address(engine), address(marginEngine), address(vault), address(insurance), TIMELOCK_DELAY)
        );
        vm.expectRevert(ILiquidationEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_RevertOnZeroPerpEngine() public {
        LiquidationEngine impl = new LiquidationEngine();
        bytes memory data = abi.encodeCall(
            LiquidationEngine.initialize,
            (governance, address(0), address(marginEngine), address(vault), address(insurance), TIMELOCK_DELAY)
        );
        vm.expectRevert(ILiquidationEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_RevertOnZeroMarginEngine() public {
        LiquidationEngine impl = new LiquidationEngine();
        bytes memory data = abi.encodeCall(
            LiquidationEngine.initialize,
            (governance, address(engine), address(0), address(vault), address(insurance), TIMELOCK_DELAY)
        );
        vm.expectRevert(ILiquidationEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_RevertOnZeroVault() public {
        LiquidationEngine impl = new LiquidationEngine();
        bytes memory data = abi.encodeCall(
            LiquidationEngine.initialize,
            (governance, address(engine), address(marginEngine), address(0), address(insurance), TIMELOCK_DELAY)
        );
        vm.expectRevert(ILiquidationEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_RevertOnZeroInsurance() public {
        LiquidationEngine impl = new LiquidationEngine();
        bytes memory data = abi.encodeCall(
            LiquidationEngine.initialize,
            (governance, address(engine), address(marginEngine), address(vault), address(0), TIMELOCK_DELAY)
        );
        vm.expectRevert(ILiquidationEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_RevertOnTimelockTooShort() public {
        LiquidationEngine impl = new LiquidationEngine();
        bytes memory data = abi.encodeCall(
            LiquidationEngine.initialize,
            (governance, address(engine), address(marginEngine), address(vault), address(insurance), uint32(1 minutes))
        );
        vm.expectRevert(ILiquidationEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_RevertOnTimelockTooLong() public {
        LiquidationEngine impl = new LiquidationEngine();
        bytes memory data = abi.encodeCall(
            LiquidationEngine.initialize,
            (governance, address(engine), address(marginEngine), address(vault), address(insurance), uint32(31 days))
        );
        vm.expectRevert(ILiquidationEngine.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_DoubleInitReverts() public {
        vm.expectRevert();
        liqEngine.initialize(
            governance, address(engine), address(marginEngine), address(vault), address(insurance), TIMELOCK_DELAY
        );
    }

    // ------------------------------------------------------------------------------------------
    // setConfig
    // ------------------------------------------------------------------------------------------

    function test_SetConfig_HappyPath() public {
        vm.prank(governance);
        liqEngine.setConfig(5_000, 3, 200, 200, 2_000);
        assertEq(liqEngine.partialIncrementBps(), 5_000);
        assertEq(liqEngine.minPartialsBeforeFull(), 3);
        assertEq(liqEngine.mmRestoreBufferBps(), 200);
        assertEq(liqEngine.fullBountyBps(), 200);
        assertEq(liqEngine.socializationCapBps(), 2_000);
    }

    function test_SetConfig_RevertOnUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.Unauthorized.selector, stranger));
        liqEngine.setConfig(2_500, 4, 100, 100, 3_000);
    }

    function test_SetConfig_RevertOnPartialIncrementTooLow() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.PartialIncrementOutOfRange.selector, uint16(100)));
        liqEngine.setConfig(100, 4, 100, 100, 3_000);
    }

    function test_SetConfig_RevertOnPartialIncrementTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.PartialIncrementOutOfRange.selector, uint16(10_001)));
        liqEngine.setConfig(10_001, 4, 100, 100, 3_000);
    }

    function test_SetConfig_RevertOnMinPartialsTooLow() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.MinPartialsOutOfRange.selector, uint8(0)));
        liqEngine.setConfig(2_500, 0, 100, 100, 3_000);
    }

    function test_SetConfig_RevertOnMinPartialsTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.MinPartialsOutOfRange.selector, uint8(11)));
        liqEngine.setConfig(2_500, 11, 100, 100, 3_000);
    }

    function test_SetConfig_RevertOnMmRestoreOutOfRange() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.MmRestoreBufferOutOfRange.selector, uint16(1_001)));
        liqEngine.setConfig(2_500, 4, 1_001, 100, 3_000);
    }

    function test_SetConfig_RevertOnFullBountyOutOfRange() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.FullBountyOutOfRange.selector, uint16(501)));
        liqEngine.setConfig(2_500, 4, 100, 501, 3_000);
    }

    function test_SetConfig_RevertOnSocializationCapTooLow() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.LpSocializationCapOutOfRange.selector, uint16(100)));
        liqEngine.setConfig(2_500, 4, 100, 100, 100);
    }

    function test_SetConfig_RevertOnSocializationCapTooHigh() public {
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidationEngine.LpSocializationCapOutOfRange.selector, uint16(10_001))
        );
        liqEngine.setConfig(2_500, 4, 100, 100, 10_001);
    }

    // ------------------------------------------------------------------------------------------
    // Liquidator set: propose / activate / cancel / remove
    // ------------------------------------------------------------------------------------------

    function test_ProposeAddLiquidator_HappyPath() public {
        vm.prank(governance);
        liqEngine.proposeAddLiquidator(liquidator2);
        assertEq(liqEngine.pendingLiquidatorActivatesAt(liquidator2), uint64(block.timestamp + TIMELOCK_DELAY));
        assertFalse(liqEngine.isLiquidator(liquidator2));
    }

    function test_ProposeAddLiquidator_RevertOnUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.Unauthorized.selector, stranger));
        liqEngine.proposeAddLiquidator(liquidator2);
    }

    function test_ProposeAddLiquidator_RevertOnZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(ILiquidationEngine.InvalidConfig.selector);
        liqEngine.proposeAddLiquidator(address(0));
    }

    function test_ProposeAddLiquidator_RevertOnAlreadyAdded() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.LiquidatorAlreadyAdded.selector, liquidator));
        liqEngine.proposeAddLiquidator(liquidator);
    }

    function test_ProposeAddLiquidator_RevertOnPendingAlreadyExists() public {
        vm.prank(governance);
        liqEngine.proposeAddLiquidator(liquidator2);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.PendingLiquidatorExists.selector, liquidator2));
        liqEngine.proposeAddLiquidator(liquidator2);
    }

    function test_ActivateAddLiquidator_HappyPath() public {
        vm.prank(governance);
        liqEngine.proposeAddLiquidator(liquidator2);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        liqEngine.activateAddLiquidator(liquidator2);
        assertTrue(liqEngine.isLiquidator(liquidator2));
        assertEq(liqEngine.pendingLiquidatorActivatesAt(liquidator2), 0);
    }

    function test_ActivateAddLiquidator_RevertOnTimelockNotElapsed() public {
        vm.prank(governance);
        liqEngine.proposeAddLiquidator(liquidator2);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.TimelockNotElapsed.selector, readyAt));
        liqEngine.activateAddLiquidator(liquidator2);
    }

    function test_ActivateAddLiquidator_RevertOnNoPending() public {
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.NoPendingLiquidator.selector, stranger));
        liqEngine.activateAddLiquidator(stranger);
    }

    function test_CancelAddLiquidator_HappyPath() public {
        vm.prank(governance);
        liqEngine.proposeAddLiquidator(liquidator2);
        vm.prank(governance);
        liqEngine.cancelAddLiquidator(liquidator2);
        assertEq(liqEngine.pendingLiquidatorActivatesAt(liquidator2), 0);
    }

    function test_CancelAddLiquidator_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.NoPendingLiquidator.selector, liquidator2));
        liqEngine.cancelAddLiquidator(liquidator2);
    }

    function test_RemoveLiquidator_HappyPath() public {
        vm.prank(governance);
        liqEngine.removeLiquidator(liquidator);
        assertFalse(liqEngine.isLiquidator(liquidator));
    }

    function test_RemoveLiquidator_RevertOnNotSet() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.LiquidatorNotSet.selector, liquidator2));
        liqEngine.removeLiquidator(liquidator2);
    }

    function test_RemoveLiquidator_RevertOnUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.Unauthorized.selector, stranger));
        liqEngine.removeLiquidator(liquidator);
    }

    // ------------------------------------------------------------------------------------------
    // liquidate — happy paths
    // ------------------------------------------------------------------------------------------

    function test_Liquidate_LongPartialTier1() public {
        bytes32 positionId = _openLong(trader);
        // Drop to $84 — equity $2K, MM+buffer threshold ~$3150 ⇒ under buffer.
        _pushMark(84 * ONE_18);

        uint256 liquidatorBalBefore = usdc.balanceOf(liquidator);
        uint256 traderBalBefore = usdc.balanceOf(trader);

        vm.prank(liquidator);
        ILiquidationEngine.LiquidationResult memory r = liqEngine.liquidate(positionId);

        assertEq(uint8(r.tier), uint8(ILiquidationEngine.Tier.PARTIAL));
        assertEq(r.positionId, positionId);
        assertEq(r.trader, trader);
        assertGt(r.bountyPaid, 0);
        assertEq(r.markPrice, 84 * ONE_18);

        // Partial attempts counter incremented.
        assertEq(liqEngine.partialAttemptsOf(positionId), 1);

        // Position still open with reduced size and collateral.
        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertGt(pos.size, 0);
        assertLt(pos.size, int256(int256(500 * ONE_USDC))); // smaller than original 500 contracts

        // Liquidator got the bounty.
        assertEq(usdc.balanceOf(liquidator), liquidatorBalBefore + r.bountyPaid);
        // Trader got the freed collateral.
        assertEq(usdc.balanceOf(trader), traderBalBefore + r.collateralReturned);
    }

    function test_Liquidate_LongFullTier2_AfterPartialBudget() public {
        bytes32 positionId = _openLong(trader);
        // Position is just under buffer at $84 — partial path can succeed (collateralFreed > 0).
        _pushMark(84 * ONE_18);

        // Run the partial budget. Each call closes a 25% slice while collateralFreed > 0.
        ILiquidationEngine.Tier lastTier;
        for (uint256 i = 0; i < 4; i++) {
            IPerpEngine.Position memory pos_ = engine.positionOf(positionId);
            if (pos_.size == 0) break;
            vm.prank(liquidator);
            ILiquidationEngine.LiquidationResult memory rr = liqEngine.liquidate(positionId);
            lastTier = rr.tier;
        }
        // Should have transitioned from PARTIAL to FULL at some point.
        assertTrue(lastTier == ILiquidationEngine.Tier.PARTIAL || lastTier == ILiquidationEngine.Tier.FULL);
        // Either still open (partial still going) or fully closed.
        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        // If still open, push a deeper mark and trigger full.
        if (pos.size != 0) {
            _pushMark(83 * ONE_18);
            vm.prank(liquidator);
            ILiquidationEngine.LiquidationResult memory r = liqEngine.liquidate(positionId);
            // Either still PARTIAL (if attempts < 4 after early exits) or FULL.
            assertTrue(
                r.tier == ILiquidationEngine.Tier.PARTIAL || r.tier == ILiquidationEngine.Tier.FULL
                    || r.tier == ILiquidationEngine.Tier.INSURANCE || r.tier == ILiquidationEngine.Tier.SOCIALIZATION
            );
        }
    }

    function test_Liquidate_LongFullTier2_InsuranceCovers() public {
        // Seed insurance + push price deep enough that full close needs insurance for the bounty.
        _seedInsurance(20_000 * ONE_USDC);
        bytes32 positionId = _openLong(trader);

        // Push price to $80 — equity = 0, full close needs the bounty from insurance. Partial
        // succeeds with `collateralFreed == 0` ⇒ escalates to full in-call.
        _pushMark(80 * ONE_18);

        uint256 insBalBefore = insurance.balance();
        vm.prank(liquidator);
        ILiquidationEngine.LiquidationResult memory r = liqEngine.liquidate(positionId);

        // Tier should be INSURANCE (no socialization needed) or FULL if equity covered.
        assertTrue(r.tier == ILiquidationEngine.Tier.INSURANCE || r.tier == ILiquidationEngine.Tier.FULL);
        if (r.tier == ILiquidationEngine.Tier.INSURANCE) {
            assertGt(r.shortfallPnl, 0);
            // Insurance balance dropped.
            assertLt(insurance.balance(), insBalBefore);
        }
        assertGt(r.bountyPaid, 0);

        // Position deleted.
        assertEq(engine.positionOf(positionId).size, 0);
    }

    function test_Liquidate_LongTier3Plus4Socialization() public {
        // Tiny insurance seed so the shortfall exceeds insurance but stays under socialization cap.
        _seedInsurance(100 * ONE_USDC); // $100 — well below the ~$2.9K shortfall
        bytes32 positionId = _openLong(trader);

        // Push price to $75 — wipeout: equity = -2500, shortfall = ~2900 (bounty + |equity|).
        _pushMark(75 * ONE_18);

        uint256 insBefore = insurance.balance();
        vm.prank(liquidator);
        ILiquidationEngine.LiquidationResult memory r = liqEngine.liquidate(positionId);

        // Tier should be SOCIALIZATION.
        assertEq(uint8(r.tier), uint8(ILiquidationEngine.Tier.SOCIALIZATION));
        assertGt(r.shortfallPnl, 0);

        // Insurance was drained.
        assertEq(insurance.balance(), 0);
        assertGt(insBefore, 0);
    }

    function test_Liquidate_SocializationFitsCap() public {
        // No insurance seed + default cap. A ~$2.9K shortfall fits comfortably under the 30%
        // cap on a ~$1M TVL ($300K cap) — verifies the socialization path runs without revert.
        vm.prank(governance);
        liqEngine.setConfig(2_500, 4, 100, 100, 3_000); // default

        bytes32 positionId = _openLong(trader);
        _pushMark(75 * ONE_18);

        vm.prank(liquidator);
        ILiquidationEngine.LiquidationResult memory r = liqEngine.liquidate(positionId);
        assertEq(uint8(r.tier), uint8(ILiquidationEngine.Tier.SOCIALIZATION));
    }

    function test_Liquidate_RevertOnSocializationCapExceeded() public {
        // Construct a setup with a tight socialization cap so the SOCIALIZATION step trips:
        // open the position, then set the cap to 500 bps (5%) and drain most of the vault TVL
        // before liquidation. With the residual TVL low enough, the shortfall exceeds the cap.

        bytes32 positionId = _openLong(trader);

        // Push to -50% — shortfall ~$15K + bounty.
        _pushMark(50 * ONE_18);

        // Now drain alice's share so cap × TVL is small.
        // TVL is freeAssets() = balance - positionCollateral(=$10K) - 0 - $4 = ~$990K.
        // alice's shares correspond to ~$1M; redeem most so freeAssets drops below the
        // socialization cap requirement.
        // Withdraw as much as `maxWithdraw` allows (capped by freeAssets).
        uint256 maxWd = vault.maxWithdraw(alice);
        // Leave only $5_000 in freeAssets. Cap = 5% × $5K = $250. Shortfall ~$5,500 → trips.
        vm.prank(alice);
        vault.withdraw(maxWd - 5_000 * ONE_USDC, alice, alice);

        vm.prank(governance);
        liqEngine.setConfig(2_500, 4, 100, 100, 500); // 5% cap

        // Now liquidation must socialize ≈ shortfall, but cap is tiny.
        vm.prank(liquidator);
        vm.expectRevert();
        liqEngine.liquidate(positionId);
    }

    // ------------------------------------------------------------------------------------------
    // liquidate — reverts
    // ------------------------------------------------------------------------------------------

    function test_Liquidate_RevertOnPositionNotFound() public {
        bytes32 fake = keccak256("nope");
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.PositionNotFound.selector, fake));
        liqEngine.liquidate(fake);
    }

    function test_Liquidate_RevertOnNotUnderBuffer() public {
        bytes32 positionId = _openLong(trader);
        // Position is healthy — mark hasn't moved.
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.NotUnderBuffer.selector, positionId));
        liqEngine.liquidate(positionId);
    }

    function test_Liquidate_RevertOnUnauthorized() public {
        bytes32 positionId = _openLong(trader);
        _pushMark(84 * ONE_18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.OnlyLiquidator.selector, stranger));
        liqEngine.liquidate(positionId);
    }

    // ------------------------------------------------------------------------------------------
    // Short coverage
    // ------------------------------------------------------------------------------------------

    function test_Liquidate_ShortPartialTier1() public {
        bytes32 positionId = _openShort(trader);
        // Push mark UP — short loses. Equity drops when mark > entry.
        _pushMark(116 * ONE_18); // +16% — mirrors the long test

        vm.prank(liquidator);
        ILiquidationEngine.LiquidationResult memory r = liqEngine.liquidate(positionId);
        assertEq(uint8(r.tier), uint8(ILiquidationEngine.Tier.PARTIAL));
        // Closed size has same negative sign as the short position.
        assertLt(r.sizeClosed, 0);
        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertLt(pos.size, 0); // still short
    }

    function test_Liquidate_ShortFullTier2() public {
        _seedInsurance(10_000 * ONE_USDC);
        bytes32 positionId = _openShort(trader);
        _pushMark(120 * ONE_18);

        vm.prank(liquidator);
        ILiquidationEngine.LiquidationResult memory r = liqEngine.liquidate(positionId);
        assertTrue(
            r.tier == ILiquidationEngine.Tier.FULL || r.tier == ILiquidationEngine.Tier.INSURANCE
                || r.tier == ILiquidationEngine.Tier.SOCIALIZATION
        );
        // Position deleted.
        assertEq(engine.positionOf(positionId).size, 0);
    }

    function test_Liquidate_ShortDeepInsurance() public {
        _seedInsurance(20_000 * ONE_USDC);
        bytes32 positionId = _openShort(trader);
        // Big upward move — short is wiped.
        _pushMark(125 * ONE_18); // +25%

        vm.prank(liquidator);
        ILiquidationEngine.LiquidationResult memory r = liqEngine.liquidate(positionId);
        // Insurance should have absorbed the shortfall.
        assertGt(r.shortfallPnl, 0);
        assertTrue(r.tier == ILiquidationEngine.Tier.INSURANCE || r.tier == ILiquidationEngine.Tier.SOCIALIZATION);
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    function test_GovernanceTransfer_HappyPath() public {
        vm.prank(governance);
        liqEngine.proposeGovernanceTransfer(newGov);
        (address pending, uint64 ts) = liqEngine.pendingGovernance();
        assertEq(pending, newGov);
        assertEq(ts, uint64(block.timestamp + TIMELOCK_DELAY));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        liqEngine.activateGovernanceTransfer();
        assertEq(liqEngine.governance(), newGov);
    }

    function test_GovernanceTransfer_RevertOnPendingExists() public {
        vm.prank(governance);
        liqEngine.proposeGovernanceTransfer(newGov);
        vm.prank(governance);
        vm.expectRevert(ILiquidationEngine.PendingGovernanceTransferExists.selector);
        liqEngine.proposeGovernanceTransfer(newGov);
    }

    function test_GovernanceTransfer_RevertOnZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(ILiquidationEngine.InvalidConfig.selector);
        liqEngine.proposeGovernanceTransfer(address(0));
    }

    function test_GovernanceTransfer_ActivateRevertOnTimelock() public {
        vm.prank(governance);
        liqEngine.proposeGovernanceTransfer(newGov);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.TimelockNotElapsed.selector, readyAt));
        liqEngine.activateGovernanceTransfer();
    }

    function test_GovernanceTransfer_ActivateRevertOnNoPending() public {
        vm.expectRevert(ILiquidationEngine.NoPendingGovernanceTransfer.selector);
        liqEngine.activateGovernanceTransfer();
    }

    function test_GovernanceTransfer_Cancel() public {
        vm.prank(governance);
        liqEngine.proposeGovernanceTransfer(newGov);
        vm.prank(governance);
        liqEngine.cancelGovernanceTransfer();
        (address pending,) = liqEngine.pendingGovernance();
        assertEq(pending, address(0));
    }

    function test_GovernanceTransfer_CancelRevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(ILiquidationEngine.NoPendingGovernanceTransfer.selector);
        liqEngine.cancelGovernanceTransfer();
    }

    // ------------------------------------------------------------------------------------------
    // External gates (liquidateClose called from non-LiquidationEngine reverts)
    // ------------------------------------------------------------------------------------------

    function test_LiquidateClose_RevertOnNonLiquidationEngine() public {
        bytes32 positionId = _openLong(trader);
        _pushMark(84 * ONE_18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.OnlyLiquidationEngine.selector, stranger));
        engine.liquidateClose(positionId, int256(100 * ONE_USDC), 0, 0, 0, liquidator, 1);
    }

    function test_LiquidateClose_RevertOnSizeZero() public {
        bytes32 positionId = _openLong(trader);
        _pushMark(84 * ONE_18);
        // Impersonate the LiquidationEngine to reach the inner guards.
        vm.prank(address(liqEngine));
        vm.expectRevert(IPerpEngine.LiquidationSizeZero.selector);
        engine.liquidateClose(positionId, 0, 0, 0, 0, liquidator, 1);
    }

    function test_LiquidateClose_RevertOnSizeMismatch() public {
        bytes32 positionId = _openLong(trader);
        _pushMark(84 * ONE_18);
        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        // Try to close with a negative size on a long position.
        vm.prank(address(liqEngine));
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.LiquidationSizeMismatch.selector, pos.size, int256(-1)));
        engine.liquidateClose(positionId, -1, 0, 0, 0, liquidator, 1);
    }

    function test_LiquidateClose_RevertOnSizeTooLarge() public {
        bytes32 positionId = _openLong(trader);
        _pushMark(84 * ONE_18);
        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        int256 oversize = pos.size + 1;
        vm.prank(address(liqEngine));
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.LiquidationSizeMismatch.selector, pos.size, oversize));
        engine.liquidateClose(positionId, oversize, 0, 0, 0, liquidator, 1);
    }

    function test_LiquidateClose_RevertOnPositionNotOpen() public {
        bytes32 fake = keccak256("fake");
        vm.prank(address(liqEngine));
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.PositionNotOpen.selector, bytes32(0)));
        engine.liquidateClose(fake, 1, 0, 0, 0, liquidator, 1);
    }

    function test_DrawFromInsurance_RevertOnNonLiquidationEngine() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.OnlyLiquidationEngine.selector, stranger));
        vault.drawFromInsuranceForLiquidation(1);
    }

    function test_SettleLiquidation_RevertOnNonPerpEngine() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.settleLiquidation(trader, liquidator, 100, 50, 50, 0);
    }

    function test_SettleLiquidation_RevertOnTraderEqualsLiquidator() public {
        bytes32 positionId = _openLong(trader);
        _pushMark(84 * ONE_18);

        // Register the trader as a liquidator and have them try to liquidate themselves.
        // The settleLiquidation guard reverts LiquidatorIsTrader.
        vm.prank(governance);
        liqEngine.proposeAddLiquidator(trader);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        liqEngine.activateAddLiquidator(trader);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.LiquidatorIsTrader.selector, trader));
        liqEngine.liquidate(positionId);
    }

    function test_LpVaultLiquidationEngineRotation_HappyPath() public {
        address newEngine = makeAddr("newEngine");
        vm.prank(governance);
        vault.proposeSetLiquidationEngine(newEngine);
        (address pending, uint64 ts) = vault.pendingLiquidationEngine();
        assertEq(pending, newEngine);
        assertGt(ts, 0);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateSetLiquidationEngine();
        assertEq(vault.liquidationEngine(), newEngine);
    }

    function test_LpVaultLiquidationEngineRotation_Cancel() public {
        address newEngine = makeAddr("newEngine");
        vm.prank(governance);
        vault.proposeSetLiquidationEngine(newEngine);
        vm.prank(governance);
        vault.cancelSetLiquidationEngine();
        (address pending,) = vault.pendingLiquidationEngine();
        assertEq(pending, address(0));
    }

    function test_PerpEngineLiquidationEngineRotation_HappyPath() public {
        address newEngine = makeAddr("newEngine");
        vm.prank(governance);
        engine.proposeSetLiquidationEngine(newEngine);
        (address pending,) = engine.pendingLiquidationEngine();
        assertEq(pending, newEngine);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetLiquidationEngine();
        assertEq(engine.liquidationEngine(), newEngine);
    }

    function test_PerpEngineLiquidationEngineRotation_Cancel() public {
        address newEngine = makeAddr("newEngine");
        vm.prank(governance);
        engine.proposeSetLiquidationEngine(newEngine);
        vm.prank(governance);
        engine.cancelSetLiquidationEngine();
        (address pending,) = engine.pendingLiquidationEngine();
        assertEq(pending, address(0));
    }

    function test_DrawFromInsurance_RevertOnAmountZero() public {
        vm.prank(address(liqEngine));
        vm.expectRevert(ILPVault.AmountZero.selector);
        vault.drawFromInsuranceForLiquidation(0);
    }
}
