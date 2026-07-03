// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IEventMarket} from "../src/events/IEventMarket.sol";
import {EventMarketFactory} from "../src/events/EventMarketFactory.sol";
import {TestEventMarket} from "../test/mocks/TestEventMarket.sol";

/// @title  ResolveWorldCupMarket — operator one-call resolve for the test stack.
/// @notice TEST-ONLY. Resolves a single World-Cup market to a chosen outcome in ONE transaction
///         via {TestEventMarket-resolveForTest}. Must be run by the factory's governance key (the
///         deployer of the stack). No UMA assertion, no bond, no liveness, no timelock.
///
/// @dev    Resolve the market directly by address:
///           MARKET=0x... OUTCOME=1 forge script script/ResolveWorldCupMarket.s.sol \
///             --rpc-url $BASE_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY
///         ...or look it up from the factory by eventId:
///           FACTORY=0x... EVENT_ID=0x... OUTCOME=2 forge script ... (same flags)
///
///         OUTCOME: 1 = YES (team wins), 2 = NO, 3 = VOID (refund half). 0/UNRESOLVED is rejected.
contract ResolveWorldCupMarket is Script {
    function run() external {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));

        // Resolve the market address: prefer MARKET, else look up FACTORY.getMarket(EVENT_ID).
        address market = vm.envOr("MARKET", address(0));
        if (market == address(0)) {
            address factory = vm.envAddress("FACTORY");
            bytes32 eventId = vm.envBytes32("EVENT_ID");
            market = EventMarketFactory(factory).getMarket(eventId);
        }
        require(market != address(0), "market not found (set MARKET or FACTORY+EVENT_ID)");

        uint256 outcomeRaw = vm.envUint("OUTCOME");
        require(outcomeRaw >= 1 && outcomeRaw <= 3, "OUTCOME must be 1=YES, 2=NO, 3=VOID");
        IEventMarket.Outcome outcome = IEventMarket.Outcome(outcomeRaw);

        console2.log("Resolving market:", market);
        console2.log("Outcome (1=YES,2=NO,3=VOID):", outcomeRaw);

        if (deployerKey == 0) vm.startBroadcast();
        else vm.startBroadcast(deployerKey);

        TestEventMarket(market).resolveForTest(outcome);

        vm.stopBroadcast();

        console2.log("Resolved. Status:", uint256(IEventMarket(market).status()));
        console2.log("Final outcome  :", uint256(IEventMarket(market).outcome()));
    }
}
