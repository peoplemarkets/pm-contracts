// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {ILiquidationEngine} from "../src/core/ILiquidationEngine.sol";
import {IPerpEngine} from "../src/core/IPerpEngine.sol";
import {InsuranceFund} from "../src/core/InsuranceFund.sol";
import {LPVault} from "../src/core/LPVault.sol";
import {LiquidationEngine} from "../src/core/LiquidationEngine.sol";
import {MarginEngine} from "../src/core/MarginEngine.sol";
import {PerpEngine} from "../src/core/PerpEngine.sol";
import {SubjectRegistry} from "../src/registry/SubjectRegistry.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title  Tier-5 ADL (auto-deleveraging) integration tests.
/// @notice Drives a position bankrupt past the socialization cap and offloads its size onto a
///         profitable opposite-side counterparty, force-closed at the bankruptcy price.
contract LiquidationADLTest is Test {
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

    address internal alice = makeAddr("alice"); // LP
    address internal badTrader = makeAddr("badTrader");
    address internal cpTrader = makeAddr("cpTrader");

    bytes32 internal constant SUBJECT_ID = keccak256("drake");
    bytes32 internal constant CATEGORY_ID = keccak256("musician");

    uint32 internal constant TIMELOCK_DELAY = 2 days;
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant ONE_18 = 1e18;
    uint256 internal constant INITIAL_MARK = 100 * ONE_18;
    uint256 internal constant LP_SEED = 2_000_000 * ONE_USDC; // $2M

    function setUp() public {
        vm.warp(2_000_000_000);
        usdc = new MockUSDC();

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
        {
            LPVault impl = new LPVault();
            bytes memory initData = abi.encodeCall(
                LPVault.initialize,
                (IERC20(address(usdc)), governance, vaultOperator, TIMELOCK_DELAY, "People Markets LP USDC", "pmUSDC")
            );
            vault = LPVault(address(new ERC1967Proxy(address(impl), initData)));
        }
        {
            PerpEngine impl = new PerpEngine();
            bytes memory initData =
                abi.encodeCall(PerpEngine.initialize, (governance, TIMELOCK_DELAY, address(registry), address(vault)));
            engine = PerpEngine(address(new ERC1967Proxy(address(impl), initData)));
        }
        {
            MarginEngine impl = new MarginEngine();
            bytes memory initData =
                abi.encodeCall(MarginEngine.initialize, (governance, address(engine), TIMELOCK_DELAY));
            marginEngine = MarginEngine(address(new ERC1967Proxy(address(impl), initData)));
        }
        {
            InsuranceFund impl = new InsuranceFund();
            bytes memory initData = abi.encodeCall(
                InsuranceFund.initialize, (insGovernance, address(vault), IERC20(address(usdc)), TIMELOCK_DELAY)
            );
            insurance = InsuranceFund(address(new ERC1967Proxy(address(impl), initData)));
        }
        vm.startPrank(governance);
        vault.migrateInsuranceFund(address(insurance));
        vault.approveInsuranceFund();
        vm.stopPrank();
        {
            LiquidationEngine impl = new LiquidationEngine();
            bytes memory initData = abi.encodeCall(
                LiquidationEngine.initialize,
                (governance, address(engine), address(marginEngine), address(vault), address(insurance), TIMELOCK_DELAY)
            );
            liqEngine = LiquidationEngine(address(new ERC1967Proxy(address(impl), initData)));
        }

        _activate(
            address(vault),
            abi.encodeCall(LPVault.proposeSetPerpEngine, (address(engine))),
            abi.encodeCall(LPVault.activateSetPerpEngine, ())
        );
        _activate(
            address(engine),
            abi.encodeCall(PerpEngine.proposeSetMarginEngine, (address(marginEngine))),
            abi.encodeCall(PerpEngine.activateSetMarginEngine, ())
        );
        _activate(
            address(engine),
            abi.encodeCall(PerpEngine.proposeSetLiquidationEngine, (address(liqEngine))),
            abi.encodeCall(PerpEngine.activateSetLiquidationEngine, ())
        );
        _activate(
            address(vault),
            abi.encodeCall(LPVault.proposeSetLiquidationEngine, (address(liqEngine))),
            abi.encodeCall(LPVault.activateSetLiquidationEngine, ())
        );

        vm.prank(governance);
        liqEngine.proposeAddLiquidator(liquidator);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        liqEngine.activateAddLiquidator(liquidator);

        vm.prank(regAdmin);
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);
        vm.startPrank(kycWriter);
        registry.setKycTier(badTrader, 3);
        registry.setKycTier(cpTrader, 3);
        vm.stopPrank();

        vm.startPrank(governance);
        marginEngine.setKycCaps(3, 1_000_000 * ONE_USDC, 4_000_000 * ONE_USDC);
        marginEngine.setPerSubjectSideOiCapBps(5_000); // 50% of TVL
        marginEngine.setCategoryNetOiCapBps(5_000); // 50% of TVL
        engine.setMarkMaxDeltaBps(5_000);
        // Tighten the LP socialization cap to its minimum (5%) so a single large bankrupt position
        // is enough to require Tier 5 instead of being absorbable by socialization.
        liqEngine.setConfig(2_500, 4, 100, 100, 500);
        engine.proposeAddMarkWriter(markWriter);
        vm.stopPrank();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateAddMarkWriter(markWriter);

        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, INITIAL_MARK);

        usdc.mint(alice, 20_000_000 * ONE_USDC);
        usdc.mint(badTrader, 5_000_000 * ONE_USDC);
        usdc.mint(cpTrader, 5_000_000 * ONE_USDC);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(badTrader);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(cpTrader);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(alice);
        vault.deposit(LP_SEED, alice);
        engine.pokeCappedTvl();
    }

    function _activate(address target, bytes memory proposeCall, bytes memory activateCall) internal {
        vm.prank(governance);
        (bool ok,) = target.call(proposeCall);
        require(ok, "propose failed");
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        (ok,) = target.call(activateCall);
        require(ok, "activate failed");
    }

    function _open(address t, IPerpEngine.Side side, uint256 collateral, uint256 notional) internal returns (bytes32) {
        IPerpEngine.OpenParams memory p = IPerpEngine.OpenParams({
            subjectId: SUBJECT_ID,
            side: side,
            collateralAmount: collateral,
            sizeNotional: notional,
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

    /// @dev Crash the mark to $20 in ≤50%-per-push steps.
    function _crashTo20() internal {
        _pushMark(50 * ONE_18);
        _pushMark(25 * ONE_18);
        _pushMark(20 * ONE_18);
    }

    // ------------------------------------------------------------------------------------------
    // Happy path: bankrupt long offloaded onto an exactly-matched profitable short
    // ------------------------------------------------------------------------------------------

    function test_Adl_HappyPath_OffloadsOntoMatchedShort() public {
        // Bad long: $400K notional, $100K collateral (4×) ⇒ size +4000e6, P_b = $75.
        bytes32 badId = _open(badTrader, IPerpEngine.Side.LONG, 100_000 * ONE_USDC, 400_000 * ONE_USDC);
        // Counterparty short: same size, $100K collateral ⇒ size -4000e6.
        bytes32 cpId = _open(cpTrader, IPerpEngine.Side.SHORT, 100_000 * ONE_USDC, 400_000 * ONE_USDC);

        _crashTo20();

        uint256 cpBalBefore = usdc.balanceOf(cpTrader);

        bytes32[] memory cps = new bytes32[](1);
        cps[0] = cpId;
        vm.prank(liquidator);
        ILiquidationEngine.LiquidationResult memory r = liqEngine.adl(badId, cps);

        assertEq(uint8(r.tier), uint8(ILiquidationEngine.Tier.ADL));
        assertEq(r.sizeClosed, int256(4000e6));

        // Bad long wiped.
        assertEq(engine.positionOf(badId).size, 0);
        // Counterparty fully closed (exact match).
        assertEq(engine.positionOf(cpId).size, 0);

        // Short closed at P_b = $75: pnl = -4000e6 × (75-100) = +100_000e6; payout = collateral +
        // pnl = $100K + $100K = $200K (vs the $400K it would have received at the $20 mark — it
        // gives up exactly the bad long's $220K-ish shortfall via the price gap).
        assertEq(usdc.balanceOf(cpTrader) - cpBalBefore, 200_000 * ONE_USDC);
    }

    /// @dev Partial counterparty: short larger than the bad long is closed only up to the matched
    ///      size, leaving a residual position.
    function test_Adl_PartialCounterpartyMatch() public {
        bytes32 badId = _open(badTrader, IPerpEngine.Side.LONG, 100_000 * ONE_USDC, 400_000 * ONE_USDC); // size 4000e6
        // Short $600K / $150K collateral ⇒ size -6000e6.
        bytes32 cpId = _open(cpTrader, IPerpEngine.Side.SHORT, 150_000 * ONE_USDC, 600_000 * ONE_USDC);

        _crashTo20();

        bytes32[] memory cps = new bytes32[](1);
        cps[0] = cpId;
        vm.prank(liquidator);
        liqEngine.adl(badId, cps);

        assertEq(engine.positionOf(badId).size, 0);
        // 4000e6 of the 6000e6 short closed ⇒ residual -2000e6 with prorated collateral $50K.
        IPerpEngine.Position memory cp = engine.positionOf(cpId);
        assertEq(cp.size, -int256(2000e6));
        assertEq(cp.collateral, 50_000 * ONE_USDC);
    }

    // ------------------------------------------------------------------------------------------
    // Reverts
    // ------------------------------------------------------------------------------------------

    /// @dev With the default 30% socialization cap, the shortfall is absorbable ⇒ ADL not allowed.
    function test_Adl_RevertWhenNotRequired() public {
        vm.prank(governance);
        liqEngine.setConfig(2_500, 4, 100, 100, 3_000); // back to 30% cap

        bytes32 badId = _open(badTrader, IPerpEngine.Side.LONG, 100_000 * ONE_USDC, 400_000 * ONE_USDC);
        bytes32 cpId = _open(cpTrader, IPerpEngine.Side.SHORT, 100_000 * ONE_USDC, 400_000 * ONE_USDC);
        _crashTo20();

        bytes32[] memory cps = new bytes32[](1);
        cps[0] = cpId;
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.ADLNotRequired.selector, badId));
        liqEngine.adl(badId, cps);
    }

    /// @dev Counterparties too small to fully offset the bad position's size.
    function test_Adl_RevertOnInsufficientCounterpartySize() public {
        bytes32 badId = _open(badTrader, IPerpEngine.Side.LONG, 100_000 * ONE_USDC, 400_000 * ONE_USDC); // 4000e6
        // Short only $200K ⇒ size -2000e6 < 4000e6.
        bytes32 cpId = _open(cpTrader, IPerpEngine.Side.SHORT, 50_000 * ONE_USDC, 200_000 * ONE_USDC);
        _crashTo20();

        bytes32[] memory cps = new bytes32[](1);
        cps[0] = cpId;
        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidationEngine.ADLInsufficientCounterpartySize.selector, uint256(2000e6))
        );
        liqEngine.adl(badId, cps);
    }

    /// @dev A same-side (also long) counterparty is ineligible.
    function test_Adl_RevertOnWrongSideCounterparty() public {
        bytes32 badId = _open(badTrader, IPerpEngine.Side.LONG, 100_000 * ONE_USDC, 400_000 * ONE_USDC);
        bytes32 cpId = _open(cpTrader, IPerpEngine.Side.LONG, 100_000 * ONE_USDC, 400_000 * ONE_USDC);
        _crashTo20();

        bytes32[] memory cps = new bytes32[](1);
        cps[0] = cpId;
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.ADLCounterpartyNotEligible.selector, cpId));
        liqEngine.adl(badId, cps);
    }

    /// @dev A healthy (not-under-buffer) bad position cannot be ADL'd.
    function test_Adl_RevertOnNotUnderBuffer() public {
        bytes32 badId = _open(badTrader, IPerpEngine.Side.LONG, 100_000 * ONE_USDC, 400_000 * ONE_USDC);
        bytes32 cpId = _open(cpTrader, IPerpEngine.Side.SHORT, 100_000 * ONE_USDC, 400_000 * ONE_USDC);
        // No crash ⇒ long is healthy.
        bytes32[] memory cps = new bytes32[](1);
        cps[0] = cpId;
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.NotUnderBuffer.selector, badId));
        liqEngine.adl(badId, cps);
    }

    /// @dev Only registered liquidators may call ADL.
    function test_Adl_RevertOnNonLiquidator() public {
        bytes32 badId = _open(badTrader, IPerpEngine.Side.LONG, 100_000 * ONE_USDC, 400_000 * ONE_USDC);
        bytes32 cpId = _open(cpTrader, IPerpEngine.Side.SHORT, 100_000 * ONE_USDC, 400_000 * ONE_USDC);
        _crashTo20();
        bytes32[] memory cps = new bytes32[](1);
        cps[0] = cpId;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.OnlyLiquidator.selector, alice));
        liqEngine.adl(badId, cps);
    }
}
