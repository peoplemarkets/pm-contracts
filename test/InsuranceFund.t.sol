// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/Test.sol";

import {IInsuranceFund} from "../src/core/IInsuranceFund.sol";
import {InsuranceFund} from "../src/core/InsuranceFund.sol";

import {MockUSDC} from "./mocks/MockUSDC.sol";

contract InsuranceFundTest is Test {
    InsuranceFund internal fund;
    MockUSDC internal usdc;

    address internal governance = makeAddr("governance");
    address internal lpVault = makeAddr("lpVault"); // EOA stand-in
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");
    address internal recipient = makeAddr("recipient");

    uint32 internal constant TIMELOCK_DELAY = 2 days;
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant USDC_1M = 1_000_000 * ONE_USDC;

    function setUp() public {
        usdc = new MockUSDC();
        InsuranceFund impl = new InsuranceFund();
        bytes memory initData =
            abi.encodeCall(InsuranceFund.initialize, (governance, lpVault, IERC20(address(usdc)), TIMELOCK_DELAY));
        fund = InsuranceFund(address(new ERC1967Proxy(address(impl), initData)));

        // Pre-fund the LP vault stand-in with USDC and pre-approve the fund — mirrors the
        // real `approveInsuranceFund()` setup so `accrue` flows are exercisable in isolation.
        usdc.mint(lpVault, 10 * USDC_1M);
        vm.prank(lpVault);
        usdc.approve(address(fund), type(uint256).max);

        // Fund alice for deposit tests.
        usdc.mint(alice, 10 * USDC_1M);
        vm.prank(alice);
        usdc.approve(address(fund), type(uint256).max);
    }

    // ------------------------------------------------------------------------------------------
    // initialize
    // ------------------------------------------------------------------------------------------

    function test_Initialize_StoresParams() public view {
        assertEq(fund.governance(), governance);
        assertEq(fund.lpVault(), lpVault);
        assertEq(fund.usdc(), address(usdc));
        assertEq(fund.timelockDelay(), TIMELOCK_DELAY);
        assertEq(fund.balance(), 0);
    }

    function test_Initialize_RevertOnZeroGovernance() public {
        InsuranceFund impl = new InsuranceFund();
        bytes memory initData =
            abi.encodeCall(InsuranceFund.initialize, (address(0), lpVault, IERC20(address(usdc)), TIMELOCK_DELAY));
        vm.expectRevert(IInsuranceFund.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroLPVault() public {
        InsuranceFund impl = new InsuranceFund();
        bytes memory initData =
            abi.encodeCall(InsuranceFund.initialize, (governance, address(0), IERC20(address(usdc)), TIMELOCK_DELAY));
        vm.expectRevert(IInsuranceFund.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroUsdc() public {
        InsuranceFund impl = new InsuranceFund();
        bytes memory initData =
            abi.encodeCall(InsuranceFund.initialize, (governance, lpVault, IERC20(address(0)), TIMELOCK_DELAY));
        vm.expectRevert(IInsuranceFund.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooShort() public {
        InsuranceFund impl = new InsuranceFund();
        bytes memory initData =
            abi.encodeCall(InsuranceFund.initialize, (governance, lpVault, IERC20(address(usdc)), uint32(1 minutes)));
        vm.expectRevert(IInsuranceFund.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooLong() public {
        InsuranceFund impl = new InsuranceFund();
        bytes memory initData =
            abi.encodeCall(InsuranceFund.initialize, (governance, lpVault, IERC20(address(usdc)), uint32(60 days)));
        vm.expectRevert(IInsuranceFund.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_DoubleInitReverts() public {
        vm.expectRevert();
        fund.initialize(governance, lpVault, IERC20(address(usdc)), TIMELOCK_DELAY);
    }

    // ------------------------------------------------------------------------------------------
    // deposit
    // ------------------------------------------------------------------------------------------

    function test_Deposit_HappyPath() public {
        vm.expectEmit(true, false, false, true, address(fund));
        emit IInsuranceFund.Deposited(alice, USDC_1M, USDC_1M);
        vm.prank(alice);
        fund.deposit(USDC_1M);

        assertEq(fund.balance(), USDC_1M);
        assertEq(usdc.balanceOf(address(fund)), USDC_1M);
    }

    function test_Deposit_AccumulatesBookkeeper() public {
        vm.prank(alice);
        fund.deposit(USDC_1M);
        vm.prank(alice);
        fund.deposit(500_000 * ONE_USDC);
        assertEq(fund.balance(), USDC_1M + 500_000 * ONE_USDC);
    }

    function test_Deposit_RevertOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IInsuranceFund.AmountZero.selector);
        fund.deposit(0);
    }

    function test_Deposit_PermissionlessAnyoneCanDeposit() public {
        usdc.mint(bob, USDC_1M);
        vm.prank(bob);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(bob);
        fund.deposit(USDC_1M);
        assertEq(fund.balance(), USDC_1M);
    }

    function test_Deposit_DonationDoesNotInflateBookkeeper() public {
        // A direct ERC-20 transfer to the fund inflates `usdc.balanceOf(fund)` but NOT the
        // tracked balance. The cap math on LPVault reads `balance()` so this shields against
        // donation-driven inflation games.
        usdc.mint(stranger, USDC_1M);
        vm.prank(stranger);
        usdc.transfer(address(fund), USDC_1M);

        assertEq(usdc.balanceOf(address(fund)), USDC_1M);
        assertEq(fund.balance(), 0);
    }

    // ------------------------------------------------------------------------------------------
    // accrue (onlyLPVault)
    // ------------------------------------------------------------------------------------------

    function test_Accrue_HappyPath() public {
        vm.expectEmit(false, false, false, true, address(fund));
        emit IInsuranceFund.AccruedFromVault(500 * ONE_USDC, 500 * ONE_USDC);
        vm.prank(lpVault);
        fund.accrue(500 * ONE_USDC);

        assertEq(fund.balance(), 500 * ONE_USDC);
        assertEq(usdc.balanceOf(address(fund)), 500 * ONE_USDC);
    }

    function test_Accrue_RevertOnNonLPVault() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceFund.NotLPVault.selector, stranger));
        fund.accrue(500 * ONE_USDC);
    }

    function test_Accrue_RevertOnZeroAmount() public {
        vm.prank(lpVault);
        vm.expectRevert(IInsuranceFund.AmountZero.selector);
        fund.accrue(0);
    }

    function test_Accrue_RevertOnInsufficientAllowance() public {
        // Revoke the LP vault's allowance and try to accrue.
        vm.prank(lpVault);
        usdc.approve(address(fund), 0);
        vm.prank(lpVault);
        vm.expectRevert();
        fund.accrue(500 * ONE_USDC);
    }

    function test_Accrue_BookkeeperEqualsUsdcBalanceWithoutDonations() public {
        vm.prank(lpVault);
        fund.accrue(500 * ONE_USDC);
        assertEq(fund.balance(), usdc.balanceOf(address(fund)));
    }

    // ------------------------------------------------------------------------------------------
    // drawShortfall (onlyLPVault)
    // ------------------------------------------------------------------------------------------

    function test_DrawShortfall_HappyPath() public {
        vm.prank(lpVault);
        fund.accrue(USDC_1M);

        vm.expectEmit(true, false, false, true, address(fund));
        emit IInsuranceFund.ShortfallDrawn(recipient, 100 * ONE_USDC, USDC_1M - 100 * ONE_USDC);
        vm.prank(lpVault);
        fund.drawShortfall(recipient, 100 * ONE_USDC);

        assertEq(usdc.balanceOf(recipient), 100 * ONE_USDC);
        assertEq(fund.balance(), USDC_1M - 100 * ONE_USDC);
    }

    function test_DrawShortfall_RevertOnNonLPVault() public {
        vm.prank(lpVault);
        fund.accrue(USDC_1M);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceFund.NotLPVault.selector, stranger));
        fund.drawShortfall(recipient, 100 * ONE_USDC);
    }

    function test_DrawShortfall_RevertOnInsufficientBalance() public {
        vm.prank(lpVault);
        fund.accrue(100 * ONE_USDC);
        vm.prank(lpVault);
        vm.expectRevert(
            abi.encodeWithSelector(IInsuranceFund.InsufficientBalance.selector, 200 * ONE_USDC, 100 * ONE_USDC)
        );
        fund.drawShortfall(recipient, 200 * ONE_USDC);
    }

    function test_DrawShortfall_RevertOnZeroAmount() public {
        vm.prank(lpVault);
        vm.expectRevert(IInsuranceFund.AmountZero.selector);
        fund.drawShortfall(recipient, 0);
    }

    function test_DrawShortfall_RevertOnZeroRecipient() public {
        vm.prank(lpVault);
        fund.accrue(100 * ONE_USDC);
        vm.prank(lpVault);
        vm.expectRevert(IInsuranceFund.InvalidConfig.selector);
        fund.drawShortfall(address(0), 1);
    }

    function test_DrawShortfall_FullDrain() public {
        vm.prank(lpVault);
        fund.accrue(USDC_1M);
        vm.prank(lpVault);
        fund.drawShortfall(recipient, USDC_1M);
        assertEq(fund.balance(), 0);
        assertEq(usdc.balanceOf(recipient), USDC_1M);
    }

    // ------------------------------------------------------------------------------------------
    // setLPVault
    // ------------------------------------------------------------------------------------------

    function test_SetLPVault_HappyPath() public {
        address newVault = makeAddr("newVault");
        vm.expectEmit(true, true, false, false, address(fund));
        emit IInsuranceFund.LPVaultSet(lpVault, newVault);
        vm.prank(governance);
        fund.setLPVault(newVault);
        assertEq(fund.lpVault(), newVault);
    }

    function test_SetLPVault_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IInsuranceFund.InvalidConfig.selector);
        fund.setLPVault(address(0));
    }

    function test_SetLPVault_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceFund.Unauthorized.selector, stranger));
        fund.setLPVault(makeAddr("x"));
    }

    function test_SetLPVault_OldVaultLosesAccess() public {
        address newVault = makeAddr("newVault");
        vm.prank(governance);
        fund.setLPVault(newVault);

        // Old vault can no longer accrue or draw.
        vm.prank(lpVault);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceFund.NotLPVault.selector, lpVault));
        fund.accrue(1);

        vm.prank(lpVault);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceFund.NotLPVault.selector, lpVault));
        fund.drawShortfall(recipient, 1);
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    function test_GovernanceTransfer_HappyPath() public {
        address newGov = makeAddr("newGov");
        vm.expectEmit(true, false, false, true, address(fund));
        emit IInsuranceFund.GovernanceTransferProposed(newGov, uint64(block.timestamp + TIMELOCK_DELAY));
        vm.prank(governance);
        fund.proposeGovernanceTransfer(newGov);

        (address pending, uint64 readyAt) = fund.pendingGovernance();
        assertEq(pending, newGov);
        assertEq(readyAt, uint64(block.timestamp + TIMELOCK_DELAY));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectEmit(true, true, false, false, address(fund));
        emit IInsuranceFund.GovernanceTransferActivated(governance, newGov);
        fund.activateGovernanceTransfer();
        assertEq(fund.governance(), newGov);
    }

    function test_ProposeGovernanceTransfer_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceFund.Unauthorized.selector, stranger));
        fund.proposeGovernanceTransfer(makeAddr("x"));
    }

    function test_ProposeGovernanceTransfer_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(IInsuranceFund.InvalidConfig.selector);
        fund.proposeGovernanceTransfer(address(0));
    }

    function test_ProposeGovernanceTransfer_RevertOnPendingExists() public {
        vm.startPrank(governance);
        fund.proposeGovernanceTransfer(makeAddr("x"));
        vm.expectRevert(IInsuranceFund.PendingGovernanceTransferExists.selector);
        fund.proposeGovernanceTransfer(makeAddr("y"));
        vm.stopPrank();
    }

    function test_ActivateGovernanceTransfer_RevertOnNoPending() public {
        vm.expectRevert(IInsuranceFund.NoPendingGovernanceTransfer.selector);
        fund.activateGovernanceTransfer();
    }

    function test_ActivateGovernanceTransfer_RevertBeforeTimelock() public {
        vm.prank(governance);
        fund.proposeGovernanceTransfer(makeAddr("x"));
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceFund.TimelockNotElapsed.selector, readyAt));
        fund.activateGovernanceTransfer();
    }

    function test_CancelGovernanceTransfer_HappyPath() public {
        address pending = makeAddr("pending");
        vm.prank(governance);
        fund.proposeGovernanceTransfer(pending);

        vm.expectEmit(true, false, false, false, address(fund));
        emit IInsuranceFund.GovernanceTransferCancelled(pending);
        vm.prank(governance);
        fund.cancelGovernanceTransfer();

        (address p, uint64 t) = fund.pendingGovernance();
        assertEq(p, address(0));
        assertEq(t, 0);
    }

    function test_CancelGovernanceTransfer_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(IInsuranceFund.NoPendingGovernanceTransfer.selector);
        fund.cancelGovernanceTransfer();
    }

    function test_CancelGovernanceTransfer_RevertOnNonGovernance() public {
        vm.prank(governance);
        fund.proposeGovernanceTransfer(makeAddr("x"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceFund.Unauthorized.selector, stranger));
        fund.cancelGovernanceTransfer();
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function test_UpgradeAuthorization_RevertOnNonGovernance() public {
        InsuranceFund newImpl = new InsuranceFund();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IInsuranceFund.Unauthorized.selector, stranger));
        fund.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeAuthorization_GovernanceCanUpgrade() public {
        InsuranceFund newImpl = new InsuranceFund();
        vm.prank(governance);
        fund.upgradeToAndCall(address(newImpl), "");
        // post-upgrade state preserved
        assertEq(fund.governance(), governance);
        assertEq(fund.lpVault(), lpVault);
    }

    // ------------------------------------------------------------------------------------------
    // End-to-end accrue → draw cycle
    // ------------------------------------------------------------------------------------------

    function test_EndToEnd_DepositAccrueDraw() public {
        // Treasury deposits a seed.
        vm.prank(alice);
        fund.deposit(500_000 * ONE_USDC);

        // LP vault accrues from a settle.
        vm.prank(lpVault);
        fund.accrue(50_000 * ONE_USDC);

        // LP vault draws a shortfall.
        vm.prank(lpVault);
        fund.drawShortfall(recipient, 30_000 * ONE_USDC);

        assertEq(fund.balance(), 520_000 * ONE_USDC);
        assertEq(usdc.balanceOf(recipient), 30_000 * ONE_USDC);
        assertEq(usdc.balanceOf(address(fund)), 520_000 * ONE_USDC);
    }
}
