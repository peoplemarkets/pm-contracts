// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {LPVault} from "../src/core/LPVault.sol";
import {MarginEngine} from "../src/core/MarginEngine.sol";
import {PerpEngine} from "../src/core/PerpEngine.sol";
import {SubjectRegistry} from "../src/registry/SubjectRegistry.sol";
import {MatchedFillRouter} from "../src/routers/MatchedFillRouter.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @notice Deploy the minimum real protocol used by the cross-repository local pair-trade smoke.
/// @dev Chain-id locked to Anvil. Phase one deploys and schedules the three required timelocked
///      links. `ConfigureLocal` activates them after the local runner advances the chain by one
///      hour. Nothing in this script is suitable for a public network.
contract DeployLocal is Script {
    uint256 internal constant ANVIL_DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint32 internal constant TIMELOCK_DELAY = 1 hours;

    address internal constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant MAKER_A = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant MAKER_B = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address internal constant TAKER_A = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address internal constant TAKER_B = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    bytes32 internal constant SUBJECT_A = keccak256("drake");
    bytes32 internal constant SUBJECT_B = keccak256("kendrick");

    struct Deployment {
        address usdc;
        address subjectRegistry;
        address lpVault;
        address perpEngine;
        address marginEngine;
        address matchedFillRouter;
    }

    function run() external returns (Deployment memory deployed) {
        require(block.chainid == 31_337, "local deployment requires chain 31337");
        require(vm.addr(ANVIL_DEPLOYER_KEY) == DEPLOYER, "unexpected local deployer");

        vm.startBroadcast(ANVIL_DEPLOYER_KEY);

        deployed.usdc = address(new MockUSDC());
        deployed.subjectRegistry = _deploySubjectRegistry();
        deployed.lpVault = _deployLpVault(deployed.usdc);
        deployed.perpEngine = _deployPerpEngine(deployed.subjectRegistry, deployed.lpVault);
        deployed.marginEngine = _deployMarginEngine(deployed.perpEngine);
        deployed.matchedFillRouter = _deployMatchedFillRouter(deployed.perpEngine);

        LPVault(deployed.lpVault).proposeSetPerpEngine(deployed.perpEngine);
        PerpEngine(deployed.perpEngine).proposeSetMarginEngine(deployed.marginEngine);
        PerpEngine(deployed.perpEngine).proposeAddRouter(deployed.matchedFillRouter);
        PerpEngine(deployed.perpEngine).proposeAddMarkWriter(DEPLOYER);

        vm.stopBroadcast();

        _writeEnvironment(deployed);
        console2.log("Local protocol phase one deployed. Environment: deployments/local/protocol.env");
        console2.log("USDC", deployed.usdc);
        console2.log("SubjectRegistry", deployed.subjectRegistry);
        console2.log("LPVault", deployed.lpVault);
        console2.log("PerpEngine", deployed.perpEngine);
        console2.log("MarginEngine", deployed.marginEngine);
        console2.log("MatchedFillRouter", deployed.matchedFillRouter);
    }

    function _deploySubjectRegistry() private returns (address proxy) {
        SubjectRegistry implementation = new SubjectRegistry();
        address[] memory singleton = new address[](1);
        singleton[0] = DEPLOYER;
        bytes memory initData =
            abi.encodeCall(SubjectRegistry.initialize, (DEPLOYER, TIMELOCK_DELAY, singleton, singleton, singleton));
        proxy = address(new ERC1967Proxy(address(implementation), initData));
    }

    function _deployLpVault(address usdc) private returns (address proxy) {
        LPVault implementation = new LPVault();
        bytes memory initData = abi.encodeCall(
            LPVault.initialize, (IERC20(usdc), DEPLOYER, DEPLOYER, TIMELOCK_DELAY, "People Markets Local LP", "pmLOCAL")
        );
        proxy = address(new ERC1967Proxy(address(implementation), initData));
    }

    function _deployPerpEngine(address subjectRegistry, address lpVault) private returns (address proxy) {
        PerpEngine implementation = new PerpEngine();
        bytes memory initData =
            abi.encodeCall(PerpEngine.initialize, (DEPLOYER, TIMELOCK_DELAY, subjectRegistry, lpVault));
        proxy = address(new ERC1967Proxy(address(implementation), initData));
    }

    function _deployMarginEngine(address perpEngine) private returns (address proxy) {
        MarginEngine implementation = new MarginEngine();
        bytes memory initData = abi.encodeCall(MarginEngine.initialize, (DEPLOYER, perpEngine, TIMELOCK_DELAY));
        proxy = address(new ERC1967Proxy(address(implementation), initData));
    }

    function _deployMatchedFillRouter(address perpEngine) private returns (address proxy) {
        MatchedFillRouter implementation = new MatchedFillRouter();
        bytes memory initData = abi.encodeCall(MatchedFillRouter.initialize, (DEPLOYER, perpEngine, TIMELOCK_DELAY));
        proxy = address(new ERC1967Proxy(address(implementation), initData));
    }

    function _writeEnvironment(Deployment memory deployed) private {
        vm.createDir("deployments/local", true);
        string memory output = "# Generated by DeployLocal.s.sol for chain 31337 only.\n";
        output = string.concat(output, "LOCAL_PROTOCOL_CHAIN_ID=31337\n");
        output = string.concat(output, _addressLine("LOCAL_DEPLOYER", DEPLOYER));
        output = string.concat(output, _addressLine("LOCAL_EXECUTOR", DEPLOYER));
        output = string.concat(output, _addressLine("LOCAL_MAKER_A", MAKER_A));
        output = string.concat(output, _addressLine("LOCAL_MAKER_B", MAKER_B));
        output = string.concat(output, _addressLine("LOCAL_TAKER_A", TAKER_A));
        output = string.concat(output, _addressLine("LOCAL_TAKER_B", TAKER_B));
        output = string.concat(output, _bytes32Line("LOCAL_SUBJECT_A", SUBJECT_A));
        output = string.concat(output, _bytes32Line("LOCAL_SUBJECT_B", SUBJECT_B));
        output = string.concat(output, _addressLine("USDC_ADDRESS", deployed.usdc));
        output = string.concat(output, _addressLine("SUBJECT_REGISTRY_ADDRESS", deployed.subjectRegistry));
        output = string.concat(output, _addressLine("LP_VAULT_ADDRESS", deployed.lpVault));
        output = string.concat(output, _addressLine("PERP_ENGINE_ADDRESS", deployed.perpEngine));
        output = string.concat(output, _addressLine("MARGIN_ENGINE_ADDRESS", deployed.marginEngine));
        output = string.concat(output, _addressLine("MATCHED_FILL_ROUTER_ADDRESS", deployed.matchedFillRouter));
        output = string.concat(output, "USDC_START_BLOCK=0\n");
        output = string.concat(output, "SUBJECT_REGISTRY_START_BLOCK=0\n");
        output = string.concat(output, "LP_VAULT_START_BLOCK=0\n");
        output = string.concat(output, "PERP_ENGINE_START_BLOCK=0\n");
        output = string.concat(output, "MARGIN_ENGINE_START_BLOCK=0\n");
        output = string.concat(output, "MATCHED_FILL_ROUTER_START_BLOCK=0\n");
        output = string.concat(output, _addressLine("PM_CHAIN__SUBJECT_REGISTRY", deployed.subjectRegistry));
        output = string.concat(output, _addressLine("PM_CHAIN__LP_VAULT", deployed.lpVault));
        output = string.concat(output, _addressLine("PM_CHAIN__PERP_ENGINE", deployed.perpEngine));
        output = string.concat(output, _addressLine("PM_CHAIN__MATCHED_FILL_ROUTER", deployed.matchedFillRouter));
        output = string.concat(output, "MATCHED_FILL_CHAIN_ID=31337\n");
        output = string.concat(output, _addressLine("MATCHED_FILL_EXECUTOR_ADDRESS", DEPLOYER));
        // Chain-31337-only generated addresses; the path is fixed and gitignored.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile("deployments/local/protocol.env", output);
    }

    function _addressLine(string memory key, address value) private pure returns (string memory) {
        return string.concat(key, "=", vm.toString(value), "\n");
    }

    function _bytes32Line(string memory key, bytes32 value) private pure returns (string memory) {
        return string.concat(key, "=", vm.toString(value), "\n");
    }
}
