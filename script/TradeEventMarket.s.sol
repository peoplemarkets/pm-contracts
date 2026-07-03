// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEventMarket} from "../src/events/IEventMarket.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @title  TradeEventMarket — tester self-custody trade flow (approve -> buy -> [sell] -> redeem).
/// @notice A tester runs this with THEIR OWN key against a deployed World-Cup market. It uses the
///         direct-wallet path (`buyOutcome` / `sellOutcome` / `redeemWinnings`) — msg.sender is the
///         trader, no router/operator/engine involved.
///
/// @dev    Env:
///           MARKET   (address)  the EventMarket to trade                          [required]
///           USDC     (address)  the MockUSDC token                                [required]
///           IS_YES   (bool)     true = buy YES, false = buy NO         (default true)
///           SPEND    (uint)     USDC (6-dec) to spend buying, e.g. 100e6 = 100    (default 100e6)
///           MIN_SHARES (uint)   slippage floor on shares out                       (default 0)
///           DO_SELL  (bool)     sell the bought shares right back      (default false)
///           DO_REDEEM(bool)     redeem winnings (market must be RESOLVED) (default false)
///           MINT_FIRST(bool)    self-mint SPEND of MockUSDC first (test faucet) (default true)
///
///         Run (broadcast with the tester's key):
///           MARKET=0x.. USDC=0x.. SPEND=100000000 IS_YES=true \
///             forge script script/TradeEventMarket.s.sol --rpc-url $BASE_SEPOLIA_RPC \
///             --broadcast --private-key $TESTER_PK
///
///         NOTE: enforce a UI minimum trade — dust buys revert (LMSR needs a positive share mint).
contract TradeEventMarket is Script {
    function run() external {
        uint256 testerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address tester = testerKey == 0 ? msg.sender : vm.addr(testerKey);

        address marketAddr = vm.envAddress("MARKET");
        address usdcAddr = vm.envAddress("USDC");
        bool isYes = vm.envOr("IS_YES", true);
        uint256 spend = vm.envOr("SPEND", uint256(100e6));
        uint256 minShares = vm.envOr("MIN_SHARES", uint256(0));
        bool doSell = vm.envOr("DO_SELL", false);
        bool doRedeem = vm.envOr("DO_REDEEM", false);
        bool mintFirst = vm.envOr("MINT_FIRST", true);

        IEventMarket market = IEventMarket(marketAddr);
        IERC20 usdc = IERC20(usdcAddr);

        console2.log("Tester      :", tester);
        console2.log("Market      :", marketAddr);
        console2.log("Buy YES?    :", isYes);
        console2.log("Spend (6dec):", spend);

        if (testerKey == 0) vm.startBroadcast();
        else vm.startBroadcast(testerKey);

        // 0) Optional test faucet: mint play-money USDC to the tester.
        if (mintFirst) MockUSDC(usdcAddr).mint(tester, spend);

        // 1) Approve the market to pull USDC, then buy outcome shares.
        usdc.approve(marketAddr, spend);
        uint256 shares = market.buyOutcome(isYes, spend, minShares);
        console2.log("Bought shares:", shares);
        console2.log("YES price (1e18):", market.priceOf(true));
        console2.log("NO  price (1e18):", market.priceOf(false));

        // 2) Optional: sell the shares straight back (round trip; will realize LMSR spread loss).
        if (doSell) {
            uint256 out = market.sellOutcome(isYes, shares, 0);
            console2.log("Sold shares, USDC out:", out);
        }

        // 3) Optional: redeem winnings (only after the market is RESOLVED to the winning side).
        if (doRedeem) {
            uint256 payout = market.redeemWinnings();
            console2.log("Redeemed payout:", payout);
        }

        vm.stopBroadcast();
    }
}
