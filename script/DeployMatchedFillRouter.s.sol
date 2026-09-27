// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IPerpEngine} from "../src/core/IPerpEngine.sol";
import {MatchedFillRouter} from "../src/routers/MatchedFillRouter.sol";

/// @notice Deploys the MatchedFillRouter (implementation + ERC1967 proxy) against a LIVE PerpEngine
///         proxy on Base mainnet (8453) or Base Sepolia (84532).
/// @dev    The deployer key holds no role afterwards: `GOVERNANCE` (the Safe on mainnet) owns the
///         router from initialization and must equal the PerpEngine governance.
///
///         Registration is NOT done here. Governance must, AFTER the PerpEngine proxy runs an
///         implementation with `openPositionForMatched` / `closePositionForMatched`
///         (script/UpgradePerpEngine.s.sol), execute:
///           1. PerpEngine.proposeAddRouter(router)   (onlyGovernance, starts the timelock)
///           2. PerpEngine.activateAddRouter(router)  (after PerpEngine.timelockDelay)
///         The matching-engine executor is not stored on chain: every signed order names it.
///
///         Env: GOVERNANCE, PERP_ENGINE, TIMELOCK_DELAY (seconds, [3600, 30 days]),
///              DEPLOYER_PK or PRIVATE_KEY (optional; otherwise forge's --sender/--account).
///         Use a fresh deployer key on mainnet: the previous mainnet deployer key is retired
///         (docs/MAINNET_EVENTS_DEPLOY.md). Run once without --broadcast first; the simulation
///         refuses an engine that has not been upgraded yet.
contract DeployMatchedFillRouter is Script {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address internal constant SURFACE_PROBE =
        address(uint160(uint256(keccak256("DeployMatchedFillRouter.surfaceProbe"))));

    struct Deployed {
        address implementation;
        address proxy;
    }

    function run() external returns (Deployed memory deployed) {
        require(block.chainid == 8453 || block.chainid == 84_532, "DeployMatchedFillRouter: Base or Base Sepolia only");
        address governance = vm.envAddress("GOVERNANCE");
        address perpEngine = vm.envAddress("PERP_ENGINE");
        uint32 timelockDelay = uint32(vm.envUint("TIMELOCK_DELAY"));
        require(governance != address(0), "GOVERNANCE unset");
        require(perpEngine.code.length != 0, "PERP_ENGINE has no code");
        require(IPerpEngine(perpEngine).governance() == governance, "GOVERNANCE must equal the PerpEngine governance");
        _requireMatchedSurface(perpEngine);

        uint256 key = vm.envOr("DEPLOYER_PK", uint256(0));
        if (key == 0) key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) vm.startBroadcast();
        else vm.startBroadcast(key);

        MatchedFillRouter implementation = new MatchedFillRouter();
        bytes memory initData = abi.encodeCall(MatchedFillRouter.initialize, (governance, perpEngine, timelockDelay));
        deployed.proxy = address(new ERC1967Proxy(address(implementation), initData));
        deployed.implementation = address(implementation);

        vm.stopBroadcast();

        _verify(deployed, governance, perpEngine, timelockDelay);
        _logNextSteps(deployed, perpEngine);
    }

    /// @dev The router only calls `openPositionForMatched` / `closePositionForMatched`. Refuse to
    ///      deploy against an engine that does not expose them yet (i.e. before the PerpEngine
    ///      upgrade): a pranked non-router call must revert with exactly `OnlyRouter(probe)`.
    ///      This runs in forge's local simulation and is never broadcast.
    function _requireMatchedSurface(address perpEngine) internal {
        IPerpEngine.MatchedCloseParams memory p;
        vm.prank(SURFACE_PROBE);
        (bool ok, bytes memory ret) =
            perpEngine.call(abi.encodeCall(IPerpEngine.closePositionForMatched, (SURFACE_PROBE, p)));
        require(
            !ok && keccak256(ret) == keccak256(abi.encodeWithSelector(IPerpEngine.OnlyRouter.selector, SURFACE_PROBE)),
            "PERP_ENGINE has no matched-fill surface: upgrade PerpEngine first (script/UpgradePerpEngine.s.sol)"
        );
    }

    function _verify(Deployed memory deployed, address governance, address perpEngine, uint32 delay) internal view {
        MatchedFillRouter router = MatchedFillRouter(deployed.proxy);
        require(
            address(uint160(uint256(vm.load(deployed.proxy, IMPLEMENTATION_SLOT)))) == deployed.implementation,
            "router implementation slot mismatch"
        );
        require(router.governance() == governance, "router governance mismatch");
        require(router.perpEngine() == perpEngine, "router perpEngine mismatch");
        require(router.timelockDelay() == delay, "router timelock mismatch");
        (address pendingGovernance, uint64 pendingAt) = router.pendingGovernance();
        require(pendingGovernance == address(0) && pendingAt == 0, "router has a pending governance transfer");
        bytes32 expectedDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PeopleMarketsMatchedOrders"),
                keccak256("2"),
                block.chainid,
                deployed.proxy
            )
        );
        require(router.domainSeparator() == expectedDomain, "router EIP-712 domain mismatch");
    }

    function _logNextSteps(Deployed memory deployed, address perpEngine) internal pure {
        console2.log("MatchedFillRouter implementation:", deployed.implementation);
        console2.log("MatchedFillRouter proxy         :", deployed.proxy);
        console2.log("--------------------------------------");
        console2.log("Governance next steps (only after the PerpEngine upgrade is live):");
        console2.log("  1. PerpEngine.proposeAddRouter(router) on", perpEngine);
        console2.logBytes(abi.encodeWithSignature("proposeAddRouter(address)", deployed.proxy));
        console2.log("  2. after PerpEngine.timelockDelay: activateAddRouter(router)");
        console2.logBytes(abi.encodeWithSignature("activateAddRouter(address)", deployed.proxy));
        console2.log("Record the proxy address and its deployment block for the API/indexer config.");
    }
}
