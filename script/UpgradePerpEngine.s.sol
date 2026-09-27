// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILPVault} from "../src/core/ILPVault.sol";
import {IPerpEngine} from "../src/core/IPerpEngine.sol";
import {PerpEngine} from "../src/core/PerpEngine.sol";

/// @title  UpgradePerpEngine - UUPS upgrade ceremony for a LIVE PerpEngine proxy (Base / Base Sepolia).
///
/// @notice PerpEngine DELEGATECALLs the public `PerpInternals` library, so an upgrade is two
///         deployments (library, then an implementation linked to that exact library) plus one
///         governance transaction. On Base mainnet governance is the Safe, so this script never
///         sends the upgrade itself there: it simulates it on a fork and prints the Safe payload.
///         Runbook: script/DEPLOYMENT.md "Upgrading an existing PerpEngine proxy".
///
/// @dev    ZERO-POSITION GATE. This release removed the legacy opening-notional fallback: a
///         position opened before `positionOpeningNotional` existed would release no OI when it
///         closes. Every phase that can lead to, or follows, an upgrade therefore requires:
///           - LPVault.positionCollateral() == 0 (every open perp position locks > 0 collateral), and
///           - either PerpStorage.nextPositionNonce == 0 (no position was ever opened), or
///             openInterestOf(subject) == (0, 0) for every subject in SUBJECT_IDS (non-empty).
///         If the gate fails, STOP: the upgrade is not safe for the live positions.
///
/// @dev    BYTECODE IDENTITY. The library and implementation are compared byte-for-byte with this
///         commit's `out/` artifacts. Only link references (which must hold PERP_INTERNALS_LIBRARY)
///         and immutables (which must hold the contract's own address: UUPS `__self` and the
///         via-IR library call guard) may differ. Run every phase from the reviewed commit with the
///         default profile so the artifacts match what is deployed.
///
/// @dev    Phases:
///           preflight()              - read-only: chain, zero-position gate, wiring snapshot.
///           DeployPerpInternals      - BROADCAST (deployer): separate contract in this file; deploys
///                                      PerpInternals from its artifact.
///           deployImplementation()   - BROADCAST (deployer): `new PerpEngine()`. Must be run with
///                                      `--libraries src/libraries/PerpInternals.sol:PerpInternals:$PERP_INTERNALS_LIBRARY`.
///           simulateUpgrade()        - fork simulation of governance upgradeToAndCall(impl, "") with
///                                      money-safety asserts; prints the Safe transaction.
///           simulateCeremony()       - fork simulation of the whole sequence with a freshly built
///                                      implementation and a simulated library.
///           upgradeWithKey()         - BROADCAST (EOA governance only, e.g. Base Sepolia). Refuses
///                                      when governance is a contract (use the Safe payload instead).
///           verify()                 - read-only, after the governance transaction executed.
///         Read-only and simulation phases refuse `--broadcast`.
///
/// @dev    Env:
///           PERP_ENGINE              - PerpEngine proxy.
///           SUBJECT_IDS              - comma-separated bytes32 subject ids (every subject that was
///                                      ever listed or traded). Optional only while no position was
///                                      ever opened (nextPositionNonce == 0).
///           PERP_INTERNALS_LIBRARY   - deployed library (deployImplementation / simulateUpgrade /
///                                      upgradeWithKey / verify).
///           NEW_PERP_ENGINE_IMPL     - deployed implementation (simulateUpgrade / upgradeWithKey / verify).
///           ROUTER_CANDIDATES        - comma-separated keys that must not be (or become) routers when
///                                      they have no code: operator, mark writers, KYC writer, deployers.
///           DEPLOYER_PK / PRIVATE_KEY- broadcaster for the BROADCAST phases (else forge --account/--sender).
abstract contract PerpEngineUpgradeChecks is Script {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev keccak256("people.markets.perp.v1"): PerpStorage.Layout root (src/libraries/StorageLib.sol).
    bytes32 internal constant PERP_STORAGE_SLOT = keccak256("people.markets.perp.v1");
    /// @dev Layout member 6 is `nextPositionNonce`; member 9 packs `globalHalt` (byte 0) and
    ///      `markStaleAfter` (bytes 1-4). Member 9 is cross-checked against the getters so a layout
    ///      drift makes the nonce read fail loudly instead of reading the wrong slot.
    uint256 internal constant NONCE_MEMBER = 6;
    uint256 internal constant HALT_STALE_MEMBER = 9;
    string internal constant LIBRARY_ARTIFACT = "PerpInternals.sol:PerpInternals";
    /// @dev Arbitrary non-router caller for the post-upgrade surface probe.
    address internal constant SURFACE_PROBE = address(uint160(uint256(keccak256("UpgradePerpEngine.surfaceProbe"))));
    string internal constant LIBRARY_ARTIFACT_JSON = "/out/PerpInternals.sol/PerpInternals.json";
    string internal constant ENGINE_ARTIFACT_JSON = "/out/PerpEngine.sol/PerpEngine.json";

    struct Snapshot {
        address implementation;
        address governance;
        uint32 timelockDelay;
        address lpVault;
        address subjectRegistry;
        address marginEngine;
        address fundingEngine;
        address feedbackController;
        address liquidationEngine;
        uint32 markStaleAfter;
        uint8 lpRebatePct;
        uint16 markMaxDeltaBps;
        bool globalHalt;
        uint256 nextPositionNonce;
        uint256 positionCollateral;
        uint256 vaultUsdc;
        uint256 totalAssets;
        uint256[] marks;
        uint256[] longOi;
        uint256[] shortOi;
    }

    /// @dev forge-std decodes JSON objects with keys in alphabetical order.
    struct ArtifactRef {
        uint256 length;
        uint256 start;
    }

    // ------------------------------------------------------------------------------------------
    // Checks
    // ------------------------------------------------------------------------------------------

    function _simulateAndCheck(PerpEngine engine, address impl) internal {
        Snapshot memory before = _snapshot(engine);
        _requireZeroPositions(before);
        _requireNoEoaRouters(engine);
        vm.prank(before.governance);
        UUPSUpgradeable(address(engine)).upgradeToAndCall(impl, "");
        _checkAfter(engine, before, impl);
        console2.log("SIMULATION PASSED: upgrade preserves wiring, parameters, vault balances and zero OI");
    }

    function _checkAfter(PerpEngine engine, Snapshot memory before, address impl) internal {
        Snapshot memory afterSnap = _snapshot(engine);
        require(afterSnap.implementation == impl, "UPGRADE FAIL: implementation slot");
        require(afterSnap.governance == before.governance, "UPGRADE FAIL: governance changed");
        require(afterSnap.timelockDelay == before.timelockDelay, "UPGRADE FAIL: timelock changed");
        require(afterSnap.lpVault == before.lpVault, "UPGRADE FAIL: lpVault changed");
        require(afterSnap.subjectRegistry == before.subjectRegistry, "UPGRADE FAIL: registry changed");
        require(afterSnap.marginEngine == before.marginEngine, "UPGRADE FAIL: marginEngine changed");
        require(afterSnap.fundingEngine == before.fundingEngine, "UPGRADE FAIL: fundingEngine changed");
        require(afterSnap.feedbackController == before.feedbackController, "UPGRADE FAIL: feedback changed");
        require(afterSnap.liquidationEngine == before.liquidationEngine, "UPGRADE FAIL: liquidation changed");
        require(afterSnap.markStaleAfter == before.markStaleAfter, "UPGRADE FAIL: markStaleAfter changed");
        require(afterSnap.lpRebatePct == before.lpRebatePct, "UPGRADE FAIL: lpRebatePct changed");
        require(afterSnap.markMaxDeltaBps == before.markMaxDeltaBps, "UPGRADE FAIL: markMaxDeltaBps changed");
        require(afterSnap.globalHalt == before.globalHalt, "UPGRADE FAIL: globalHalt changed");
        require(afterSnap.nextPositionNonce == before.nextPositionNonce, "UPGRADE FAIL: position nonce changed");
        require(afterSnap.positionCollateral == before.positionCollateral, "MONEY-SAFETY FAIL: positionCollateral");
        require(afterSnap.vaultUsdc == before.vaultUsdc, "MONEY-SAFETY FAIL: vault USDC balance moved");
        require(afterSnap.totalAssets == before.totalAssets, "MONEY-SAFETY FAIL: totalAssets changed");
        for (uint256 i; i < before.marks.length; ++i) {
            require(afterSnap.marks[i] == before.marks[i], "UPGRADE FAIL: mark changed");
            require(afterSnap.longOi[i] == before.longOi[i], "UPGRADE FAIL: long OI changed");
            require(afterSnap.shortOi[i] == before.shortOi[i], "UPGRADE FAIL: short OI changed");
        }
        _requireZeroPositions(afterSnap);
        _requireNewSurface(engine);
    }

    /// @dev The upgraded implementation exposes the matched-fill entrypoints behind `onlyRouter`.
    ///      A pranked call from SURFACE_PROBE (never a router) must revert with exactly `OnlyRouter`; the
    ///      previous implementation has no such selector and reverts without that data.
    function _requireNewSurface(PerpEngine engine) internal {
        IPerpEngine.MatchedCloseParams memory p;
        vm.prank(SURFACE_PROBE);
        (bool ok, bytes memory ret) =
            address(engine).call(abi.encodeCall(IPerpEngine.closePositionForMatched, (SURFACE_PROBE, p)));
        require(!ok, "UPGRADE FAIL: matched close did not revert for a non-router");
        require(
            keccak256(ret) == keccak256(abi.encodeWithSelector(IPerpEngine.OnlyRouter.selector, SURFACE_PROBE)),
            "UPGRADE FAIL: matched-fill surface missing"
        );
    }

    function _requireZeroPositions(Snapshot memory snap) internal pure {
        require(snap.positionCollateral == 0, "ZERO-POSITION GATE FAIL: LPVault.positionCollateral != 0");
        if (snap.nextPositionNonce == 0) return; // no position was ever opened on this engine
        require(snap.longOi.length != 0, "ZERO-POSITION GATE FAIL: positions were opened; set SUBJECT_IDS");
        for (uint256 i; i < snap.longOi.length; ++i) {
            require(snap.longOi[i] == 0 && snap.shortOi[i] == 0, "ZERO-POSITION GATE FAIL: open interest");
        }
    }

    /// @dev After this upgrade a router may call `openPositionForMatched` /
    ///      `closePositionForMatched` for ANY trader at a caller-chosen execution price (bounded
    ///      only by the caller-chosen `maxMarkDivergenceBps`, up to 100% of mark), spending that
    ///      trader's LPVault allowance. Only contracts that verify trader signatures (the
    ///      MatchedFillRouter) may hold the role. Every ROUTER_CANDIDATES address without code
    ///      (operator, mark writers, KYC writer, deployer keys) must be neither a router nor pending.
    function _requireNoEoaRouters(PerpEngine engine) internal view {
        address[] memory candidates = vm.envOr("ROUTER_CANDIDATES", ",", new address[](0));
        for (uint256 i; i < candidates.length; ++i) {
            if (candidates[i].code.length != 0) continue;
            if (engine.isRouter(candidates[i]) || engine.pendingRouterActivatesAt(candidates[i]) != 0) {
                console2.log("EOA router or pending router:", candidates[i]);
                revert("ROUTER GATE FAIL: removeRouter / cancelAddRouter every EOA before upgrading");
            }
        }
        console2.log("router gate: EOA candidates checked:", candidates.length);
    }

    function _snapshot(PerpEngine engine) internal view returns (Snapshot memory snap) {
        snap.implementation = _implementationOf(address(engine));
        snap.governance = engine.governance();
        snap.timelockDelay = engine.timelockDelay();
        snap.lpVault = engine.lpVault();
        snap.subjectRegistry = engine.subjectRegistry();
        snap.marginEngine = engine.marginEngine();
        snap.fundingEngine = engine.fundingEngine();
        snap.feedbackController = engine.feedbackController();
        snap.liquidationEngine = engine.liquidationEngine();
        snap.markStaleAfter = engine.markStaleAfter();
        snap.lpRebatePct = engine.lpRebatePct();
        snap.markMaxDeltaBps = engine.markMaxDeltaBps();
        snap.globalHalt = engine.globalHalt();
        snap.nextPositionNonce = _nextPositionNonce(address(engine), snap.globalHalt, snap.markStaleAfter);
        ILPVault vault = ILPVault(snap.lpVault);
        snap.positionCollateral = vault.positionCollateral();
        snap.vaultUsdc = IERC20(vault.asset()).balanceOf(address(vault));
        snap.totalAssets = vault.totalAssets();
        bytes32[] memory subjects = _subjects();
        snap.marks = new uint256[](subjects.length);
        snap.longOi = new uint256[](subjects.length);
        snap.shortOi = new uint256[](subjects.length);
        for (uint256 i; i < subjects.length; ++i) {
            (snap.marks[i],) = engine.markOf(subjects[i]);
            (snap.longOi[i], snap.shortOi[i]) = engine.openInterestOf(subjects[i]);
            if (snap.longOi[i] != 0 || snap.shortOi[i] != 0) {
                console2.log("non-zero OI on subject (long, short):", snap.longOi[i], snap.shortOi[i]);
                console2.logBytes32(subjects[i]);
            }
        }
    }

    function _nextPositionNonce(address engine, bool halt, uint32 staleAfter) internal view returns (uint256) {
        uint256 packed = uint256(vm.load(engine, bytes32(uint256(PERP_STORAGE_SLOT) + HALT_STALE_MEMBER)));
        require(
            (packed & 0xff) == (halt ? 1 : 0) && uint32(packed >> 8) == staleAfter,
            "PerpStorage layout mismatch: cannot read nextPositionNonce"
        );
        return uint256(vm.load(engine, bytes32(uint256(PERP_STORAGE_SLOT) + NONCE_MEMBER)));
    }

    function _printGovernancePayload(PerpEngine engine, address impl) internal pure {
        bytes memory data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impl, ""));
        console2.log("--------------------------------------");
        console2.log("Governance transaction (Safe: operation CALL, value 0):");
        console2.log("  to   :", address(engine));
        console2.log("  data :");
        console2.logBytes(data);
        console2.log("Sign and execute only after preflight() passes again with globalHalt set.");
    }

    // ------------------------------------------------------------------------------------------
    // Bytecode identity
    // ------------------------------------------------------------------------------------------

    /// @dev `impl` is this commit's PerpEngine linked to `library_`, and `library_` is this commit's
    ///      PerpInternals.
    function _requireReleaseBytecode(address impl, address library_) internal view {
        _requireArtifactMatch(library_, LIBRARY_ARTIFACT_JSON, address(0));
        _requireArtifactMatch(impl, ENGINE_ARTIFACT_JSON, library_);
    }

    function _linkedLibrary(address impl) internal view returns (address) {
        ArtifactRef[] memory links = _linkRefs(vm.readFile(string.concat(vm.projectRoot(), ENGINE_ARTIFACT_JSON)));
        return address(bytes20(_slice(impl.code, links[0].start, 20)));
    }

    /// @dev Byte-for-byte comparison of `target.code` with the artifact's `deployedBytecode`,
    ///      except link references (must equal `linkedLibrary`) and immutables (must equal
    ///      `target` itself). Fails closed on any other difference, length mismatch or missing code.
    function _requireArtifactMatch(address target, string memory artifactJson, address linkedLibrary) internal view {
        bytes memory live = target.code;
        require(live.length != 0, "bytecode check: target has no code");
        string memory json = vm.readFile(string.concat(vm.projectRoot(), artifactJson));
        bytes memory expectedHex = bytes(vm.parseJsonString(json, ".deployedBytecode.object"));
        require(expectedHex.length == 2 + 2 * live.length, "bytecode check: runtime length differs from artifact");
        bool[] memory masked = new bool[](live.length);

        ArtifactRef[] memory links = _linkRefs(json);
        require((links.length == 0) == (linkedLibrary == address(0)), "bytecode check: unexpected link references");
        for (uint256 i; i < links.length; ++i) {
            require(links[i].length == 20, "bytecode check: link length");
            require(
                address(bytes20(_slice(live, links[i].start, 20))) == linkedLibrary,
                "bytecode check: implementation links a different PerpInternals"
            );
            _mask(masked, links[i]);
        }

        string[] memory immutableIds = vm.parseJsonKeys(json, ".deployedBytecode.immutableReferences");
        for (uint256 k; k < immutableIds.length; ++k) {
            ArtifactRef[] memory refs = abi.decode(
                vm.parseJson(json, string.concat(".deployedBytecode.immutableReferences['", immutableIds[k], "']")),
                (ArtifactRef[])
            );
            for (uint256 i; i < refs.length; ++i) {
                require(refs[i].length == 32, "bytecode check: immutable length");
                require(
                    bytes32(_slice(live, refs[i].start, 32)) == bytes32(uint256(uint160(target))),
                    "bytecode check: immutable is not the contract's own address"
                );
                _mask(masked, refs[i]);
            }
        }

        for (uint256 i; i < live.length; ++i) {
            if (masked[i]) continue;
            uint8 b = uint8(live[i]);
            require(
                _hexNibble(expectedHex[2 + 2 * i]) == b >> 4 && _hexNibble(expectedHex[3 + 2 * i]) == b & 0x0f,
                "bytecode check: runtime differs from this commit's artifact"
            );
        }
    }

    function _linkRefs(string memory json) internal pure returns (ArtifactRef[] memory refs) {
        string[] memory files = vm.parseJsonKeys(json, ".deployedBytecode.linkReferences");
        if (files.length == 0) return refs;
        require(
            files.length == 1 && keccak256(bytes(files[0])) == keccak256("src/libraries/PerpInternals.sol"),
            "bytecode check: unexpected linked library file"
        );
        string[] memory libs =
            vm.parseJsonKeys(json, string.concat(".deployedBytecode.linkReferences['", files[0], "']"));
        require(libs.length == 1 && keccak256(bytes(libs[0])) == keccak256("PerpInternals"), "unexpected library");
        refs = abi.decode(
            vm.parseJson(json, string.concat(".deployedBytecode.linkReferences['", files[0], "'].PerpInternals")),
            (ArtifactRef[])
        );
        require(refs.length != 0, "bytecode check: no PerpInternals link reference");
    }

    function _mask(bool[] memory masked, ArtifactRef memory ref) internal pure {
        for (uint256 j; j < ref.length; ++j) {
            masked[ref.start + j] = true;
        }
    }

    function _slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory out) {
        require(start + length <= data.length, "bytecode check: reference out of range");
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = data[start + i];
        }
    }

    function _hexNibble(bytes1 c) internal pure returns (uint8) {
        uint8 x = uint8(c);
        if (x >= 0x30 && x <= 0x39) return x - 0x30;
        if (x >= 0x61 && x <= 0x66) return x - 0x57;
        if (x >= 0x41 && x <= 0x46) return x - 0x37;
        revert("bytecode check: unlinked or non-hex artifact byte");
    }

    // ------------------------------------------------------------------------------------------
    // Env / guards
    // ------------------------------------------------------------------------------------------

    function _engine() internal view returns (PerpEngine engine) {
        engine = PerpEngine(vm.envAddress("PERP_ENGINE"));
        require(address(engine).code.length != 0, "PERP_ENGINE has no code");
    }

    function _subjects() internal view returns (bytes32[] memory) {
        return vm.envOr("SUBJECT_IDS", ",", new bytes32[](0));
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _requireBaseChain() internal view {
        require(block.chainid == 8453 || block.chainid == 84_532, "UpgradePerpEngine: Base or Base Sepolia only");
    }

    function _requireNotBroadcast() internal view {
        require(
            !vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && !vm.isContext(VmSafe.ForgeContext.ScriptResume),
            "read-only/simulation phase: run without --broadcast"
        );
    }

    function _beginBroadcast() internal {
        uint256 key = vm.envOr("DEPLOYER_PK", uint256(0));
        if (key == 0) key = vm.envOr("PRIVATE_KEY", uint256(0));
        if (key == 0) vm.startBroadcast();
        else vm.startBroadcast(key);
    }
}

