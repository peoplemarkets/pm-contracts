// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {DeployBaseMainnetEvents} from "../../script/DeployBaseMainnetEvents.s.sol";
import {EventMarketFactory} from "../../src/events/EventMarketFactory.sol";
import {EventMarketRouter} from "../../src/events/EventMarketRouter.sol";
import {IEventMarketRouter} from "../../src/events/IEventMarketRouter.sol";

/// @title  DeployBaseMainnetEvents script simulation (no fork, no RPC).
/// @notice Asserts the mainnet event-stack deployer's chain-id guard and env-driven config loading
///         to the extent testable locally: the script must refuse to run on any chain other than
///         Base mainnet (8453), and on 8453 it must deploy the EventMarket impl + factory/router
///         proxies wired exactly to the env-provided live-core addresses.
///
/// @dev    Mirrors ScriptRunbookSims: a SINGLE test body so every `vm.setEnv` sequence is strictly
///         ordered — forge may run test functions on parallel threads that share process env, so
///         the guard leg (no env needed) and the deploy legs (env-driven) MUST NOT be split across
///         functions.
contract DeployBaseMainnetEventsScriptTest is Test {
    DeployBaseMainnetEvents internal deployScript;

    uint256 internal constant DEPLOYER_PK = 0xDE1;
    uint32 internal constant TIMELOCK_DELAY = 3600; // 1h — mainnet value AND the router floor.

    address internal governance = makeAddr("governanceSafe");
    address internal lpVault = makeAddr("lpVaultProxy");
    address internal usdc = makeAddr("usdc");
    address internal umaAdapter = makeAddr("umaAdapterProxy");
    address internal feedbackController = makeAddr("feedbackControllerProxy");

    function setUp() public {
        deployScript = new DeployBaseMainnetEvents();
    }

    function _wireEnv(uint256 timelockDelay) internal {
        vm.setEnv("DEPLOYER_PK", vm.toString(DEPLOYER_PK));
        vm.setEnv("GOVERNANCE", vm.toString(governance));
        vm.setEnv("TIMELOCK_DELAY", vm.toString(uint256(timelockDelay)));
        vm.setEnv("LP_VAULT", vm.toString(lpVault));
        vm.setEnv("USDC", vm.toString(usdc));
        vm.setEnv("UMA_ADAPTER", vm.toString(umaAdapter));
        vm.setEnv("FEEDBACK_CONTROLLER", vm.toString(feedbackController));
    }

    /// @dev Single body: guard leg first (env-independent), then the env-driven deploy legs.
    function test_deployBaseMainnetEvents_guardAndConfig() public {
        _run_revertsOffMainnet();
        _run_revertsBelowRouterTimelockFloor();
        _run_deploysAndWiresOnMainnetChainId();
    }

    // ------------------------------------------------------------------------------------------
    // Chain-id guard: the guard runs BEFORE any env read or broadcast, so this needs no env.
    // ------------------------------------------------------------------------------------------
    function _run_revertsOffMainnet() internal {
        assertEq(block.chainid, 31337, "test sanity: default anvil chain id");
        vm.expectRevert(bytes("not base mainnet"));
        deployScript.run();

        // Explicitly also refuse Base Sepolia — the chain this stack was previously deployed on.
        vm.chainId(84532);
        vm.expectRevert(bytes("not base mainnet"));
        deployScript.run();
    }

    // ------------------------------------------------------------------------------------------
    // Router timelock floor: a mainnet run with TIMELOCK_DELAY below the router's 1h
    // MIN_TIMELOCK_DELAY must revert the whole deployment (router proxy init InvalidConfig).
    // ------------------------------------------------------------------------------------------
    function _run_revertsBelowRouterTimelockFloor() internal {
        vm.chainId(8453);
        _wireEnv(TIMELOCK_DELAY - 1);
        vm.expectRevert(IEventMarketRouter.InvalidConfig.selector);
        deployScript.run();
        // The revert unwinds the EVM state but NOT cheatcode state: the script's startBroadcast is
        // still active, so close it before the happy-path leg re-runs the script.
        vm.stopBroadcast();
    }

    // ------------------------------------------------------------------------------------------
    // Happy path on chain id 8453: proxies deployed and initialized against the env addresses.
    // ------------------------------------------------------------------------------------------
    function _run_deploysAndWiresOnMainnetChainId() internal {
        vm.chainId(8453);
        _wireEnv(TIMELOCK_DELAY);
        DeployBaseMainnetEvents.DeployAddresses memory deployed = deployScript.run();

        // All three contracts exist.
        assertTrue(deployed.eventMarketImplementation.code.length > 0, "EventMarket impl has code");
        assertTrue(deployed.eventMarketFactory.code.length > 0, "factory proxy has code");
        assertTrue(deployed.eventMarketRouter.code.length > 0, "router proxy has code");

        // Factory wired to the env-provided live core.
        EventMarketFactory factory = EventMarketFactory(deployed.eventMarketFactory);
        assertEq(factory.governance(), governance, "factory governance");
        assertEq(factory.timelockDelay(), TIMELOCK_DELAY, "factory timelockDelay");
        assertEq(address(factory.lpVault()), lpVault, "factory lpVault");
        assertEq(address(factory.feedbackController()), feedbackController, "factory feedbackController");
        assertEq(address(factory.umaAdapter()), umaAdapter, "factory umaAdapter");
        assertEq(address(factory.usdc()), usdc, "factory usdc");
        assertEq(factory.marketImplementation(), deployed.eventMarketImplementation, "factory marketImplementation");

        // Router wired to the freshly deployed factory.
        EventMarketRouter router = EventMarketRouter(deployed.eventMarketRouter);
        assertEq(router.governance(), governance, "router governance");
        assertEq(router.factory(), deployed.eventMarketFactory, "router factory");
        assertEq(router.usdc(), usdc, "router usdc");
        assertEq(router.timelockDelay(), TIMELOCK_DELAY, "router timelockDelay");

        // No operators pre-wired: the propose/activate choreography is governance's, post-deploy.
        assertFalse(factory.isOperator(deployed.eventMarketRouter), "router NOT yet a factory operator");
    }
}
