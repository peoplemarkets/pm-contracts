// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {LPVault} from "../src/core/LPVault.sol";
import {EventMarket} from "../src/events/EventMarket.sol";
import {EventMarketFactory} from "../src/events/EventMarketFactory.sol";
import {EventMarketRouter} from "../src/events/EventMarketRouter.sol";
import {IFeedbackController} from "../src/feedback/IFeedbackController.sol";
import {UMAAdapter} from "../src/oracle/UMAAdapter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Script to deploy EventMarkets (CTF) to an existing environment
contract DeployEventMarkets is Script {
    function run() external {
        uint256 deployerKey = vm.envOr("DEPLOYER_PK", uint256(0));
        if (deployerKey == 0) {
            deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        }

        address lpVaultProxy = vm.envAddress("LP_VAULT_ADDRESS");
        address usdc = vm.envAddress("USDC");
        address umaAdapter = vm.envAddress("UMA_ADAPTER_ADDRESS");
        address feedbackController = vm.envAddress("FEEDBACK_CONTROLLER_ADDRESS");

        if (deployerKey == 0) {
            vm.startBroadcast();
        } else {
            vm.startBroadcast(deployerKey);
        }

        console2.log("--- Deploying EventMarket Implementation ---");
        EventMarket eventMarketImpl = new EventMarket();
        console2.log("EventMarket Impl:", address(eventMarketImpl));

        console2.log("--- Deploying EventMarketFactory ---");
        EventMarketFactory factoryImpl = new EventMarketFactory();

        bytes memory factoryInit = abi.encodeCall(
            EventMarketFactory.initialize,
            (
                vm.envAddress("GOVERNANCE"),
                uint32(vm.envUint("TIMELOCK_DELAY")),
                LPVault(lpVaultProxy),
                IFeedbackController(feedbackController),
                UMAAdapter(umaAdapter),
                IERC20(usdc),
                address(eventMarketImpl)
            )
        );
        address factoryProxy = address(new ERC1967Proxy(address(factoryImpl), factoryInit));
        console2.log("EventMarketFactory Proxy:", factoryProxy);

        console2.log("--- Deploying EventMarketRouter (engine-relayed *For path) ---");
        EventMarketRouter routerImpl = new EventMarketRouter();
        console2.log("EventMarketRouter Impl:", address(routerImpl));

        bytes memory routerInit = abi.encodeCall(
            EventMarketRouter.initialize,
            (vm.envAddress("GOVERNANCE"), factoryProxy, usdc, uint32(vm.envUint("TIMELOCK_DELAY")))
        );
        address routerProxy = address(new ERC1967Proxy(address(routerImpl), routerInit));
        console2.log("EventMarketRouter Proxy:", routerProxy);

        console2.log("--- Deploying New LPVault Implementation ---");
        LPVault newVaultImpl = new LPVault();
        console2.log("New LPVault Impl:", address(newVaultImpl));

        console2.log("------------------------------------------");
        console2.log("Deployment Complete. Next steps (governance + ops, NOT done here):");
        console2.log("1. Upgrade LPVault proxy:");
        console2.log("   LPVault(proxy).upgradeTo(New LPVault Impl)");
        console2.log("2. Grant EVENT_MARKET_ROLE to the Factory:");
        console2.log("   LPVault(proxy).grantRole(EVENT_MARKET_ROLE, EventMarketFactory)");
        console2.log("3. Register the Router as a factory operator (layer i, timelocked):");
        console2.log("   EventMarketFactory(factory).proposeAddOperator(EventMarketRouter)");
        console2.log("   ...after TIMELOCK_DELAY: activateAddOperator(EventMarketRouter)");
        console2.log("4. Register the engine KMS key as a router operator (layer ii, timelocked):");
        console2.log("   EventMarketRouter(router).proposeAddOperator(ENGINE_OPERATOR_KEY)");
        console2.log("   ...after TIMELOCK_DELAY: activateAddOperator(ENGINE_OPERATOR_KEY)");
        console2.log("5. Users approve USDC to the EventMarketRouter (single approval).");
        console2.log("------------------------------------------");

        vm.stopBroadcast();
    }
}
