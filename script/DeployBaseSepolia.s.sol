// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BatchRouter} from "../src/routers/BatchRouter.sol";
import {FeedbackController} from "../src/feedback/FeedbackController.sol";
import {FundingEngine} from "../src/core/FundingEngine.sol";
import {InsuranceFund} from "../src/core/InsuranceFund.sol";
import {LiquidationEngine} from "../src/core/LiquidationEngine.sol";
import {LPVault} from "../src/core/LPVault.sol";
import {MarginEngine} from "../src/core/MarginEngine.sol";
import {ChainlinkAdapter} from "../src/oracle/ChainlinkAdapter.sol";
import {IOracleRouter} from "../src/oracle/IOracleRouter.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {PairTradeRouter} from "../src/routers/PairTradeRouter.sol";
import {PauseGuardian} from "../src/core/PauseGuardian.sol";
import {PerpEngine} from "../src/core/PerpEngine.sol";
import {SignedFeedAdapter} from "../src/oracle/SignedFeedAdapter.sol";
import {SubjectRegistry} from "../src/registry/SubjectRegistry.sol";
import {IOptimisticOracleV3, UMAAdapter} from "../src/oracle/UMAAdapter.sol";

/// @notice Base Sepolia deployment script for the People Markets core suite.
/// @dev    Assumes you are deploying with the governance key so post-deploy proposals can be
///         submitted. Timelocked activations are not executed here (Base Sepolia time is real).
contract DeployBaseSepolia is Script {
    struct DeployConfig {
        address governance;
        address operator;
        address oracleGovernance;
        address oracleOperator;
        address signedFeedGovernance;
        address signedFeedOperator;
        address insuranceGovernance;
        address usdc;
        address umaOptimisticOracle;
        address subjectAdmin;
        address pauseGuardian;
        address kycWriter;
        uint32 timelockDelay;
        string lpName;
        string lpSymbol;
        address[5] signedFeedSigners;
    }

    struct DeployAddresses {
        address subjectRegistry;
        address oracleRouter;
        address chainlinkAdapter;
        address signedFeedAdapter;
        address umaAdapter;
        address lpVault;
        address insuranceFund;
        address perpEngine;
        address marginEngine;
        address fundingEngine;
        address liquidationEngine;
        address feedbackController;
        address pauseGuardian;
        address pairTradeRouter;
        address batchRouter;
    }

    function run() external returns (DeployAddresses memory deployed) {
        _requireBaseSepolia();

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

        deployed.subjectRegistry = _deploySubjectRegistry(cfg);
        deployed.oracleRouter = _deployOracleRouter(cfg);
        deployed.chainlinkAdapter = _deployChainlinkAdapter(cfg, deployed.oracleRouter);
        deployed.signedFeedAdapter = _deploySignedFeedAdapter(cfg, deployed.oracleRouter);
        deployed.umaAdapter = _deployUMAAdapter(cfg);
        deployed.lpVault = _deployLPVault(cfg);
        deployed.insuranceFund = _deployInsuranceFund(cfg, deployed.lpVault);
        deployed.perpEngine = _deployPerpEngine(cfg, deployed.subjectRegistry, deployed.lpVault);
        deployed.marginEngine = _deployMarginEngine(cfg, deployed.perpEngine);
        deployed.fundingEngine = _deployFundingEngine(cfg, deployed.perpEngine, deployed.oracleRouter);
        deployed.liquidationEngine =
            _deployLiquidationEngine(cfg, deployed.perpEngine, deployed.marginEngine, deployed.lpVault, deployed.insuranceFund);
        deployed.feedbackController = _deployFeedbackController(cfg, deployed.perpEngine, deployed.oracleRouter);
        deployed.pauseGuardian = _deployPauseGuardian(cfg, deployed.perpEngine, deployed.subjectRegistry);
        deployed.pairTradeRouter = _deployPairTradeRouter(cfg, deployed.perpEngine);
        deployed.batchRouter = _deployBatchRouter(cfg, deployed.perpEngine);

        _logNextSteps(cfg, deployed);

        vm.stopBroadcast();
    }

    // ------------------------------------------------------------------------------------------
    // Config
    // ------------------------------------------------------------------------------------------

    function _loadConfig() internal view returns (DeployConfig memory cfg) {
        cfg.governance = vm.envAddress("GOVERNANCE");
        cfg.operator = vm.envAddress("OPERATOR");
        cfg.oracleGovernance = vm.envAddress("ORACLE_GOVERNANCE");
        cfg.oracleOperator = vm.envAddress("ORACLE_OPERATOR");
        cfg.signedFeedGovernance = vm.envAddress("SIGNED_FEED_GOVERNANCE");
        cfg.signedFeedOperator = vm.envAddress("SIGNED_FEED_OPERATOR");
        cfg.insuranceGovernance = vm.envAddress("INSURANCE_GOVERNANCE");
        cfg.usdc = vm.envAddress("USDC");
        cfg.umaOptimisticOracle = vm.envAddress("UMA_OO");
        cfg.subjectAdmin = vm.envAddress("SUBJECT_ADMIN");
        cfg.pauseGuardian = vm.envAddress("PAUSE_GUARDIAN");
        cfg.kycWriter = vm.envAddress("KYC_WRITER");
        cfg.timelockDelay = uint32(vm.envUint("TIMELOCK_DELAY"));
        cfg.lpName = vm.envString("LP_NAME");
        cfg.lpSymbol = vm.envString("LP_SYMBOL");
        cfg.signedFeedSigners[0] = vm.envAddress("SIGNED_FEED_SIGNER_0");
        cfg.signedFeedSigners[1] = vm.envAddress("SIGNED_FEED_SIGNER_1");
        cfg.signedFeedSigners[2] = vm.envAddress("SIGNED_FEED_SIGNER_2");
        cfg.signedFeedSigners[3] = vm.envAddress("SIGNED_FEED_SIGNER_3");
        cfg.signedFeedSigners[4] = vm.envAddress("SIGNED_FEED_SIGNER_4");
    }

    function _requireBaseSepolia() internal view {
        require(block.chainid == 84532, "not base sepolia");
    }

    // ------------------------------------------------------------------------------------------
    // Deploy helpers
    // ------------------------------------------------------------------------------------------

    function _deploySubjectRegistry(DeployConfig memory cfg) internal returns (address proxy) {
        SubjectRegistry impl = new SubjectRegistry();
        address[] memory admins = new address[](1);
        admins[0] = cfg.subjectAdmin;
        address[] memory guardians = new address[](1);
        guardians[0] = cfg.pauseGuardian;
        address[] memory kycWriters = new address[](1);
        kycWriters[0] = cfg.kycWriter;
        bytes memory init = abi.encodeCall(
            SubjectRegistry.initialize,
            (cfg.governance, cfg.timelockDelay, admins, guardians, kycWriters)
        );
        proxy = _deployUUPS(address(impl), init);
        console2.log("SubjectRegistry", proxy);
    }

    function _deployOracleRouter(DeployConfig memory cfg) internal returns (address proxy) {
        OracleRouter impl = new OracleRouter();
        bytes memory init = abi.encodeCall(OracleRouter.initialize, (cfg.oracleGovernance, cfg.oracleOperator, cfg.timelockDelay));
        proxy = _deployUUPS(address(impl), init);
        console2.log("OracleRouter", proxy);
    }

    function _deployChainlinkAdapter(DeployConfig memory cfg, address oracleRouter) internal returns (address proxy) {
        ChainlinkAdapter impl = new ChainlinkAdapter();
        bytes memory init = abi.encodeCall(ChainlinkAdapter.initialize, (IOracleRouter(oracleRouter), cfg.oracleGovernance, cfg.timelockDelay));
        proxy = _deployUUPS(address(impl), init);
        console2.log("ChainlinkAdapter", proxy);
    }

    function _deploySignedFeedAdapter(DeployConfig memory cfg, address oracleRouter) internal returns (address adapter) {
        adapter = address(
            new SignedFeedAdapter(
                IOracleRouter(oracleRouter),
                cfg.signedFeedGovernance,
                cfg.signedFeedOperator,
                cfg.timelockDelay,
                cfg.signedFeedSigners
            )
        );
        console2.log("SignedFeedAdapter", adapter);
    }

    function _deployUMAAdapter(DeployConfig memory cfg) internal returns (address proxy) {
        UMAAdapter impl = new UMAAdapter();
        bytes memory init = abi.encodeCall(UMAAdapter.initialize, (IOptimisticOracleV3(cfg.umaOptimisticOracle), cfg.oracleGovernance, cfg.timelockDelay));
        proxy = _deployUUPS(address(impl), init);
        console2.log("UMAAdapter", proxy);
    }

    function _deployLPVault(DeployConfig memory cfg) internal returns (address proxy) {
        LPVault impl = new LPVault();
        bytes memory init = abi.encodeCall(
            LPVault.initialize,
            (IERC20(cfg.usdc), cfg.governance, cfg.operator, cfg.timelockDelay, cfg.lpName, cfg.lpSymbol)
        );
        proxy = _deployUUPS(address(impl), init);
        console2.log("LPVault", proxy);
    }

    function _deployInsuranceFund(DeployConfig memory cfg, address lpVault) internal returns (address proxy) {
        InsuranceFund impl = new InsuranceFund();
        bytes memory init = abi.encodeCall(InsuranceFund.initialize, (cfg.insuranceGovernance, lpVault, IERC20(cfg.usdc), cfg.timelockDelay));
        proxy = _deployUUPS(address(impl), init);
        console2.log("InsuranceFund", proxy);
    }

    function _deployPerpEngine(DeployConfig memory cfg, address subjectRegistry, address lpVault) internal returns (address proxy) {
        PerpEngine impl = new PerpEngine();
        bytes memory init = abi.encodeCall(PerpEngine.initialize, (cfg.governance, cfg.timelockDelay, subjectRegistry, lpVault));
        proxy = _deployUUPS(address(impl), init);
        console2.log("PerpEngine", proxy);
    }

    function _deployMarginEngine(DeployConfig memory cfg, address perpEngine) internal returns (address proxy) {
        MarginEngine impl = new MarginEngine();
        bytes memory init = abi.encodeCall(MarginEngine.initialize, (cfg.governance, perpEngine, cfg.timelockDelay));
        proxy = _deployUUPS(address(impl), init);
        console2.log("MarginEngine", proxy);
    }

    function _deployFundingEngine(DeployConfig memory cfg, address perpEngine, address oracleRouter) internal returns (address proxy) {
        FundingEngine impl = new FundingEngine();
        bytes memory init = abi.encodeCall(FundingEngine.initialize, (cfg.governance, perpEngine, oracleRouter, cfg.timelockDelay));
        proxy = _deployUUPS(address(impl), init);
        console2.log("FundingEngine", proxy);
    }

    function _deployLiquidationEngine(
        DeployConfig memory cfg,
        address perpEngine,
        address marginEngine,
        address lpVault,
        address insuranceFund
    )
        internal
        returns (address proxy)
    {
        LiquidationEngine impl = new LiquidationEngine();
        bytes memory init = abi.encodeCall(
            LiquidationEngine.initialize,
            (cfg.governance, perpEngine, marginEngine, lpVault, insuranceFund, cfg.timelockDelay)
        );
        proxy = _deployUUPS(address(impl), init);
        console2.log("LiquidationEngine", proxy);
    }

    function _deployFeedbackController(DeployConfig memory cfg, address perpEngine, address oracleRouter)
        internal
        returns (address proxy)
    {
        FeedbackController impl = new FeedbackController();
        bytes memory init = abi.encodeCall(FeedbackController.initialize, (cfg.governance, perpEngine, oracleRouter, cfg.timelockDelay));
        proxy = _deployUUPS(address(impl), init);
        console2.log("FeedbackController", proxy);
    }

    function _deployPauseGuardian(DeployConfig memory cfg, address perpEngine, address subjectRegistry)
        internal
        returns (address proxy)
    {
        PauseGuardian impl = new PauseGuardian();
        bytes memory init = abi.encodeCall(PauseGuardian.initialize, (cfg.governance, perpEngine, subjectRegistry, cfg.timelockDelay));
        proxy = _deployUUPS(address(impl), init);
        console2.log("PauseGuardian", proxy);
    }

    function _deployPairTradeRouter(DeployConfig memory cfg, address perpEngine) internal returns (address proxy) {
        PairTradeRouter impl = new PairTradeRouter();
        bytes memory init = abi.encodeCall(PairTradeRouter.initialize, (cfg.governance, perpEngine, cfg.timelockDelay));
        proxy = _deployUUPS(address(impl), init);
        console2.log("PairTradeRouter", proxy);
    }

    function _deployBatchRouter(DeployConfig memory cfg, address perpEngine) internal returns (address proxy) {
        BatchRouter impl = new BatchRouter();
        bytes memory init = abi.encodeCall(BatchRouter.initialize, (cfg.governance, perpEngine, cfg.timelockDelay));
        proxy = _deployUUPS(address(impl), init);
        console2.log("BatchRouter", proxy);
    }

    function _deployUUPS(address implementation, bytes memory initData) internal returns (address proxy) {
        proxy = address(new ERC1967Proxy(implementation, initData));
    }

    // ------------------------------------------------------------------------------------------
    // Post-deploy guidance
    // ------------------------------------------------------------------------------------------

    function _logNextSteps(DeployConfig memory cfg, DeployAddresses memory deployed) internal view {
        console2.log("--- Next steps (timelocked) ---");
        console2.log("OracleRouter: register metrics with Chainlink/SignedFeed/UMA adapters");
        console2.log("LPVault.proposeSetPerpEngine ->", deployed.perpEngine);
        console2.log("LPVault.proposeSetLiquidationEngine ->", deployed.liquidationEngine);
        console2.log("PerpEngine.proposeSetMarginEngine ->", deployed.marginEngine);
        console2.log("PerpEngine.proposeSetFundingEngine ->", deployed.fundingEngine);
        console2.log("PerpEngine.proposeSetLiquidationEngine ->", deployed.liquidationEngine);
        console2.log("PerpEngine.proposeSetFeedbackController ->", deployed.feedbackController);
        console2.log("PerpEngine.proposeAddRouter ->", deployed.pairTradeRouter);
        console2.log("PerpEngine.proposeAddRouter ->", deployed.batchRouter);
        console2.log("PauseGuardian should be granted SUBJECT_ADMIN + PAUSE_GUARDIAN roles in SubjectRegistry");
        console2.log("InsuranceFund migration: LPVault.migrateInsuranceFund + approveInsuranceFund");
        console2.log("Governance:", cfg.governance);
    }
}
