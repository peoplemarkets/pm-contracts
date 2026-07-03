// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {EventMarketFactory} from "../src/events/EventMarketFactory.sol";
import {EventMarketRouter} from "../src/events/EventMarketRouter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deploys ONLY the EventMarketRouter, wired to an EXISTING EventMarketFactory.
///
/// Use this when the event-market stack (factory + vault upgrade + vault.eventMarketFactory)
/// is already live — on Base Sepolia that is the case (factory 0xb73f…, vault already
/// upgraded + pointed at it) — and the only missing piece of the custodial dispatch path
/// is the router (pm-engine #10). `DeployEventMarkets.s.sol` redeploys the whole stack;
/// this script deliberately does not.
///
/// Env:
///   DEPLOYER_PK / PRIVATE_KEY  broadcast key (governance recommended; not required —
///                              the router's governance comes from GOVERNANCE below)
///   GOVERNANCE                 router governance (must be the factory's governance so
///                              EnableEventOperator can drive both timelocks with one key)
///   EVENT_MARKET_FACTORY       the EXISTING EventMarketFactory proxy
///   USDC                       settlement USDC (must match the factory's)
///   TIMELOCK_DELAY             router timelock seconds (floor 1 hours, enforced on init)
///
/// After this, allowlist with script/EnableEventOperator.s.sol (propose → 1h → activate).
contract DeployEventRouter is Script {
    function run() external {
        uint256 deployerKey = vm.envOr("DEPLOYER_PK", uint256(0));
        if (deployerKey == 0) {
            deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        }

        address governance = vm.envAddress("GOVERNANCE");
        address factoryProxy = vm.envAddress("EVENT_MARKET_FACTORY");
        address usdc = vm.envAddress("USDC");
        uint32 timelockDelay = uint32(vm.envUint("TIMELOCK_DELAY"));

        // Fail fast if the wiring premise is wrong: the factory must exist and be governed
        // by the same GOVERNANCE that will govern the router, and its USDC must match.
        EventMarketFactory factory = EventMarketFactory(factoryProxy);
        require(factory.governance() == governance, "GOVERNANCE != factory.governance()");
        require(address(factory.usdc()) == usdc, "USDC != factory.usdc()");

        if (deployerKey == 0) {
            vm.startBroadcast();
        } else {
            vm.startBroadcast(deployerKey);
        }

        console2.log("--- Deploying EventMarketRouter (against existing factory) ---");
        console2.log("Existing EventMarketFactory:", factoryProxy);

        EventMarketRouter routerImpl = new EventMarketRouter();
        console2.log("EventMarketRouter Impl:", address(routerImpl));

        bytes memory routerInit =
            abi.encodeCall(EventMarketRouter.initialize, (governance, factoryProxy, usdc, timelockDelay));
        address routerProxy = address(new ERC1967Proxy(address(routerImpl), routerInit));
        console2.log("EventMarketRouter Proxy:", routerProxy);

        vm.stopBroadcast();

        console2.log("------------------------------------------");
        console2.log("Next: allowlist (script/EnableEventOperator.s.sol)");
        console2.log("  export EVENT_MARKET_ROUTER=", routerProxy);
        console2.log("  propose() -> wait timelock (>= 1h) -> activate()");
        console2.log("Engine config:");
        console2.log("  PM_CHAIN__EVENT_MARKET_ROUTER  =", routerProxy);
        console2.log("  PM_CHAIN__EVENT_MARKET_FACTORY =", factoryProxy);
        console2.log("------------------------------------------");
    }
}
