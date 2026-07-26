// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILPVault} from "../src/core/ILPVault.sol";
import {EventMarket} from "../src/events/EventMarket.sol";
import {EventMarketFactory} from "../src/events/EventMarketFactory.sol";
import {EventMarketRouter} from "../src/events/EventMarketRouter.sol";
import {IFeedbackController} from "../src/feedback/IFeedbackController.sol";
import {UMAAdapter} from "../src/oracle/UMAAdapter.sol";

/// @notice Base mainnet deployment script for the People Markets EVENT stack (CTF markets).
/// @dev    Companion to DeployBaseMainnet.s.sol (which deployed the live core suite on 2026-07-14
///         from commit 278fbbc and deploys ZERO event contracts). This script adds the missing
///         event-market layer against the LIVE core proxies passed in via env:
///
///           - EventMarket implementation      (clone template for the factory)
///           - EventMarketFactory impl + proxy (initialized against the live LPVault / UMAAdapter /
///                                              FeedbackController / USDC)
///           - EventMarketRouter  impl + proxy (engine-relayed custodial *For path)
///
///         NO LPVault UPGRADE IS NEEDED. The live mainnet LPVault implementation
///         (0x7b904e341E14ae82e9Fa78a5CD2E856Bac56A3D5, deployed by DeployBaseMainnet from commit
///         278fbbc — the commit recorded in broadcast/DeployBaseMainnet.s.sol/8453/run-latest.json)
///         already contains the full event surface: `fundEventMarket` (src/core/LPVault.sol:578),
///         `settleEventMarket` (:608) and the timelocked `proposeSetEventMarketFactory` /
///         `activateSetEventMarketFactory` pair (:872/:882). Only the timelocked WIRING is required
///         post-deploy (see _logNextSteps and docs/MAINNET_EVENTS_DEPLOY.md).
///
///         Timelocked activations are NOT executed here (Base mainnet time is real, and governance
///         is the Safe — proposals/activations are Safe transactions, not deployer transactions).
contract DeployBaseMainnetEvents is Script {
    struct DeployConfig {
        address governance;
        address lpVault;
        address usdc;
        address umaAdapter;
        address feedbackController;
        uint32 timelockDelay;
    }

    struct DeployAddresses {
        address eventMarketImplementation;
        address eventMarketFactory;
        address eventMarketRouter;
    }

    function run() external returns (DeployAddresses memory deployed) {
        _requireBaseMainnet();

        uint256 deployerKey = vm.envOr("DEPLOYER_PK", uint256(0));
        if (deployerKey == 0) {
            deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        }
        DeployConfig memory cfg = _loadConfig();

        if (deployerKey == 0) {
            vm.startBroadcast();
        } else {
            vm.startBroadcast(deployerKey);
        }

        deployed.eventMarketImplementation = _deployEventMarketImplementation();
        deployed.eventMarketFactory = _deployEventMarketFactory(cfg, deployed.eventMarketImplementation);
        deployed.eventMarketRouter = _deployEventMarketRouter(cfg, deployed.eventMarketFactory);

        _logNextSteps(cfg, deployed);

        vm.stopBroadcast();
    }

    // ------------------------------------------------------------------------------------------
    // Config
    // ------------------------------------------------------------------------------------------

    function _loadConfig() internal view returns (DeployConfig memory cfg) {
        cfg.governance = vm.envAddress("GOVERNANCE");
        cfg.lpVault = vm.envAddress("LP_VAULT");
        cfg.usdc = vm.envAddress("USDC");
        cfg.umaAdapter = vm.envAddress("UMA_ADAPTER");
        cfg.feedbackController = vm.envAddress("FEEDBACK_CONTROLLER");
        cfg.timelockDelay = uint32(vm.envUint("TIMELOCK_DELAY"));
    }

    function _requireBaseMainnet() internal view {
        require(block.chainid == 8453, "not base mainnet");
    }

    // ------------------------------------------------------------------------------------------
    // Deploy helpers
    // ------------------------------------------------------------------------------------------

    function _deployEventMarketImplementation() internal returns (address impl) {
        impl = address(new EventMarket());
        console2.log("EventMarket impl", impl);
    }

    function _deployEventMarketFactory(
        DeployConfig memory cfg,
        address eventMarketImplementation
    )
        internal
        returns (address proxy)
    {
        EventMarketFactory impl = new EventMarketFactory();
        bytes memory init = abi.encodeCall(
            EventMarketFactory.initialize,
            (
                cfg.governance,
                cfg.timelockDelay,
                ILPVault(cfg.lpVault),
                IFeedbackController(cfg.feedbackController),
                UMAAdapter(cfg.umaAdapter),
                IERC20(cfg.usdc),
                eventMarketImplementation
            )
        );
        proxy = _deployUUPS(address(impl), init);
        console2.log("EventMarketFactory", proxy);
    }

    function _deployEventMarketRouter(DeployConfig memory cfg, address factory) internal returns (address proxy) {
        EventMarketRouter impl = new EventMarketRouter();
        bytes memory init =
            abi.encodeCall(EventMarketRouter.initialize, (cfg.governance, factory, cfg.usdc, cfg.timelockDelay));
        proxy = _deployUUPS(address(impl), init);
        console2.log("EventMarketRouter", proxy);
    }

    function _deployUUPS(address implementation, bytes memory initData) internal returns (address proxy) {
        proxy = address(new ERC1967Proxy(implementation, initData));
    }

    // ------------------------------------------------------------------------------------------
    // Post-deploy guidance
    // ------------------------------------------------------------------------------------------

    function _logNextSteps(DeployConfig memory cfg, DeployAddresses memory deployed) internal view {
        console2.log("--- Next steps (ALL timelocked, executed by governance Safe) ---");
        console2.log("No LPVault upgrade needed: live impl (commit 278fbbc) already has the event surface.");
        console2.log("(a) LPVault.proposeSetEventMarketFactory ->", deployed.eventMarketFactory);
        console2.log("    ...wait timelockDelay, then LPVault.activateSetEventMarketFactory()");
        console2.log("(b) factory.proposeAddOperator ->", deployed.eventMarketRouter);
        console2.log("    ...wait timelockDelay, then factory.activateAddOperator(router)");
        console2.log("(c) router.proposeAddOperator -> <EVENT_OPERATOR KMS signer>");
        console2.log("    ...wait timelockDelay, then router.activateAddOperator(operator)");
        console2.log("(d) UMAAdapter.proposeRegisterMetric per event, then activateRegisterMetric");
        console2.log("    (createMarket REVERTS MetricNotReady until the metric is registered)");
        console2.log("(e) factory.createMarket via governance; vault freeAssets must cover b*ln2 per market");
        console2.log("Full ceremony + verification checks: docs/MAINNET_EVENTS_DEPLOY.md");
        console2.log("Governance:", cfg.governance);
        console2.log("TimelockDelay (s):", uint256(cfg.timelockDelay));
    }
}
