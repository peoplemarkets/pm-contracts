// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILPVault} from "../src/core/ILPVault.sol";
import {IFeedbackController} from "../src/feedback/IFeedbackController.sol";
import {EventMarketFactory} from "../src/events/EventMarketFactory.sol";
import {LMSRMath} from "../src/events/LMSRMath.sol";
import {UMAAdapter} from "../src/oracle/UMAAdapter.sol";

import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockOptimisticOracleV3} from "../test/mocks/MockOptimisticOracleV3.sol";
import {TestEventMarket} from "../test/mocks/TestEventMarket.sol";
import {TestEventVault} from "../test/mocks/TestEventVault.sol";
import {MockFeedbackController} from "../test/events/mocks/MockEventDeps.sol";

/// @title  DeployWorldCupTest — stand up a FRESH, ISOLATED, play-money event-market stack.
/// @notice TEST-ONLY. Deploys a self-contained World-Cup event-market stack on Base Sepolia:
///         open-mint MockUSDC, a MockOptimisticOracleV3 wired behind a real UMAAdapter, a minimal
///         factory-gated seed vault (TestEventVault), and an EventMarketFactory (behind a proxy)
///         whose market implementation is TestEventMarket (governance one-call resolve). It seeds
///         the vault, then creates one market per World-Cup outcome. NOTHING here touches the live
///         perp deployment, and there is ZERO timelock friction (factory timelock = 0, resolve is
///         a direct governance call).
///
/// @dev    Operator decisions (see WORLDCUP_TEST.md):
///           - LMSR_B (env, default 2000e6): liquidity depth. MUST be 6-decimal USDC. Guardrail:
///             1_000e6 – 5_000e6. Bigger b = deeper book + larger seed (vault loss capped at
///             b·ln2 per market).
///           - VAULT_SEED_MINT (env, default 1_000_000e6): MockUSDC minted into the seed vault.
///           - DEPLOYER_FAUCET (env, default 100_000e6): MockUSDC minted to the deployer for
///             immediate smoke-testing.
///           - The market list below (`_teams()`) — edit freely.
///
/// @dev    Run (dry-run / simulate):
///           forge script script/DeployWorldCupTest.s.sol --rpc-url $BASE_SEPOLIA_RPC
///         Broadcast:
///           forge script script/DeployWorldCupTest.s.sol --rpc-url $BASE_SEPOLIA_RPC \
///             --broadcast --private-key $PRIVATE_KEY
contract DeployWorldCupTest is Script {
    // Feedback event class passed to createMarket. The fresh stack uses a no-op MockFeedbackController,
    // so the value is opaque; AWARD_WIN (6) is a sensible label for "team wins".
    uint8 internal constant EVENT_CLASS = 6;

    function run() external {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = deployerKey == 0 ? msg.sender : vm.addr(deployerKey);

        uint256 lmsrB = vm.envOr("LMSR_B", uint256(2_000e6));
        uint256 vaultSeedMint = vm.envOr("VAULT_SEED_MINT", uint256(1_000_000e6));
        uint256 deployerFaucet = vm.envOr("DEPLOYER_FAUCET", uint256(100_000e6));
        uint64 deadline = uint64(block.timestamp + 180 days);

        require(lmsrB >= 1_000e6 && lmsrB <= 5_000e6, "LMSR_B out of 6-decimal guardrail [1000e6, 5000e6]");

        if (deployerKey == 0) vm.startBroadcast();
        else vm.startBroadcast(deployerKey);

        // --- 1. Play-money token + mock optimistic oracle ---
        MockUSDC usdc = new MockUSDC();
        MockOptimisticOracleV3 mockOO = new MockOptimisticOracleV3();

        // --- 2. UMAAdapter (real contract) wired to the mock OO ---
        // Resolution for the dogfood goes through TestEventMarket.resolveForTest (one governance
        // call). The adapter is still deployed + wired so the standard UMA path also works if
        // wanted. timelockDelay = 1h is the adapter's hard floor; irrelevant to the resolve path.
        UMAAdapter umaImpl = new UMAAdapter();
        bytes memory umaInit = abi.encodeCall(UMAAdapter.initialize, (mockOO, deployer, uint32(1 hours)));
        UMAAdapter uma = UMAAdapter(address(new ERC1967Proxy(address(umaImpl), umaInit)));

        // --- 3. No-op feedback controller + minimal seed vault ---
        MockFeedbackController feedback = new MockFeedbackController();
        TestEventVault vault = new TestEventVault(IERC20(address(usdc)));

        // --- 4. Market implementation (test resolve) + factory behind a proxy ---
        TestEventMarket marketImpl = new TestEventMarket();
        EventMarketFactory factoryImpl = new EventMarketFactory();
        bytes memory factoryInit = abi.encodeCall(
            EventMarketFactory.initialize,
            (
                deployer, // governance == deployer/operator
                uint32(0), // timelockDelay: 0 for the fresh test stack (no friction)
                ILPVault(address(vault)),
                IFeedbackController(address(feedback)),
                uma,
                IERC20(address(usdc)),
                address(marketImpl)
            )
        );
        EventMarketFactory factory = EventMarketFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));

        // --- 5. Wire + seed the vault ---
        vault.setEventMarketFactory(address(factory));
        usdc.mint(address(vault), vaultSeedMint);
        if (deployerFaucet > 0) usdc.mint(deployer, deployerFaucet);

        // --- 6. Create one market per outcome ---
        string[] memory teams = _teams();
        bytes32 subjectId = keccak256("worldcup.2026.winner");
        uint256 seedPerMarket = LMSRMath.cost(0, 0, lmsrB);

        console2.log("==================== WORLD CUP TEST STACK ====================");
        console2.log("Deployer / governance :", deployer);
        console2.log("MockUSDC              :", address(usdc));
        console2.log("MockOptimisticOracleV3:", address(mockOO));
        console2.log("UMAAdapter (proxy)   :", address(uma));
        console2.log("MockFeedbackController:", address(feedback));
        console2.log("TestEventVault       :", address(vault));
        console2.log("EventMarket impl     :", address(marketImpl));
        console2.log("EventMarketFactory   :", address(factory));
        console2.log("lmsrB (6-dec)        :", lmsrB);
        console2.log("seed per market (6d) :", seedPerMarket);
        console2.log("resolution deadline  :", deadline);
        console2.log("--------------------------- MARKETS --------------------------");

        for (uint256 i = 0; i < teams.length; i++) {
            bytes32 eventId = keccak256(abi.encode(subjectId, teams[i]));
            string memory question = string(abi.encodePacked("Will ", teams[i], " win the 2026 World Cup?"));
            address market = factory.createMarket(subjectId, eventId, EVENT_CLASS, question, deadline, 0, lmsrB);
            console2.log(teams[i]);
            console2.log("  eventId:", vm.toString(eventId));
            console2.log("  market :", market);
        }

        console2.log("==============================================================");
        console2.log("Indexer: point pm-indexer FACTORY at the EventMarketFactory above,");
        console2.log("and set start block to this deploy's block. See WORLDCUP_TEST.md.");

        vm.stopBroadcast();
    }

    /// @dev The World-Cup outcome list. Edit freely (6-8 recommended). Each becomes one market.
    function _teams() internal pure returns (string[] memory teams) {
        teams = new string[](8);
        teams[0] = "Brazil";
        teams[1] = "Argentina";
        teams[2] = "France";
        teams[3] = "England";
        teams[4] = "Spain";
        teams[5] = "Germany";
        teams[6] = "Portugal";
        teams[7] = "Netherlands";
    }
}