/// @notice Phases that link or read the upgrade. See the file header.
contract UpgradePerpEngine is PerpEngineUpgradeChecks {
    // ------------------------------------------------------------------------------------------
    // Read-only phases
    // ------------------------------------------------------------------------------------------

    function run() external view returns (Snapshot memory snap) {
        return preflight();
    }

    function preflight() public view returns (Snapshot memory snap) {
        _requireNotBroadcast();
        _requireBaseChain();
        PerpEngine engine = _engine();
        snap = _snapshot(engine);
        console2.log("=== UpgradePerpEngine: PREFLIGHT ===");
        console2.log("chain id              :", block.chainid);
        console2.log("block                 :", block.number);
        console2.log("PerpEngine proxy      :", address(engine));
        console2.log("current implementation:", snap.implementation);
        console2.log("governance            :", snap.governance);
        console2.log("governance is contract:", snap.governance.code.length != 0);
        console2.log("globalHalt            :", snap.globalHalt);
        console2.log("LPVault               :", snap.lpVault);
        console2.log("positionCollateral    :", snap.positionCollateral);
        console2.log("nextPositionNonce     :", snap.nextPositionNonce);
        _requireZeroPositions(snap);
        console2.log("ZERO-POSITION GATE PASSED; subjects checked:", snap.longOi.length);
        _requireNoEoaRouters(engine);
    }

    /// @notice Fork-simulates the governance upgrade to NEW_PERP_ENGINE_IMPL and prints the exact
    ///         transaction governance must execute. Never broadcasts.
    function simulateUpgrade() external {
        _requireNotBroadcast();
        _requireBaseChain();
        PerpEngine engine = _engine();
        address impl = vm.envAddress("NEW_PERP_ENGINE_IMPL");
        _requireReleaseBytecode(impl, vm.envAddress("PERP_INTERNALS_LIBRARY"));
        _simulateAndCheck(engine, impl);
        _printGovernancePayload(engine, impl);
    }

    /// @notice Whole ceremony against a fork with a freshly compiled implementation. Forge links a
    ///         simulated PerpInternals deployment; both are checked against this commit's artifacts.
    ///         Never broadcasts.
    function simulateCeremony() external {
        _requireNotBroadcast();
        _requireBaseChain();
        PerpEngine engine = _engine();
        address impl = address(new PerpEngine());
        address library_ = _linkedLibrary(impl);
        console2.log("simulated PerpInternals :", library_);
        console2.log("simulated implementation:", impl);
        _requireReleaseBytecode(impl, library_);
        _simulateAndCheck(engine, impl);
    }

    /// @notice Post-execution verification after governance executed the upgrade on chain.
    function verify() external {
        _requireNotBroadcast();
        _requireBaseChain();
        PerpEngine engine = _engine();
        address impl = vm.envAddress("NEW_PERP_ENGINE_IMPL");
        require(
            _implementationOf(address(engine)) == impl, "VERIFY FAIL: implementation slot is not NEW_PERP_ENGINE_IMPL"
        );
        _requireReleaseBytecode(impl, vm.envAddress("PERP_INTERNALS_LIBRARY"));
        _requireZeroPositions(_snapshot(engine));
        _requireNoEoaRouters(engine);
        _requireNewSurface(engine);
        console2.log("VERIFY PASSED: implementation + library bytecode, zero positions, matched-fill surface");
    }

    // ------------------------------------------------------------------------------------------
    // Broadcast phases
    // ------------------------------------------------------------------------------------------

    function deployImplementation() external returns (address impl) {
        _requireBaseChain();
        address library_ = vm.envAddress("PERP_INTERNALS_LIBRARY");
        _requireArtifactMatch(library_, LIBRARY_ARTIFACT_JSON, address(0));
        _beginBroadcast();
        impl = address(new PerpEngine());
        vm.stopBroadcast();
        // Runs in forge's local simulation before anything is sent: without the matching
        // `--libraries` flag the implementation links a different library and this reverts.
        _requireReleaseBytecode(impl, library_);
        console2.log("PerpEngine implementation:", impl);
        console2.log("export NEW_PERP_ENGINE_IMPL=", impl);
    }

    /// @notice Direct upgrade for an EOA governance (testnet). Mainnet governance is the Safe.
    function upgradeWithKey() external {
        _requireBaseChain();
        PerpEngine engine = _engine();
        address impl = vm.envAddress("NEW_PERP_ENGINE_IMPL");
        _requireReleaseBytecode(impl, vm.envAddress("PERP_INTERNALS_LIBRARY"));
        Snapshot memory before = _snapshot(engine);
        require(before.governance.code.length == 0, "governance is a contract: execute the Safe payload instead");
        _requireZeroPositions(before);
        _requireNoEoaRouters(engine);

        _beginBroadcast();
        UUPSUpgradeable(address(engine)).upgradeToAndCall(impl, "");
        vm.stopBroadcast();

        _checkAfter(engine, before, impl);
    }
}

/// @notice Deploys PerpInternals from this commit's artifact. Kept in its own contract so the
///         script bytecode has no PerpInternals link reference: forge would otherwise auto-deploy
///         (and, under --broadcast, send) an extra library alongside this one.
contract DeployPerpInternals is PerpEngineUpgradeChecks {
    function run() external returns (address library_) {
        return deployLibrary();
    }

    function deployLibrary() public returns (address library_) {
        _requireBaseChain();
        bytes memory initCode = vm.getCode(LIBRARY_ARTIFACT);
        _beginBroadcast();
        assembly ("memory-safe") {
            library_ := create(0, add(initCode, 0x20), mload(initCode))
        }
        vm.stopBroadcast();
        require(library_ != address(0), "library deployment failed");
        _requireArtifactMatch(library_, LIBRARY_ARTIFACT_JSON, address(0));
        console2.log("PerpInternals library:", library_);
        console2.log("export PERP_INTERNALS_LIBRARY=", library_);
    }
}
