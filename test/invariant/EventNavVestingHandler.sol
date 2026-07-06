// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {LPVault} from "../../src/core/LPVault.sol";
import {EventMarket} from "../../src/events/EventMarket.sol";
import {EventMarketFactory} from "../../src/events/EventMarketFactory.sol";
import {IEventMarket} from "../../src/events/IEventMarket.sol";
import {LMSRMath} from "../../src/events/LMSRMath.sol";

import {MockUMAAdapter} from "../events/mocks/MockEventDeps.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Fuzz handler that drives the FULL event-market lifecycle — create → trade → settle —
///         repeatedly, so the receive-only vesting bucket is exercised with `unvestedEventSurplus > 0`
///         (the state the always-live handler never reaches). Also warps time so the bucket drips.
contract EventNavVestingHandler is Test {
    LPVault internal immutable vault;
    EventMarketFactory internal immutable factory;
    MockUSDC internal immutable usdc;
    MockUMAAdapter internal immutable uma;
    address internal immutable governance;

    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant LMSR_B = 10_000e6;
    uint64 internal constant DEADLINE = 2_000_000_000;

    address[] internal lps;
    address[] internal traders;

    EventMarket internal current; // the single currently-live market (0 when none)
    uint256 internal nonce;

    constructor(
        LPVault vault_,
        EventMarketFactory factory_,
        MockUSDC usdc_,
        MockUMAAdapter uma_,
        address governance_,
        address[] memory lps_,
        address[] memory traders_
    ) {
        vault = vault_;
        factory = factory_;
        usdc = usdc_;
        uma = uma_;
        governance = governance_;
        lps = lps_;
        traders = traders_;
    }

    function _lp(uint256 seed) internal view returns (address) {
        return lps[seed % lps.length];
    }

    function _trader(uint256 seed) internal view returns (address) {
        return traders[seed % traders.length];
    }

    function _seed() internal pure returns (uint256) {
        return LMSRMath.cost(0, 0, LMSR_B);
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
        if (usdc.balanceOf(traders[0]) < amt) return;
        vm.prank(traders[0]);
        usdc.transfer(address(vault), amt);
    }

    function createMarket() external {
        if (address(current) != address(0)) return; // one live market at a time
        if (vault.freeAssets() < _seed()) return; // needs liquid seed
        // Ensure the UMA mock is unresolved for the fresh market's trading window.
        uma.setLatestValue(0, 0);
        bytes32 id = keccak256(abi.encode("vest.market", nonce++));
        vm.prank(governance);
        current = EventMarket(factory.createMarket(id, id, uint8(1), "Q?", DEADLINE, 0, LMSR_B));
    }

    function buy(uint256 tSeed, bool isYes, uint256 amt) external {
        if (address(current) == address(0)) return;
        address t = _trader(tSeed);
        amt = bound(amt, 1e6, 200_000e6);
        if (usdc.balanceOf(t) < amt) return;
        vm.startPrank(t);
        usdc.approve(address(current), amt);
        try current.buyOutcome(isYes, amt, 0) {} catch {}
        vm.stopPrank();
    }

    function sell(uint256 tSeed, bool isYes, uint256 shares) external {
        if (address(current) == address(0)) return;
        address t = _trader(tSeed);
        uint256 bal = isYes ? current.yesBalance(t) : current.noBalance(t);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(t);
        try current.sellOutcome(isYes, shares, 0) {} catch {}
    }

    function settle(uint8 rawOutcome) external {
        if (address(current) == address(0)) return;
        uint256 o = bound(rawOutcome, 1, 3); // YES / NO / VOID
        uma.setLatestValue(o, uint64(block.timestamp));
        try current.settleResolution() {
            current = EventMarket(address(0));
        } catch {}
    }

    function warpTime(uint32 dt) external {
        uint256 d = bound(uint256(dt), 1, 6 hours);
        vm.warp(block.timestamp + d);
    }
}
