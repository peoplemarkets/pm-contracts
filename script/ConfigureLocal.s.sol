// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {LPVault} from "../src/core/LPVault.sol";
import {MarginEngine} from "../src/core/MarginEngine.sol";
import {PerpEngine} from "../src/core/PerpEngine.sol";
import {SubjectRegistry} from "../src/registry/SubjectRegistry.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @notice Activate and seed a `DeployLocal` deployment after its one-hour timelock.
/// @dev Idempotent after a successful first run so a local operator can safely re-run the
///      configuration phase to refresh marks or recover from an interrupted command.
contract ConfigureLocal is Script {
    uint256 internal constant ANVIL_DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    bytes32 internal constant CATEGORY_ID = keccak256("music");

    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant LP_DEPOSIT = 1_000_000 * ONE_USDC;
    uint256 internal constant INSURANCE_SEED = 100_000 * ONE_USDC;
    uint256 internal constant ACTOR_BALANCE = 10_000 * ONE_USDC;
    uint256 internal constant INITIAL_MARK = 100e18;

    function run() external {
        require(block.chainid == 31_337, "local configuration requires chain 31337");

        address deployer = vm.envAddress("LOCAL_DEPLOYER");
        address matchedFillRouter = vm.envAddress("MATCHED_FILL_ROUTER_ADDRESS");
        bytes32 subjectA = vm.envBytes32("LOCAL_SUBJECT_A");
        bytes32 subjectB = vm.envBytes32("LOCAL_SUBJECT_B");

        MockUSDC usdc = MockUSDC(vm.envAddress("USDC_ADDRESS"));
        SubjectRegistry registry = SubjectRegistry(vm.envAddress("SUBJECT_REGISTRY_ADDRESS"));
        LPVault vault = LPVault(vm.envAddress("LP_VAULT_ADDRESS"));
        PerpEngine engine = PerpEngine(vm.envAddress("PERP_ENGINE_ADDRESS"));
        MarginEngine margin = MarginEngine(vm.envAddress("MARGIN_ENGINE_ADDRESS"));

        require(vm.addr(ANVIL_DEPLOYER_KEY) == deployer, "unexpected local deployer");

        vm.startBroadcast(ANVIL_DEPLOYER_KEY);

        if (vault.perpEngine() == address(0)) vault.activateSetPerpEngine();
        if (engine.marginEngine() == address(0)) engine.activateSetMarginEngine();
        if (!engine.isRouter(matchedFillRouter)) engine.activateAddRouter(matchedFillRouter);
        if (!engine.isMarkWriter(deployer)) engine.activateAddMarkWriter(deployer);

        if (registry.subjectOf(subjectA).listedAt == 0) registry.listSubject(subjectA, CATEGORY_ID);
        if (registry.subjectOf(subjectB).listedAt == 0) registry.listSubject(subjectB, CATEGORY_ID);

        _setKycIfNeeded(registry, vm.envAddress("LOCAL_MAKER_A"));
        _setKycIfNeeded(registry, vm.envAddress("LOCAL_MAKER_B"));
        _setKycIfNeeded(registry, vm.envAddress("LOCAL_TAKER_A"));
        _setKycIfNeeded(registry, vm.envAddress("LOCAL_TAKER_B"));
        margin.setKycCaps(2, 250_000 * ONE_USDC, 1_000_000 * ONE_USDC);

        uint256 deployerRequired = LP_DEPOSIT + INSURANCE_SEED;
        uint256 deployerBalance = usdc.balanceOf(deployer);
        if (deployerBalance < deployerRequired) usdc.mint(deployer, deployerRequired - deployerBalance);
        require(usdc.approve(address(vault), type(uint256).max), "local vault approval failed");
        if (vault.insuranceFundBalance() == 0) vault.seedInsurance(INSURANCE_SEED);
        if (vault.totalSupply() == 0) {
            uint256 shares = vault.deposit(LP_DEPOSIT, deployer);
            require(shares != 0, "local LP deposit minted no shares");
        }

        _fundActor(usdc, vm.envAddress("LOCAL_MAKER_A"));
        _fundActor(usdc, vm.envAddress("LOCAL_MAKER_B"));
        _fundActor(usdc, vm.envAddress("LOCAL_TAKER_A"));
        _fundActor(usdc, vm.envAddress("LOCAL_TAKER_B"));

        (uint256 cappedTvl, uint64 cappedTvlUpdatedAt) = engine.cappedTvl();
        if (cappedTvlUpdatedAt == 0) engine.pokeCappedTvl();
        engine.pushMark(subjectA, INITIAL_MARK);
        engine.pushMark(subjectB, INITIAL_MARK);

        vm.stopBroadcast();

        require(vault.perpEngine() == address(engine), "vault/engine link missing");
        require(engine.marginEngine() == address(margin), "margin link missing");
        require(engine.isRouter(matchedFillRouter), "matched router not trusted");
        require(engine.isMarkWriter(deployer), "local mark writer missing");
        require(registry.isTradeable(subjectA) && registry.isTradeable(subjectB), "subjects not tradeable");
        (cappedTvl, cappedTvlUpdatedAt) = engine.cappedTvl();
        require(cappedTvl != 0, "local capped TVL not seeded");
        require(cappedTvlUpdatedAt != 0, "local capped TVL timestamp missing");

        console2.log("Local protocol configured and seeded.");
        console2.log("Subject A", vm.toString(subjectA));
        console2.log("Subject B", vm.toString(subjectB));
    }

    function _setKycIfNeeded(SubjectRegistry registry, address actor) private {
        if (registry.kycTierOf(actor) != 2) registry.setKycTier(actor, 2);
    }

    function _fundActor(MockUSDC usdc, address actor) private {
        uint256 balance = usdc.balanceOf(actor);
        if (balance < ACTOR_BALANCE) usdc.mint(actor, ACTOR_BALANCE - balance);
    }
}
