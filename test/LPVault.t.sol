// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {ILPVault} from "../src/core/ILPVault.sol";
import {LPVault} from "../src/core/LPVault.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @dev Test-only harness exposing the internal `_withdraw` so we can prove the defensive
///      `freeAssets` check fires when the wrapper's max-cap is bypassed (regression scenario).
contract LPVaultDefenseHarness is LPVault {
    function exposeWithdraw(uint256 assets) external {
        _withdraw(msg.sender, msg.sender, msg.sender, assets, 0);
    }
}

contract LPVaultTest is Test {
    LPVault internal vault;
    MockUSDC internal usdc;

    address internal governance = makeAddr("governance");
    address internal operator = makeAddr("operator");
    address internal perpEngine = makeAddr("perpEngine"); // EOA stand-in
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");
    address internal trader = makeAddr("trader");
    address internal stranger = makeAddr("stranger");

    uint32 internal constant TIMELOCK_DELAY = 2 days;
    uint256 internal constant ONE_USDC = 1e6; // 6-decimal USDC
    uint256 internal constant USDC_1M = 1_000_000 * ONE_USDC;

    // ------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------

    function setUp() public {
        usdc = new MockUSDC();
        LPVault impl = new LPVault();
        bytes memory initData = abi.encodeCall(
            LPVault.initialize,
            (IERC20(address(usdc)), governance, operator, TIMELOCK_DELAY, "People Markets LP USDC", "pmUSDC")
        );
        vault = LPVault(address(new ERC1967Proxy(address(impl), initData)));

        // Wire the perpEngine address through the timelocked path so all setup paths get exercised.
        vm.prank(governance);
        vault.proposeSetPerpEngine(perpEngine);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateSetPerpEngine();

        // Fund actors with USDC and pre-approve the vault.
        usdc.mint(alice, 10 * USDC_1M);
        usdc.mint(bob, 10 * USDC_1M);
        usdc.mint(charlie, 10 * USDC_1M);
        usdc.mint(trader, 10 * USDC_1M);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(charlie);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------------------------------------
    // initialize
    // ------------------------------------------------------------------------------------------

    function test_Initialize_StoresParamsAndMetadata() public view {
        assertEq(vault.governance(), governance);
        assertEq(vault.operator(), operator);
        assertEq(vault.timelockDelay(), TIMELOCK_DELAY);
        assertEq(vault.perpEngine(), perpEngine);
        assertEq(vault.asset(), address(usdc));
        assertEq(vault.name(), "People Markets LP USDC");
        assertEq(vault.symbol(), "pmUSDC");
        // ERC-4626 share decimals = asset decimals + offset = 6 + 6 = 12
        assertEq(vault.decimals(), 12);
    }

    function test_Initialize_RevertOnZeroUsdc() public {
        LPVault impl = new LPVault();
        bytes memory initData =
            abi.encodeCall(LPVault.initialize, (IERC20(address(0)), governance, operator, TIMELOCK_DELAY, "x", "x"));
        vm.expectRevert(ILPVault.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroGovernance() public {
        LPVault impl = new LPVault();
        bytes memory initData =
            abi.encodeCall(LPVault.initialize, (IERC20(address(usdc)), address(0), operator, TIMELOCK_DELAY, "x", "x"));
        vm.expectRevert(ILPVault.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroOperator() public {
        LPVault impl = new LPVault();
        bytes memory initData = abi.encodeCall(
            LPVault.initialize, (IERC20(address(usdc)), governance, address(0), TIMELOCK_DELAY, "x", "x")
        );
        vm.expectRevert(ILPVault.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooShort() public {
        LPVault impl = new LPVault();
        bytes memory initData = abi.encodeCall(
            LPVault.initialize, (IERC20(address(usdc)), governance, operator, uint32(1 minutes), "x", "x")
        );
        vm.expectRevert(ILPVault.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooLong() public {
        LPVault impl = new LPVault();
        bytes memory initData =
            abi.encodeCall(LPVault.initialize, (IERC20(address(usdc)), governance, operator, uint32(60 days), "x", "x"));
        vm.expectRevert(ILPVault.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_DoubleInitReverts() public {
        vm.expectRevert();
        vault.initialize(IERC20(address(usdc)), governance, operator, TIMELOCK_DELAY, "x", "x");
    }

    // ------------------------------------------------------------------------------------------
    // ERC-4626 surface
    // ------------------------------------------------------------------------------------------

    function test_Deposit_HappyPath() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(USDC_1M, alice);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.freeAssets(), USDC_1M);
        assertEq(vault.totalAssets(), USDC_1M);
        assertEq(usdc.balanceOf(address(vault)), USDC_1M);
    }

    function test_Mint_HappyPath() public {
        uint256 sharesToMint = vault.previewDeposit(USDC_1M);
        vm.prank(alice);
        uint256 assetsIn = vault.mint(sharesToMint, alice);
        assertEq(assetsIn, USDC_1M);
        assertEq(vault.balanceOf(alice), sharesToMint);
    }

    function test_Withdraw_HappyPath() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(USDC_1M, alice);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 sharesBurned = vault.withdraw(USDC_1M / 2, alice, alice);
        assertGt(sharesBurned, 0);
        assertEq(usdc.balanceOf(alice) - balBefore, USDC_1M / 2);
        assertEq(vault.balanceOf(alice), shares - sharesBurned);
    }

    function test_Redeem_HappyPath() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(USDC_1M, alice);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertEq(assets, USDC_1M);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_Deposit_RevertOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ILPVault.AmountZero.selector);
        vault.deposit(0, alice);
    }

    function test_PreviewRoundtrips() public {
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);

        uint256 shares = vault.previewDeposit(100 * ONE_USDC);
        uint256 backToAssets = vault.previewRedeem(shares);
        // Rounding is at most a 1-wei loss.
        assertApproxEqAbs(backToAssets, 100 * ONE_USDC, 1);
    }

    function test_DepositWithMinShares_HappyPath() public {
        uint256 expected = vault.previewDeposit(USDC_1M);
        vm.prank(alice);
        uint256 shares = vault.depositWithMinShares(USDC_1M, alice, expected);
        assertEq(shares, expected);
    }

    function test_DepositWithMinShares_RevertOnSlippage() public {
        uint256 expected = vault.previewDeposit(USDC_1M);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.MinSharesNotMet.selector, expected + 1, expected));
        vault.depositWithMinShares(USDC_1M, alice, expected + 1);
    }

    function test_RedeemWithMinAssets_HappyPath() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(USDC_1M, alice);
        uint256 expected = vault.previewRedeem(shares);
        vm.prank(alice);
        uint256 assets = vault.redeemWithMinAssets(shares, alice, alice, expected);
        assertEq(assets, expected);
    }

    function test_RedeemWithMinAssets_RevertOnSlippage() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(USDC_1M, alice);
        uint256 expected = vault.previewRedeem(shares);
        if (expected == 0) return; // empty case
        vm.prank(alice);
        // User asks for at least expected + 1 assets per share. Realized = expected.
        // Reverts because realized < minAssets, protecting against share-price decline.
        vm.expectRevert(abi.encodeWithSelector(ILPVault.MinAssetsNotMet.selector, expected + 1, expected));
        vault.redeemWithMinAssets(shares, alice, alice, expected + 1);
    }

    // ------------------------------------------------------------------------------------------
    // Free-assets accounting
    // ------------------------------------------------------------------------------------------

    function test_FreeAssets_TracksBalanceMinusBookkeepers() public {
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);
        assertEq(vault.freeAssets(), USDC_1M);

        // perpEngine locks collateral on a trader's behalf. freeAssets should not change.
        vm.prank(perpEngine);
        vault.lockCollateral(trader, 100 * ONE_USDC);
        assertEq(vault.positionCollateral(), 100 * ONE_USDC);
        assertEq(vault.freeAssets(), USDC_1M);

        // Donation: anyone transfers USDC directly. freeAssets goes up by donation.
        usdc.mint(stranger, 5 * ONE_USDC);
        vm.prank(stranger);
        usdc.transfer(address(vault), 5 * ONE_USDC);
        assertEq(vault.freeAssets(), USDC_1M + 5 * ONE_USDC);
    }

    function test_FreeAssets_DonationBenefitsExistingHolders() public {
        vm.prank(alice);
        uint256 sharesAlice = vault.deposit(USDC_1M, alice);

        uint256 priceBefore = vault.previewRedeem(sharesAlice);

        // Stranger donates. Alice's redeem value should rise.
        usdc.mint(stranger, USDC_1M);
        vm.prank(stranger);
        usdc.transfer(address(vault), USDC_1M);

        uint256 priceAfter = vault.previewRedeem(sharesAlice);
        assertGt(priceAfter, priceBefore);
    }

    function test_InflationAttack_DefendedByDecimalsOffset() public {
        // Attacker deposits 1 wei, then donates a chunk; victim deposits; attacker redeems.
        // With the OZ virtual-shares offset of 6, the attacker should NOT come out ahead.
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        usdc.mint(attacker, USDC_1M);
        usdc.mint(victim, USDC_1M);
        vm.prank(attacker);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(victim);
        usdc.approve(address(vault), type(uint256).max);

        // 1 wei deposit
        vm.prank(attacker);
        uint256 attackerShares = vault.deposit(1, attacker);

        // Donate 1 USDC directly — try to inflate price
        vm.prank(attacker);
        usdc.transfer(address(vault), 1 * ONE_USDC);

        // Victim deposits 1 USDC
        vm.prank(victim);
        uint256 victimShares = vault.deposit(1 * ONE_USDC, victim);

        // Attacker redeems all their shares
        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(attackerShares, attacker, attacker);

        // Attacker spent: 1 wei + 1 USDC donation = 1_000_001 wei
        // Attacker got back: < 1_000_001 (the donation is shared with victim via offset math)
        uint256 attackerSpent = 1 + 1 * ONE_USDC;
        assertLt(attackerOut, attackerSpent);
        // Victim still got close to fair value (within rounding)
        vm.prank(victim);
        uint256 victimOut = vault.redeem(victimShares, victim, victim);
        // Victim should get at least 95% of their deposit back even after the inflation attempt.
        assertGt(victimOut, (1 * ONE_USDC * 95) / 100);
    }

    function test_LockCollateral_DoesNotMoveFreeAssets() public {
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);
        uint256 freeBefore = vault.freeAssets();
        vm.prank(perpEngine);
        vault.lockCollateral(trader, 100 * ONE_USDC);
        // trader paid in 100 USDC, vault books it as positionCollateral
        assertEq(vault.positionCollateral(), 100 * ONE_USDC);
        assertEq(vault.freeAssets(), freeBefore); // unchanged
    }

    function test_ReleaseCollateral_DoesNotMoveFreeAssets() public {
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);
        vm.prank(perpEngine);
        vault.lockCollateral(trader, 100 * ONE_USDC);
        uint256 freeBefore = vault.freeAssets();

        vm.prank(perpEngine);
        vault.releaseCollateral(trader, 30 * ONE_USDC);
        assertEq(vault.positionCollateral(), 70 * ONE_USDC);
        assertEq(vault.freeAssets(), freeBefore); // unchanged
    }

    function test_OpenPositionFlow_FeeSplitGoesToCorrectBuckets() public {
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);

        uint256 freeBefore = vault.freeAssets();
        // collateral 1000 USDC, fee 75 bps on 100k notional = 750 USDC.
        uint256 collat = 1_000 * ONE_USDC;
        uint256 fee = 750 * ONE_USDC;
        uint256 lpRebate = (fee * 40) / 100; // 300
        uint256 insurance = (fee * 50) / 100; // 375
        // residual = 75 USDC

        vm.prank(perpEngine);
        vault.openPositionFlow(trader, collat, fee, lpRebate, insurance);

        assertEq(vault.positionCollateral(), collat);
        assertEq(vault.insuranceFundBalance(), insurance);
        assertEq(vault.accruedFees(), fee - lpRebate - insurance); // 75 USDC residual
        // freeAssets gained `lpRebate` (LP rebate stays in the share-NAV bucket).
        assertEq(vault.freeAssets(), freeBefore + lpRebate);
    }

    function test_SettlePosition_TraderProfit() public {
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);

        uint256 collat = 1_000 * ONE_USDC;
        uint256 fee = 0;
        vm.prank(perpEngine);
        vault.openPositionFlow(trader, collat, fee, 0, 0);

        uint256 freeBefore = vault.freeAssets();
        uint256 traderBalBefore = usdc.balanceOf(trader);

        // trader profits 100 USDC
        vm.prank(perpEngine);
        vault.settlePosition(trader, collat, int256(100 * ONE_USDC), 0, 0, 0);

        // trader received collat + 100 USDC
        assertEq(usdc.balanceOf(trader) - traderBalBefore, collat + 100 * ONE_USDC);
        assertEq(vault.positionCollateral(), 0);
        // freeAssets dropped by trader's profit
        assertEq(vault.freeAssets(), freeBefore - 100 * ONE_USDC);
    }

    function test_SettlePosition_TraderLoss() public {
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);

        uint256 collat = 1_000 * ONE_USDC;
        vm.prank(perpEngine);
        vault.openPositionFlow(trader, collat, 0, 0, 0);

        uint256 freeBefore = vault.freeAssets();
        uint256 traderBalBefore = usdc.balanceOf(trader);

        // trader loses 100 USDC
        vm.prank(perpEngine);
        vault.settlePosition(trader, collat, -int256(100 * ONE_USDC), 0, 0, 0);

        // trader received collat - 100 USDC
        assertEq(usdc.balanceOf(trader) - traderBalBefore, collat - 100 * ONE_USDC);
        // freeAssets gained the trader's loss
        assertEq(vault.freeAssets(), freeBefore + 100 * ONE_USDC);
    }

    function test_SettlePosition_BreakEven() public {
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);

        uint256 collat = 1_000 * ONE_USDC;
        vm.prank(perpEngine);
        vault.openPositionFlow(trader, collat, 0, 0, 0);

        uint256 freeBefore = vault.freeAssets();
        vm.prank(perpEngine);
        vault.settlePosition(trader, collat, 0, 0, 0, 0);

        assertEq(vault.freeAssets(), freeBefore);
    }

    function test_SettlePosition_RevertUnderwater() public {
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);

        uint256 collat = 1_000 * ONE_USDC;
        vm.prank(perpEngine);
        vault.openPositionFlow(trader, collat, 0, 0, 0);

        // Loss exceeds collateral; v0 must refuse voluntary close into underwater.
        vm.prank(perpEngine);
        vm.expectRevert(
            abi.encodeWithSelector(ILPVault.UnderwaterClose.selector, collat, -int256(collat + 1), uint256(0))
        );
        vault.settlePosition(trader, collat, -int256(collat + 1), 0, 0, 0);
    }

    function test_SettlePosition_RevertOnInsufficientFreeAssetsForProfit() public {
        // v2-audit Fix #2: profitable PnL portion must be backed by freeAssets.
        // Setup: vault has small freeAssets relative to the trader's profit.
        // Alice deposits $1000. Trader opens $500 collat. freeAssets = $1000.
        vm.prank(alice);
        vault.deposit(1_000 * ONE_USDC, alice);
        vm.prank(perpEngine);
        vault.openPositionFlow(trader, 500 * ONE_USDC, 0, 0, 0);
        // freeAssets is now $1000, positionCollateral $500.
        // Try to settle with $2000 profit (way exceeds freeAssets).
        vm.prank(perpEngine);
        vm.expectRevert(
            abi.encodeWithSelector(ILPVault.InsufficientFreeAssets.selector, 2_000 * ONE_USDC, 1_000 * ONE_USDC)
        );
        vault.settlePosition(trader, 500 * ONE_USDC, int256(2_000 * ONE_USDC), 0, 0, 0);
    }

    function test_SettlePosition_AllowsProfitWithinFreeAssets() public {
        vm.prank(alice);
        vault.deposit(1_000 * ONE_USDC, alice);
        vm.prank(perpEngine);
        vault.openPositionFlow(trader, 500 * ONE_USDC, 0, 0, 0);
        // Profit of $500 is within freeAssets ($1000) — should succeed.
        vm.prank(perpEngine);
        vault.settlePosition(trader, 500 * ONE_USDC, int256(500 * ONE_USDC), 0, 0, 0);
    }

    function test_SettlePosition_RevertOnExcessRelease() public {
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);

        vm.prank(perpEngine);
        vault.openPositionFlow(trader, 100 * ONE_USDC, 0, 0, 0);

        vm.prank(perpEngine);
        vm.expectRevert(
            abi.encodeWithSelector(ILPVault.InsufficientPositionCollateral.selector, 200 * ONE_USDC, 100 * ONE_USDC)
        );
        vault.settlePosition(trader, 200 * ONE_USDC, 0, 0, 0, 0);
    }

    function test_OpenPositionFlow_RevertOnInvalidFeeSplit() public {
        vm.prank(perpEngine);
        vm.expectRevert(
            abi.encodeWithSelector(ILPVault.FeeSplitInvalid.selector, uint256(100), uint256(60), uint256(60))
        );
        vault.openPositionFlow(trader, 1, 100, 60, 60); // 60+60 > 100
    }

    function test_OpenPositionFlow_RevertOnZeroCollateral() public {
        vm.prank(perpEngine);
        vm.expectRevert(ILPVault.AmountZero.selector);
        vault.openPositionFlow(trader, 0, 0, 0, 0);
    }

    function test_LockCollateral_RevertOnZero() public {
        vm.prank(perpEngine);
        vm.expectRevert(ILPVault.AmountZero.selector);
        vault.lockCollateral(trader, 0);
    }

    function test_ReleaseCollateral_RevertOnZero() public {
        vm.prank(perpEngine);
        vm.expectRevert(ILPVault.AmountZero.selector);
        vault.releaseCollateral(trader, 0);
    }

    function test_ReleaseCollateral_RevertOnExcess() public {
        vm.prank(perpEngine);
        vault.lockCollateral(trader, 100 * ONE_USDC);

        vm.prank(perpEngine);
        vm.expectRevert(
            abi.encodeWithSelector(ILPVault.InsufficientPositionCollateral.selector, 200 * ONE_USDC, 100 * ONE_USDC)
        );
        vault.releaseCollateral(trader, 200 * ONE_USDC);
    }

    // ------------------------------------------------------------------------------------------
    // Operator gating
    // ------------------------------------------------------------------------------------------

    function test_OperatorGating_NonPerpEngineRejected() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.openPositionFlow(trader, 100, 0, 0, 0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.lockCollateral(trader, 100);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.releaseCollateral(trader, 100);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.settlePosition(trader, 100, 0, 0, 0, 0);
    }

    function test_OperatorGating_RevertWhenPerpEngineUnset() public {
        // Deploy a fresh vault without setting perpEngine. Every operator entrypoint should
        // revert with PerpEngineNotSet, exercising the modifier on each function.
        LPVault impl = new LPVault();
        bytes memory initData =
            abi.encodeCall(LPVault.initialize, (IERC20(address(usdc)), governance, operator, TIMELOCK_DELAY, "x", "x"));
        LPVault freshVault = LPVault(address(new ERC1967Proxy(address(impl), initData)));

        vm.startPrank(perpEngine);
        vm.expectRevert(ILPVault.PerpEngineNotSet.selector);
        freshVault.lockCollateral(trader, 100);

        vm.expectRevert(ILPVault.PerpEngineNotSet.selector);
        freshVault.releaseCollateral(trader, 100);

        vm.expectRevert(ILPVault.PerpEngineNotSet.selector);
        freshVault.openPositionFlow(trader, 100, 0, 0, 0);

        vm.expectRevert(ILPVault.PerpEngineNotSet.selector);
        freshVault.settlePosition(trader, 100, 0, 0, 0, 0);
        vm.stopPrank();
    }

    function test_SettlePosition_RevertOnZeroCollateral() public {
        vm.prank(perpEngine);
        vm.expectRevert(ILPVault.AmountZero.selector);
        vault.settlePosition(trader, 0, 0, 0, 0, 0);
    }

    function test_SettlePosition_RevertOnInvalidFeeSplit() public {
        vm.prank(perpEngine);
        vault.openPositionFlow(trader, 100 * ONE_USDC, 0, 0, 0);
        // 60 + 60 > 100 — invalid split
        vm.prank(perpEngine);
        vm.expectRevert(
            abi.encodeWithSelector(ILPVault.FeeSplitInvalid.selector, uint256(100), uint256(60), uint256(60))
        );
        vault.settlePosition(trader, 100 * ONE_USDC, 0, 100, 60, 60);
    }

    // ------------------------------------------------------------------------------------------
    // Pause behavior
    // ------------------------------------------------------------------------------------------

    function test_DepositsPaused_BlocksDeposit() public {
        vm.prank(operator);
        vault.setDepositsPaused(true);
        assertTrue(vault.depositsPaused());
        assertEq(vault.maxDeposit(alice), 0);

        // ERC-4626 standard: max == 0 means deposit reverts with ExceededMaxDeposit.
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(USDC_1M, alice);
    }

    function test_DepositsPaused_BlocksMint() public {
        vm.prank(operator);
        vault.setDepositsPaused(true);
        assertEq(vault.maxMint(alice), 0);
    }

    function test_WithdrawalsPaused_BlocksWithdraw() public {
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);
        vm.prank(operator);
        vault.setWithdrawalsPaused(true);
        assertTrue(vault.withdrawalsPaused());
        assertEq(vault.maxWithdraw(alice), 0);

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(USDC_1M, alice, alice);
    }

    function test_WithdrawalsPaused_BlocksRedeem() public {
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);
        vm.prank(operator);
        vault.setWithdrawalsPaused(true);
        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_Pause_DoesNotBlockPerpEngineFlows() public {
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);

        vm.startPrank(operator);
        vault.setDepositsPaused(true);
        vault.setWithdrawalsPaused(true);
        vm.stopPrank();

        // PerpEngine should still be able to lock + release + settle
        vm.prank(perpEngine);
        vault.openPositionFlow(trader, 100 * ONE_USDC, 0, 0, 0);

        vm.prank(perpEngine);
        vault.settlePosition(trader, 100 * ONE_USDC, 0, 0, 0, 0);
    }

    function test_SetDepositsPaused_RevertOnNonOperator() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.setDepositsPaused(true);
    }

    function test_SetWithdrawalsPaused_RevertOnNonOperator() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.setWithdrawalsPaused(true);
    }

    // ------------------------------------------------------------------------------------------
    // maxWithdraw / maxRedeem caps
    // ------------------------------------------------------------------------------------------

    function test_MaxWithdraw_CappedAtFreeAssets() public {
        vm.prank(alice);
        vault.deposit(USDC_1M, alice);

        // PerpEngine locks most of the LP funds. Alice can still see them as her share-implied
        // assets, but maxWithdraw should be capped at freeAssets.
        vm.prank(perpEngine);
        vault.openPositionFlow(trader, 900_000 * ONE_USDC, 0, 0, 0);

        uint256 free = vault.freeAssets();
        // Alice's shares represent the full deposit, but only `free` is currently redeemable.
        assertEq(vault.maxWithdraw(alice), free);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: setPerpEngine
    // ------------------------------------------------------------------------------------------

    function test_SetPerpEngine_HappyPath() public {
        address newEngine = makeAddr("newEngine");
        vm.prank(governance);
        vault.proposeSetPerpEngine(newEngine);
        (address pending, uint64 readyAt) = vault.pendingPerpEngine();
        assertEq(pending, newEngine);
        assertEq(readyAt, uint64(block.timestamp + TIMELOCK_DELAY));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateSetPerpEngine();
        assertEq(vault.perpEngine(), newEngine);
    }

    function test_ProposeSetPerpEngine_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.proposeSetPerpEngine(makeAddr("x"));
    }

    function test_ProposeSetPerpEngine_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(ILPVault.InvalidConfig.selector);
        vault.proposeSetPerpEngine(address(0));
    }

    function test_ProposeSetPerpEngine_RevertOnPendingExists() public {
        vm.startPrank(governance);
        vault.proposeSetPerpEngine(makeAddr("x"));
        vm.expectRevert(ILPVault.PendingProposalExists.selector);
        vault.proposeSetPerpEngine(makeAddr("y"));
        vm.stopPrank();
    }

    function test_ActivateSetPerpEngine_RevertOnNoPending() public {
        vm.expectRevert(ILPVault.NoPendingProposal.selector);
        vault.activateSetPerpEngine();
    }

    function test_ActivateSetPerpEngine_RevertBeforeTimelock() public {
        vm.prank(governance);
        vault.proposeSetPerpEngine(makeAddr("x"));
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.TimelockNotElapsed.selector, readyAt));
        vault.activateSetPerpEngine();
    }

    function test_CancelSetPerpEngine_HappyPath() public {
        vm.prank(governance);
        vault.proposeSetPerpEngine(makeAddr("x"));
        vm.prank(governance);
        vault.cancelSetPerpEngine();
        (address pending, uint64 readyAt) = vault.pendingPerpEngine();
        assertEq(pending, address(0));
        assertEq(readyAt, 0);
    }

    function test_CancelSetPerpEngine_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(ILPVault.NoPendingProposal.selector);
        vault.cancelSetPerpEngine();
    }

    function test_CancelSetPerpEngine_RevertOnNonGovernance() public {
        vm.prank(governance);
        vault.proposeSetPerpEngine(makeAddr("x"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.cancelSetPerpEngine();
    }

    // ------------------------------------------------------------------------------------------
    // Governance: governance transfer
    // ------------------------------------------------------------------------------------------

    function test_GovernanceTransfer_HappyPath() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        vault.proposeGovernanceTransfer(newGov);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateGovernanceTransfer();
        assertEq(vault.governance(), newGov);
    }

    function test_ProposeGovernanceTransfer_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.proposeGovernanceTransfer(makeAddr("x"));
    }

    function test_ProposeGovernanceTransfer_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(ILPVault.InvalidConfig.selector);
        vault.proposeGovernanceTransfer(address(0));
    }

    function test_ProposeGovernanceTransfer_RevertOnPendingExists() public {
        vm.startPrank(governance);
        vault.proposeGovernanceTransfer(makeAddr("x"));
        vm.expectRevert(ILPVault.PendingProposalExists.selector);
        vault.proposeGovernanceTransfer(makeAddr("y"));
        vm.stopPrank();
    }

    function test_ActivateGovernanceTransfer_RevertOnNoPending() public {
        vm.expectRevert(ILPVault.NoPendingProposal.selector);
        vault.activateGovernanceTransfer();
    }

    function test_ActivateGovernanceTransfer_RevertBeforeTimelock() public {
        vm.prank(governance);
        vault.proposeGovernanceTransfer(makeAddr("x"));
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.TimelockNotElapsed.selector, readyAt));
        vault.activateGovernanceTransfer();
    }

    function test_CancelGovernanceTransfer_HappyPath() public {
        vm.prank(governance);
        vault.proposeGovernanceTransfer(makeAddr("x"));
        vm.prank(governance);
        vault.cancelGovernanceTransfer();
        (address pending, uint64 readyAt) = vault.pendingGovernance();
        assertEq(pending, address(0));
        assertEq(readyAt, 0);
    }

    function test_CancelGovernanceTransfer_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(ILPVault.NoPendingProposal.selector);
        vault.cancelGovernanceTransfer();
    }

    function test_CancelGovernanceTransfer_RevertOnNonGovernance() public {
        vm.prank(governance);
        vault.proposeGovernanceTransfer(makeAddr("x"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.cancelGovernanceTransfer();
    }

    // ------------------------------------------------------------------------------------------
    // setOperator
    // ------------------------------------------------------------------------------------------

    function test_SetOperator_HappyPath() public {
        address newOp = makeAddr("newOp");
        vm.prank(governance);
        vault.setOperator(newOp);
        assertEq(vault.operator(), newOp);
    }

    function test_SetOperator_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(ILPVault.InvalidConfig.selector);
        vault.setOperator(address(0));
    }

    function test_SetOperator_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.setOperator(makeAddr("x"));
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    // ------------------------------------------------------------------------------------------
    // Fix #6 — seedInsurance
    // ------------------------------------------------------------------------------------------

    function test_SeedInsurance_HappyPath() public {
        usdc.mint(governance, 5_000_000 * ONE_USDC);
        vm.prank(governance);
        usdc.approve(address(vault), type(uint256).max);

        uint256 freeBefore = vault.freeAssets();
        uint256 insBefore = vault.insuranceFundBalance();

        vm.expectEmit(true, false, false, true, address(vault));
        emit ILPVault.InsuranceSeeded(governance, 1_000_000 * ONE_USDC, 1_000_000 * ONE_USDC);
        vm.prank(governance);
        vault.seedInsurance(1_000_000 * ONE_USDC);

        assertEq(vault.insuranceFundBalance() - insBefore, 1_000_000 * ONE_USDC);
        assertEq(vault.insuranceSeedDeposited(), 1_000_000 * ONE_USDC);
        // freeAssets unchanged: balance and bookkeeper both rise by the same amount
        assertEq(vault.freeAssets(), freeBefore);
    }

    function test_SeedInsurance_RevertOnNonGovernance() public {
        usdc.mint(stranger, 1_000_000 * ONE_USDC);
        vm.prank(stranger);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.seedInsurance(1_000 * ONE_USDC);
    }

    function test_SeedInsurance_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(ILPVault.AmountZero.selector);
        vault.seedInsurance(0);
    }

    function test_SeedInsurance_RevertOnCapExceededFirstCall() public {
        uint256 cap = vault.MAX_INSURANCE_SEED();
        usdc.mint(governance, cap + ONE_USDC);
        vm.prank(governance);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InsuranceSeedCapExceeded.selector, cap + ONE_USDC, cap));
        vault.seedInsurance(cap + ONE_USDC);
    }

    function test_SeedInsurance_RevertOnCumulativeCapExceeded() public {
        uint256 cap = vault.MAX_INSURANCE_SEED();
        usdc.mint(governance, cap + ONE_USDC);
        vm.prank(governance);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(governance);
        vault.seedInsurance(cap - ONE_USDC);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InsuranceSeedCapExceeded.selector, cap + ONE_USDC, cap));
        vault.seedInsurance(2 * ONE_USDC);
    }

    function test_SeedInsurance_Repeatable() public {
        usdc.mint(governance, 5_000_000 * ONE_USDC);
        vm.prank(governance);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(governance);
        vault.seedInsurance(1_000_000 * ONE_USDC);
        vm.prank(governance);
        vault.seedInsurance(500_000 * ONE_USDC);
        assertEq(vault.insuranceFundBalance(), 1_500_000 * ONE_USDC);
        assertEq(vault.insuranceSeedDeposited(), 1_500_000 * ONE_USDC);
    }

    function test_SeedInsurance_BalanceInvariantHolds() public {
        usdc.mint(governance, 1_000_000 * ONE_USDC);
        vm.prank(governance);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(governance);
        vault.seedInsurance(1_000_000 * ONE_USDC);

        assertEq(
            usdc.balanceOf(address(vault)),
            vault.freeAssets() + vault.positionCollateral() + vault.insuranceFundBalance() + vault.accruedFees()
        );
    }

    function test_SeedInsurance_DoesNotInflateLpShares() public {
        // Alice deposits before the seed; her share-to-asset ratio should not change after seed.
        vm.prank(alice);
        uint256 sharesAlice = vault.deposit(USDC_1M, alice);
        uint256 priceBefore = vault.previewRedeem(sharesAlice);

        usdc.mint(governance, 500_000 * ONE_USDC);
        vm.prank(governance);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(governance);
        vault.seedInsurance(500_000 * ONE_USDC);

        uint256 priceAfter = vault.previewRedeem(sharesAlice);
        assertEq(priceBefore, priceAfter);
    }

    function test_SeedInsurance_NotGatedByDepositsPaused() public {
        vm.prank(operator);
        vault.setDepositsPaused(true);

        usdc.mint(governance, 100 * ONE_USDC);
        vm.prank(governance);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(governance);
        vault.seedInsurance(100 * ONE_USDC);
        assertEq(vault.insuranceFundBalance(), 100 * ONE_USDC);
    }

    // ------------------------------------------------------------------------------------------
    // Fix #5 — withdrawAccruedFees (proposed → activated → cancelled)
    // ------------------------------------------------------------------------------------------

    function _accrueFees(uint256 fee) internal {
        // pranks vaultPerpEngine to call openPositionFlow; trader pays collat + fee
        vm.prank(perpEngine);
        vault.openPositionFlow(trader, 100 * ONE_USDC, fee, (fee * 40) / 100, (fee * 50) / 100);
    }

    function test_ProposeFeeWithdrawal_HappyPath() public {
        _accrueFees(100 * ONE_USDC); // residual 10 USDC
        address recipient = makeAddr("treasury");

        vm.expectEmit(true, false, false, true, address(vault));
        emit ILPVault.FeeWithdrawalProposed(recipient, 5 * ONE_USDC, uint64(block.timestamp + TIMELOCK_DELAY));
        vm.prank(governance);
        vault.proposeFeeWithdrawal(recipient, 5 * ONE_USDC);

        (address r, uint256 a, uint64 t, bool e) = vault.pendingFeeWithdrawal();
        assertEq(r, recipient);
        assertEq(a, 5 * ONE_USDC);
        assertEq(t, uint64(block.timestamp + TIMELOCK_DELAY));
        assertTrue(e);
    }

    function test_ProposeFeeWithdrawal_RevertOnNonGovernance() public {
        _accrueFees(100 * ONE_USDC);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.proposeFeeWithdrawal(makeAddr("x"), ONE_USDC);
    }

    function test_ProposeFeeWithdrawal_RevertOnZeroRecipient() public {
        _accrueFees(100 * ONE_USDC);
        vm.prank(governance);
        vm.expectRevert(ILPVault.InvalidConfig.selector);
        vault.proposeFeeWithdrawal(address(0), ONE_USDC);
    }

    function test_ProposeFeeWithdrawal_RevertOnZeroAmount() public {
        _accrueFees(100 * ONE_USDC);
        vm.prank(governance);
        vm.expectRevert(ILPVault.AmountZero.selector);
        vault.proposeFeeWithdrawal(makeAddr("x"), 0);
    }

    function test_ProposeFeeWithdrawal_RevertOnAmountExceedsAccrued() public {
        _accrueFees(100 * ONE_USDC);
        uint256 accrued = vault.accruedFees();
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InsufficientAccruedFees.selector, accrued + 1, accrued));
        vault.proposeFeeWithdrawal(makeAddr("x"), accrued + 1);
    }

    function test_ProposeFeeWithdrawal_RevertOnPendingExists() public {
        _accrueFees(100 * ONE_USDC);
        vm.startPrank(governance);
        vault.proposeFeeWithdrawal(makeAddr("a"), ONE_USDC);
        vm.expectRevert(ILPVault.PendingProposalExists.selector);
        vault.proposeFeeWithdrawal(makeAddr("b"), ONE_USDC);
        vm.stopPrank();
    }

    function test_ActivateFeeWithdrawal_HappyPath() public {
        _accrueFees(100 * ONE_USDC);
        address recipient = makeAddr("treasury");
        uint256 amt = 5 * ONE_USDC;
        vm.prank(governance);
        vault.proposeFeeWithdrawal(recipient, amt);

        uint256 accruedBefore = vault.accruedFees();
        uint256 recipBefore = usdc.balanceOf(recipient);
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectEmit(true, false, false, true, address(vault));
        emit ILPVault.FeeWithdrawalActivated(recipient, amt);
        vm.prank(stranger); // permissionless
        vault.activateFeeWithdrawal();

        assertEq(usdc.balanceOf(recipient) - recipBefore, amt);
        assertEq(accruedBefore - vault.accruedFees(), amt);
        (,,, bool exists) = vault.pendingFeeWithdrawal();
        assertFalse(exists);
    }

    function test_ActivateFeeWithdrawal_BalanceInvariantHolds() public {
        _accrueFees(100 * ONE_USDC);
        address recipient = makeAddr("treasury");
        vm.prank(governance);
        vault.proposeFeeWithdrawal(recipient, 5 * ONE_USDC);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateFeeWithdrawal();

        assertEq(
            usdc.balanceOf(address(vault)),
            vault.freeAssets() + vault.positionCollateral() + vault.insuranceFundBalance() + vault.accruedFees()
        );
    }

    function test_ActivateFeeWithdrawal_RevertOnNoPending() public {
        vm.expectRevert(ILPVault.NoPendingProposal.selector);
        vault.activateFeeWithdrawal();
    }

    function test_ActivateFeeWithdrawal_RevertBeforeTimelock() public {
        _accrueFees(100 * ONE_USDC);
        vm.prank(governance);
        vault.proposeFeeWithdrawal(makeAddr("x"), ONE_USDC);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.TimelockNotElapsed.selector, readyAt));
        vault.activateFeeWithdrawal();
    }

    function test_CancelFeeWithdrawal_HappyPath() public {
        _accrueFees(100 * ONE_USDC);
        address recipient = makeAddr("treasury");
        uint256 amt = ONE_USDC;
        vm.prank(governance);
        vault.proposeFeeWithdrawal(recipient, amt);

        vm.expectEmit(true, false, false, true, address(vault));
        emit ILPVault.FeeWithdrawalCancelled(recipient, amt);
        vm.prank(governance);
        vault.cancelFeeWithdrawal();

        (,,, bool exists) = vault.pendingFeeWithdrawal();
        assertFalse(exists);
    }

    function test_CancelFeeWithdrawal_RevertOnNonGovernance() public {
        _accrueFees(100 * ONE_USDC);
        vm.prank(governance);
        vault.proposeFeeWithdrawal(makeAddr("x"), ONE_USDC);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.cancelFeeWithdrawal();
    }

    function test_CancelFeeWithdrawal_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(ILPVault.NoPendingProposal.selector);
        vault.cancelFeeWithdrawal();
    }

    function test_FeeWithdrawal_NotBlockedByWithdrawalsPaused() public {
        _accrueFees(100 * ONE_USDC);
        vm.prank(operator);
        vault.setWithdrawalsPaused(true);

        address recipient = makeAddr("treasury");
        vm.prank(governance);
        vault.proposeFeeWithdrawal(recipient, ONE_USDC);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateFeeWithdrawal();
        assertEq(usdc.balanceOf(recipient), ONE_USDC);
    }

    function test_FeeWithdrawal_FreeAssetsUnchanged() public {
        _accrueFees(100 * ONE_USDC);
        uint256 freeBefore = vault.freeAssets();

        vm.prank(governance);
        vault.proposeFeeWithdrawal(makeAddr("x"), ONE_USDC);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vault.activateFeeWithdrawal();

        // Both balance and accruedFees drop by the withdrawn amount; freeAssets is unchanged.
        assertEq(vault.freeAssets(), freeBefore);
    }

    function test_Withdraw_DefensiveCheckRejectsBypassedMaxCap() public {
        // Deploy a harness whose `exposeWithdraw` reaches the internal `_withdraw` directly,
        // bypassing the wrapper's maxWithdraw cap. The defensive freeAssets check should fire.
        LPVaultDefenseHarness impl = new LPVaultDefenseHarness();
        bytes memory initData =
            abi.encodeCall(LPVault.initialize, (IERC20(address(usdc)), governance, operator, TIMELOCK_DELAY, "x", "x"));
        LPVaultDefenseHarness h = LPVaultDefenseHarness(address(new ERC1967Proxy(address(impl), initData)));

        // freeAssets() is 0 — vault is empty. Any non-zero withdraw should revert with the
        // defensive InsufficientFreeAssets error.
        vm.expectRevert(abi.encodeWithSelector(ILPVault.InsufficientFreeAssets.selector, uint256(100), uint256(0)));
        h.exposeWithdraw(100);
    }

    function test_UpgradeAuthorization_RevertOnNonGovernance() public {
        LPVault newImpl = new LPVault();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.Unauthorized.selector, stranger));
        vault.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeAuthorization_GovernanceCanUpgrade() public {
        LPVault newImpl = new LPVault();
        vm.prank(governance);
        vault.upgradeToAndCall(address(newImpl), "");
        // post-upgrade state preserved
        assertEq(vault.governance(), governance);
        assertEq(vault.perpEngine(), perpEngine);
    }
}
