// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {LPVault} from "../src/core/LPVault.sol";
import {MarginEngine} from "../src/core/MarginEngine.sol";
import {PerpEngine} from "../src/core/PerpEngine.sol";
import {EventMarket} from "../src/events/EventMarket.sol";
import {EventMarketFactory} from "../src/events/EventMarketFactory.sol";
import {EventMarketRouter} from "../src/events/EventMarketRouter.sol";
import {IFeedbackController} from "../src/feedback/IFeedbackController.sol";
import {IOptimisticOracleV3, UMAAdapter} from "../src/oracle/UMAAdapter.sol";
import {SubjectRegistry} from "../src/registry/SubjectRegistry.sol";
import {MatchedFillRouter} from "../src/routers/MatchedFillRouter.sol";
import {MockFeedbackController} from "../test/events/mocks/MockEventDeps.sol";
import {MockOptimisticOracleV3} from "../test/mocks/MockOptimisticOracleV3.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @notice Deploy the real trading primitives used by the cross-repository local acceptance smokes.
/// @dev Chain-id locked to Anvil. Phase one deploys the person, matched-pair, and event-market
///      contracts and schedules their required timelocked links. `ConfigureLocal` activates those
///      links after the local runner advances the chain by one hour. Test doubles are limited to
///      local USDC, the optimistic oracle, and feedback dispatch; nothing here is suitable for a
///      public network.
contract DeployLocal is Script {
    uint256 internal constant ANVIL_DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    string internal constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";
    uint32 internal constant EXECUTOR_INDEX = 5;
    uint32 internal constant TIMELOCK_DELAY = 1 hours;
    uint64 internal constant EVENT_LIVENESS = 60;
    uint256 internal constant EVENT_BOND = 10e6;
    // The literal is 12 ASCII bytes, so right-padding it into bytes32 cannot truncate data.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant UMA_IDENTIFIER = bytes32("ASSERT_TRUTH");

    address internal constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant MAKER_A = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant MAKER_B = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address internal constant TAKER_A = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address internal constant TAKER_B = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address internal constant EXECUTOR = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;

    bytes32 internal constant SUBJECT_A = keccak256("drake");
    bytes32 internal constant SUBJECT_B = keccak256("kendrick");

    struct Deployment {
        address usdc;
        address subjectRegistry;
        address lpVault;
        address perpEngine;
        address marginEngine;
        address matchedFillRouter;
        address optimisticOracle;
        address umaAdapter;
        address feedbackController;
        address eventMarketImplementation;
        address eventMarketFactory;
        address eventMarketRouter;
    }

    function run() external returns (Deployment memory deployed) {
        require(block.chainid == 31_337, "local deployment requires chain 31337");
        require(vm.addr(ANVIL_DEPLOYER_KEY) == DEPLOYER, "unexpected local deployer");
        // Public chain-31337 test mnemonic; never derives or reads an operator secret.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        uint256 executorKey = vm.deriveKey(ANVIL_MNEMONIC, EXECUTOR_INDEX);
        require(vm.addr(executorKey) == EXECUTOR, "unexpected local executor");
        uint256 localStartBlock = block.number;

        vm.startBroadcast(ANVIL_DEPLOYER_KEY);

        deployed.usdc = address(new MockUSDC());
        deployed.subjectRegistry = _deploySubjectRegistry();
        deployed.lpVault = _deployLpVault(deployed.usdc);
        deployed.perpEngine = _deployPerpEngine(deployed.subjectRegistry, deployed.lpVault);
        deployed.marginEngine = _deployMarginEngine(deployed.perpEngine);
        deployed.matchedFillRouter = _deployMatchedFillRouter(deployed.perpEngine);
        deployed.optimisticOracle = address(new MockOptimisticOracleV3());
        deployed.umaAdapter = _deployUmaAdapter(deployed.optimisticOracle);
        deployed.feedbackController = address(new MockFeedbackController());
        deployed.eventMarketImplementation = address(new EventMarket());
        deployed.eventMarketFactory = _deployEventMarketFactory(deployed);
        deployed.eventMarketRouter = _deployEventMarketRouter(deployed.eventMarketFactory, deployed.usdc);

        bytes32 localEventId =
            keccak256(abi.encode("people-markets-local-event", localStartBlock, deployed.eventMarketFactory));

        LPVault(deployed.lpVault).proposeSetPerpEngine(deployed.perpEngine);
        LPVault(deployed.lpVault).proposeSetEventMarketFactory(deployed.eventMarketFactory);
        PerpEngine(deployed.perpEngine).proposeSetMarginEngine(deployed.marginEngine);
        PerpEngine(deployed.perpEngine).proposeAddRouter(deployed.matchedFillRouter);
        PerpEngine(deployed.perpEngine).proposeAddMarkWriter(DEPLOYER);
        EventMarketFactory(deployed.eventMarketFactory).proposeAddOperator(deployed.eventMarketRouter);
        EventMarketRouter(deployed.eventMarketRouter).proposeAddOperator(EXECUTOR);
        UMAAdapter(deployed.umaAdapter)
            .proposeRegisterMetric(localEventId, EVENT_BOND, EVENT_LIVENESS, UMA_IDENTIFIER, deployed.usdc);

        vm.stopBroadcast();

        _writeEnvironment(deployed, executorKey, localStartBlock, localEventId);
        console2.log("Local protocol phase one deployed. Environment: deployments/local/protocol.env");
        console2.log("USDC", deployed.usdc);
        console2.log("SubjectRegistry", deployed.subjectRegistry);
        console2.log("LPVault", deployed.lpVault);
        console2.log("PerpEngine", deployed.perpEngine);
        console2.log("MarginEngine", deployed.marginEngine);
        console2.log("MatchedFillRouter", deployed.matchedFillRouter);
        console2.log("MockOptimisticOracleV3", deployed.optimisticOracle);
        console2.log("UMAAdapter", deployed.umaAdapter);
        console2.log("EventMarketFactory", deployed.eventMarketFactory);
        console2.log("EventMarketRouter", deployed.eventMarketRouter);
        console2.logBytes32(localEventId);
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

    function _deployUmaAdapter(address optimisticOracle) private returns (address proxy) {
        UMAAdapter implementation = new UMAAdapter();
        bytes memory initData =
            abi.encodeCall(UMAAdapter.initialize, (IOptimisticOracleV3(optimisticOracle), DEPLOYER, TIMELOCK_DELAY));
        proxy = address(new ERC1967Proxy(address(implementation), initData));
    }

    function _deployEventMarketFactory(Deployment memory deployed) private returns (address proxy) {
        EventMarketFactory implementation = new EventMarketFactory();
        bytes memory initData = abi.encodeCall(
            EventMarketFactory.initialize,
            (
                DEPLOYER,
                TIMELOCK_DELAY,
                LPVault(deployed.lpVault),
                IFeedbackController(deployed.feedbackController),
                UMAAdapter(deployed.umaAdapter),
                IERC20(deployed.usdc),
                deployed.eventMarketImplementation
            )
        );
        proxy = address(new ERC1967Proxy(address(implementation), initData));
    }

    function _deployEventMarketRouter(address factory, address usdc) private returns (address proxy) {
        EventMarketRouter implementation = new EventMarketRouter();
        bytes memory initData = abi.encodeCall(EventMarketRouter.initialize, (DEPLOYER, factory, usdc, TIMELOCK_DELAY));
        proxy = address(new ERC1967Proxy(address(implementation), initData));
    }

    function _writeEnvironment(
        Deployment memory deployed,
        uint256 executorKey,
        uint256 localStartBlock,
        bytes32 localEventId
    )
        private
    {
        vm.createDir("deployments/local", true);
        string memory output = "# Generated by DeployLocal.s.sol for chain 31337 only.\n";
        output = string.concat(output, "LOCAL_PROTOCOL_CHAIN_ID=31337\n");
        output = string.concat(output, _uintLine("LOCAL_PROTOCOL_START_BLOCK", localStartBlock));
        output = string.concat(output, _addressLine("LOCAL_DEPLOYER", DEPLOYER));
        output = string.concat(output, _addressLine("LOCAL_EXECUTOR", EXECUTOR));
        output = string.concat(output, _addressLine("LOCAL_MAKER_A", MAKER_A));
        output = string.concat(output, _addressLine("LOCAL_MAKER_B", MAKER_B));
        output = string.concat(output, _addressLine("LOCAL_TAKER_A", TAKER_A));
        output = string.concat(output, _addressLine("LOCAL_TAKER_B", TAKER_B));
        output = string.concat(output, _bytes32Line("LOCAL_SUBJECT_A", SUBJECT_A));
        output = string.concat(output, _bytes32Line("LOCAL_SUBJECT_B", SUBJECT_B));
        output = string.concat(output, _bytes32Line("LOCAL_EVENT_ID", localEventId));
        output = string.concat(output, _uintLine("LOCAL_EVENT_BOND", EVENT_BOND));
        output = string.concat(output, _uintLine("LOCAL_EVENT_LIVENESS", EVENT_LIVENESS));
        output = string.concat(output, _addressLine("USDC_ADDRESS", deployed.usdc));
        output = string.concat(output, _addressLine("EVENT_MARKET_USDC_ADDRESS", deployed.usdc));
        output = string.concat(output, _addressLine("MATCHED_FILL_SETTLEMENT_TOKEN_ADDRESS", deployed.usdc));
        output = string.concat(output, _addressLine("SUBJECT_REGISTRY_ADDRESS", deployed.subjectRegistry));
        output = string.concat(output, _addressLine("LP_VAULT_ADDRESS", deployed.lpVault));
        output = string.concat(output, _addressLine("MATCHED_FILL_COLLATERAL_SPENDER_ADDRESS", deployed.lpVault));
        output = string.concat(output, _addressLine("PERP_ENGINE_ADDRESS", deployed.perpEngine));
        output = string.concat(output, _addressLine("MARGIN_ENGINE_ADDRESS", deployed.marginEngine));
        output = string.concat(output, _addressLine("MATCHED_FILL_ROUTER_ADDRESS", deployed.matchedFillRouter));
        output = string.concat(output, _addressLine("LOCAL_OPTIMISTIC_ORACLE_ADDRESS", deployed.optimisticOracle));
        output = string.concat(output, _addressLine("UMA_ADAPTER_ADDRESS", deployed.umaAdapter));
        output = string.concat(output, _addressLine("FEEDBACK_CONTROLLER_ADDRESS", deployed.feedbackController));
        output = string.concat(
            output, _addressLine("EVENT_MARKET_IMPLEMENTATION_ADDRESS", deployed.eventMarketImplementation)
        );
        output = string.concat(output, _addressLine("EVENT_MARKET_FACTORY_ADDRESS", deployed.eventMarketFactory));
        output = string.concat(output, _addressLine("EVENT_MARKET_ROUTER_ADDRESS", deployed.eventMarketRouter));
        output = string.concat(output, _uintLine("USDC_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("SUBJECT_REGISTRY_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("LP_VAULT_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("PERP_ENGINE_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("MARGIN_ENGINE_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("MATCHED_FILL_ROUTER_START_BLOCK", localStartBlock));
        // Override start blocks for both deployed and intentionally absent contracts so Ponder
        // never rescans old auto-mined blocks when this generated environment overlays the template.
        output = string.concat(output, _uintLine("ORACLE_ROUTER_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("SIGNED_FEED_ADAPTER_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("FUNDING_ENGINE_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("FEEDBACK_CONTROLLER_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("LIQUIDATION_ENGINE_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("INSURANCE_FUND_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("PAIR_TRADE_ROUTER_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("BATCH_ROUTER_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("PAUSE_GUARDIAN_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("CHAINLINK_ADAPTER_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("UMA_ADAPTER_START_BLOCK", localStartBlock));
        output = string.concat(output, _uintLine("EVENT_MARKET_FACTORY_START_BLOCK", localStartBlock));
        output = string.concat(output, _addressLine("PM_CHAIN__SUBJECT_REGISTRY", deployed.subjectRegistry));
        output = string.concat(output, _addressLine("PM_CHAIN__LP_VAULT", deployed.lpVault));
        output = string.concat(output, _addressLine("PM_CHAIN__PERP_ENGINE", deployed.perpEngine));
        output = string.concat(output, _addressLine("PM_CHAIN__MATCHED_FILL_ROUTER", deployed.matchedFillRouter));
        output = string.concat(output, _addressLine("PM_CHAIN__EVENT_MARKET_FACTORY", deployed.eventMarketFactory));
        output = string.concat(output, _addressLine("PM_CHAIN__EVENT_MARKET_ROUTER", deployed.eventMarketRouter));
        // Standard public Anvil account #5 keeps settlement nonces separate from mark-writer #0.
        output = string.concat(output, _bytes32Line("PM_SIGNER__LOCAL_PRIVATE_KEY", bytes32(executorKey)));
        output = string.concat(output, "MATCHED_FILL_CHAIN_ID=31337\n");
        output = string.concat(output, _addressLine("MATCHED_FILL_EXECUTOR_ADDRESS", EXECUTOR));
        output = string.concat(output, "EVENT_MARKET_CHAIN_ID=31337\n");
        output = string.concat(output, _addressLine("EVENT_MARKET_EXECUTOR_ADDRESS", EXECUTOR));
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

    function _uintLine(string memory key, uint256 value) private pure returns (string memory) {
        return string.concat(key, "=", vm.toString(value), "\n");
    }
}
