// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {ILPVault} from "../../src/core/ILPVault.sol";
import {IPerpEngine} from "../../src/core/IPerpEngine.sol";
import {LPVault} from "../../src/core/LPVault.sol";
import {MarginEngine} from "../../src/core/MarginEngine.sol";
import {PerpEngine} from "../../src/core/PerpEngine.sol";

import {ISubjectRegistry} from "../../src/registry/ISubjectRegistry.sol";
import {SubjectRegistry} from "../../src/registry/SubjectRegistry.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @title PerpVaultE2E — full cross-contract scenario.
/// @notice Walks the LP-deposit → trader-open → mark-move → partial-close → registry-pause →
///         close-during-pause → unpause → full-close cycle through real (UUPS-proxied) contracts.
///         Sanity check on the wiring beyond the unit suites; verifies bookkeeper sum identity at
///         every checkpoint.
contract PerpVaultE2ETest is Test {
    PerpEngine internal engine;
    MarginEngine internal marginEngine;
    LPVault internal vault;
    SubjectRegistry internal registry;
    MockUSDC internal usdc;

    address internal governance = makeAddr("governance");
    address internal vaultOperator = makeAddr("vaultOperator");
    address internal regAdmin = makeAddr("regAdmin");
    address internal regGuardian = makeAddr("regGuardian");
    address internal kycWriter = makeAddr("kycWriter");
    address internal markWriter = makeAddr("markWriter");

    address internal alice = makeAddr("alice"); // LP
    address internal trader = makeAddr("trader");

    bytes32 internal constant SUBJECT_ID = keccak256("drake");
    bytes32 internal constant CATEGORY_ID = keccak256("musician");

    uint32 internal constant TIMELOCK_DELAY = 2 days;
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant USDC_1M = 1_000_000 * ONE_USDC;
    uint256 internal constant USDC_10M = 10 * USDC_1M;
    uint256 internal constant ONE_18 = 1e18;
    uint256 internal constant INITIAL_MARK = 100 * ONE_18;

    function setUp() public {
        vm.warp(2_000_000_000);
        usdc = new MockUSDC();

        // SubjectRegistry behind UUPS
        SubjectRegistry regImpl = new SubjectRegistry();
        address[] memory admins = new address[](1);
        admins[0] = regAdmin;
        address[] memory guardians = new address[](1);
        guardians[0] = regGuardian;
        address[] memory writers = new address[](1);
        writers[0] = kycWriter;
        registry = SubjectRegistry(
            address(
                new ERC1967Proxy(
                    address(regImpl),
                    abi.encodeCall(SubjectRegistry.initialize, (governance, TIMELOCK_DELAY, admins, guardians, writers))
                )
            )
        );

        // LPVault behind UUPS
        LPVault vaultImpl = new LPVault();
        vault = LPVault(
            address(
                new ERC1967Proxy(
                    address(vaultImpl),
                    abi.encodeCall(
                        LPVault.initialize,
                        (
                            IERC20(address(usdc)),
                            governance,
                            vaultOperator,
                            TIMELOCK_DELAY,
                            "People Markets LP USDC",
                            "pmUSDC"
                        )
                    )
                )
            )
        );

        // PerpEngine behind UUPS
        PerpEngine engineImpl = new PerpEngine();
        engine = PerpEngine(
            address(
                new ERC1967Proxy(
                    address(engineImpl),
                    abi.encodeCall(
                        PerpEngine.initialize, (governance, TIMELOCK_DELAY, address(registry), address(vault))
                    )
                )
            )
        );

        // Wire vault.setPerpEngine via timelock
        vm.prank(governance);
        vault.proposeSetPerpEngine(address(engine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateSetPerpEngine();

        // Wave 4: MarginEngine + wiring (timelocked).
        {
            MarginEngine impl = new MarginEngine();
            bytes memory initData =
                abi.encodeCall(MarginEngine.initialize, (governance, address(engine), TIMELOCK_DELAY));
            marginEngine = MarginEngine(address(new ERC1967Proxy(address(impl), initData)));
        }
        vm.prank(governance);
        engine.proposeSetMarginEngine(address(marginEngine));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateSetMarginEngine();

        // Configure registry: list subject + KYC tier
        vm.prank(regAdmin);
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);
        vm.prank(kycWriter);
        registry.setKycTier(trader, 2); // T2

        // KYC caps live on MarginEngine; mark writer stays on PerpEngine.
        vm.prank(governance);
        marginEngine.setKycCaps(2, 250_000 * ONE_USDC, 1_000_000 * ONE_USDC);
        vm.prank(governance);
        engine.proposeAddMarkWriter(markWriter);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        engine.activateAddMarkWriter(markWriter);

        // Initial mark
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, INITIAL_MARK);

        // Fund + approve
        usdc.mint(alice, USDC_10M);
        usdc.mint(trader, USDC_1M);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Verifies the bookkeeper-sum identity after each step. Used as the cross-checkpoint.
    function _assertBookkeeperIdentity() internal view {
        assertEq(
            usdc.balanceOf(address(vault)),
            vault.freeAssets() + vault.positionCollateral() + vault.insuranceFundBalance() + vault.accruedFees(),
            "I1: bookkeeper-sum identity broken"
        );
    }

    function test_E2E_FullScenario() public {
        // Step 1 — Governance seeds insurance fund per spec §3 line 159.
        usdc.mint(governance, 1_000_000 * ONE_USDC);
        vm.prank(governance);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(governance);
        vault.seedInsurance(1_000_000 * ONE_USDC);
        assertEq(vault.insuranceFundBalance(), 1_000_000 * ONE_USDC);
        _assertBookkeeperIdentity();

        // Step 2 — Alice deposits $5M LP capital. Poke the OI cap snapshot (v2-audit Fix #3).
        vm.prank(alice);
        uint256 sharesAlice = vault.deposit(5_000_000 * ONE_USDC, alice);
        assertGt(sharesAlice, 0);
        assertEq(vault.freeAssets(), 5_000_000 * ONE_USDC);
        engine.pokeCappedTvl();
        _assertBookkeeperIdentity();

        // Step 3 — Trader opens a $50K notional long at 5× leverage.
        IPerpEngine.OpenParams memory openParams = IPerpEngine.OpenParams({
            subjectId: SUBJECT_ID,
            side: IPerpEngine.Side.LONG,
            collateralAmount: 10_000 * ONE_USDC,
            sizeNotional: 50_000 * ONE_USDC,
            expectedMark: INITIAL_MARK,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
        vm.prank(trader);
        bytes32 positionId = engine.openPosition(openParams);
        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        assertGt(pos.size, 0); // long
        assertEq(pos.collateral, 10_000 * ONE_USDC);
        assertEq(vault.positionCollateral(), 10_000 * ONE_USDC);
        _assertBookkeeperIdentity();

        // Step 4 — Mark moves +5%. Engine equity should grow.
        vm.warp(block.timestamp + 10);
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, 105 * ONE_18);
        int256 equityMid = engine.equityOf(positionId);
        assertGt(equityMid, int256(10_000 * ONE_USDC));

        // Step 5 — Trader partially closes 50%. Realizes ~$1.25K profit.
        IPerpEngine.CloseParams memory partialClose = IPerpEngine.CloseParams({
            subjectId: SUBJECT_ID,
            sizeFractionBps: 5_000,
            expectedMark: 105 * ONE_18,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
        uint256 traderBeforeStep5 = usdc.balanceOf(trader);
        vm.prank(trader);
        int256 partialPnl = engine.closePosition(partialClose);
        assertGt(partialPnl, 0);
        assertGt(usdc.balanceOf(trader), traderBeforeStep5);
        IPerpEngine.Position memory posAfter5 = engine.positionOf(positionId);
        assertEq(posAfter5.collateral, 5_000 * ONE_USDC); // halved
        _assertBookkeeperIdentity();

        // Step 6 — Registry guardian auto-pauses the subject (5%/30s circuit breaker simulated).
        vm.warp(block.timestamp + 5);
        vm.prank(regGuardian);
        registry.setAutoPaused(SUBJECT_ID, 1);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.AUTO_PAUSED));

        // Step 7 — Trader CAN still close during pause (spec §6 wind-down).
        // Refresh mark first since it's about to go stale (more than 30s since last push potentially).
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, 105 * ONE_18);
        IPerpEngine.CloseParams memory tinyClose = partialClose;
        tinyClose.sizeFractionBps = 1_000; // 10% of remainder
        tinyClose.deadline = uint64(block.timestamp + 1 hours);
        vm.prank(trader);
        engine.closePosition(tinyClose);
        _assertBookkeeperIdentity();

        // Step 8 — New opens are blocked while paused.
        IPerpEngine.OpenParams memory openParamsBlocked = openParams;
        openParamsBlocked.deadline = uint64(block.timestamp + 1 hours);
        vm.prank(trader);
        vm.expectRevert(); // requireTradeable rejects AUTO_PAUSED
        engine.openPosition(openParamsBlocked);

        // Step 9 — Auto-pause expires; permissionless unpause cycles back to ACTIVE.
        vm.warp(block.timestamp + 31);
        vm.prank(makeAddr("randomKeeper"));
        registry.unpauseAuto(SUBJECT_ID);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.ACTIVE));

        // Step 10 — Trader fully closes the remainder; position is deleted.
        vm.prank(markWriter);
        engine.pushMark(SUBJECT_ID, 105 * ONE_18); // freshen
        IPerpEngine.CloseParams memory fullClose = partialClose;
        fullClose.sizeFractionBps = 10_000;
        fullClose.deadline = uint64(block.timestamp + 1 hours);
        vm.prank(trader);
        engine.closePosition(fullClose);

        assertEq(engine.positionIdOf(trader, SUBJECT_ID), bytes32(0));
        (uint256 longOI, uint256 shortOI) = engine.openInterestOf(SUBJECT_ID);
        assertEq(longOI, 0);
        assertEq(shortOI, 0);
        _assertBookkeeperIdentity();

        // Final check: vault NAV moved (LPs paid out trader's profit, kept LP rebate).
        // Trader is in profit overall (+5% mark move), so vault freeAssets should be slightly
        // below the initial $5M deposit (trader took some profit) but above the deposit minus
        // the gross profit (LP rebate stayed in the pool).
        assertLt(vault.freeAssets(), 5_000_000 * ONE_USDC);
        assertGt(vault.freeAssets(), 4_990_000 * ONE_USDC);
    }

    /// @dev Forced-settlement flow: subject delisted, governance captures mark, trader claims.
    function test_E2E_ForcedSettlement_Path() public {
        // Setup: trader has an open position.
        vm.prank(alice);
        vault.deposit(5_000_000 * ONE_USDC, alice);
        engine.pokeCappedTvl();
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
        vm.prank(trader);
        engine.openPosition(p);

        // Subject is involuntarily delisted (legal action).
        vm.prank(regAdmin);
        registry.involuntaryDelist(SUBJECT_ID);

        // Governance captures the pre-news fair mark. (In production this would be agreed off-chain;
        // here we use the live mark for testing.)
        vm.prank(governance);
        engine.forceSettleSubject(SUBJECT_ID, INITIAL_MARK);

        // Trader can no longer use the regular close path.
        IPerpEngine.CloseParams memory cp = IPerpEngine.CloseParams({
            subjectId: SUBJECT_ID,
            sizeFractionBps: 10_000,
            expectedMark: INITIAL_MARK,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: false
        });
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IPerpEngine.SubjectIsForceSettled.selector, SUBJECT_ID));
        engine.closePosition(cp);

        // Trader claims at the captured mark; zero fee (venue obligation).
        uint256 traderBefore = usdc.balanceOf(trader);
        vm.prank(trader);
        engine.closeAtForcedSettlement(SUBJECT_ID);
        // Mark unchanged from entry → trader gets exactly collateral back, no fee
        assertEq(usdc.balanceOf(trader) - traderBefore, 10_000 * ONE_USDC);
        _assertBookkeeperIdentity();
    }
}
