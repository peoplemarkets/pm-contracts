// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {LPVault} from "../../src/core/LPVault.sol";
import {EventMarket} from "../../src/events/EventMarket.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Fuzz handler for the event-NAV invariants. Drives LP deposit/withdraw/donate on the vault
///         and buy/sell on a single always-live event market. The market is intentionally never
///         resolved during the run so the invariants exercise the pre-resolution (floor-marked)
///         window under arbitrary LP + trader activity.
contract EventNavHandler is Test {
    LPVault internal immutable vault;
    EventMarket internal immutable market;
    MockUSDC internal immutable usdc;

    address[] internal lps;
    address[] internal traders;

    constructor(LPVault vault_, EventMarket market_, MockUSDC usdc_, address[] memory lps_, address[] memory traders_) {
        vault = vault_;
        market = market_;
        usdc = usdc_;
        lps = lps_;
        traders = traders_;
    }

    function _lp(uint256 seed) internal view returns (address) {
        return lps[seed % lps.length];
    }

    function _trader(uint256 seed) internal view returns (address) {
        return traders[seed % traders.length];
    }

    function deposit(uint256 lpSeed, uint256 amt) external {
        address lp = _lp(lpSeed);
        amt = bound(amt, 1e6, 2_000_000e6);
        if (usdc.balanceOf(lp) < amt) return;
        vm.prank(lp);
        vault.deposit(amt, lp);
    }

    function withdraw(uint256 lpSeed, uint256 amt) external {
        address lp = _lp(lpSeed);
        uint256 maxW = vault.maxWithdraw(lp);
        if (maxW == 0) return;
        amt = bound(amt, 1, maxW);
        vm.prank(lp);
        vault.withdraw(amt, lp, lp);
    }

    function donate(uint256 amt) external {
        amt = bound(amt, 1, 100_000e6);
        address from = traders[0];
        if (usdc.balanceOf(from) < amt) return;
        vm.prank(from);
        usdc.transfer(address(vault), amt);
    }

    function buy(uint256 tSeed, bool isYes, uint256 amt) external {
        address t = _trader(tSeed);
        amt = bound(amt, 1e6, 100_000e6);
        if (usdc.balanceOf(t) < amt) return;
        vm.startPrank(t);
        usdc.approve(address(market), amt);
        try market.buyOutcome(isYes, amt, 0) {} catch {}
        vm.stopPrank();
    }

    function sell(uint256 tSeed, bool isYes, uint256 shares) external {
        address t = _trader(tSeed);
        uint256 bal = isYes ? market.yesBalance(t) : market.noBalance(t);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(t);
        try market.sellOutcome(isYes, shares, 0) {} catch {}
    }
}
