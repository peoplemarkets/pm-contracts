// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {EventMarketFactory} from "../src/events/EventMarketFactory.sol";
import {LPVault} from "../src/core/LPVault.sol";
import {LMSRMath} from "../src/events/LMSRMath.sol";

/// @title  CreateWorldCupMarkets — seed a handful of World-Cup event markets on the deployed factory.
///
/// @notice Governance-only. Each market clones the (operator-capable) EventMarket template and pulls
///         its LMSR seed `cost(0,0,lmsrB) = lmsrB * ln2` from the LPVault, so lmsrB MUST be small
///         enough that the sum of seeds fits the vault's LIQUID USDC (freeAssets). The deployed
///         Base Sepolia vault currently holds ~9.65 USDC, so the default lmsrB = 2e6 (~1.386 USDC
///         seed/market) fits several markets. Raise lmsrB only after depositing more USDC to the vault.
///
/// @dev    Resolution: the deployed EventMarket resolves via UMA only (no operator override) and the
///         #17 readiness gate is not yet on-chain, so these markets CREATE + TRADE without a
///         pre-registered metric — but to SETTLE one you must register its eventId as a UMA metric
///         (script/RegisterEventMetric.s.sol) and post an assertion. This script is for the custodial
///         TRADE demo; resolution is a separate, optional step.
///
/// @dev    eventClass is set to UNSET(0): the deployed FeedbackController has no sports class (that is
///         the #17 addition), and these markets are for trading, not the feedback demo. Inert here.
///
/// @dev    Env:
///           DEPLOYER_PK / PRIVATE_KEY  GOVERNANCE key (factory owner, 0x0183…).
///           EVENT_MARKET_FACTORY       factory proxy (0xb73f…).
///           LP_VAULT_ADDRESS           vault proxy (0x6347…) — for the capacity check only.
///           LMSR_B                     LMSR liquidity param, 6-dec USDC (default 2_000_000 = 2 USDC).
///           RESOLUTION_DAYS            days until resolutionDeadline (default 14; WC final is ~9 days out).
contract CreateWorldCupMarkets is Script {
    uint8 constant EVENT_CLASS_UNSET = 0;

    struct MarketDef {
        string name; // subject label -> subjectId = keccak256(name)
        string question;
    }

    /// @dev EDIT THIS LIST. subjectId is derived from `name`; eventId is unique per (name, tag).
    function _markets() internal pure returns (MarketDef[] memory m) {
        m = new MarketDef[](3);
        m[0] = MarketDef("ARGENTINA", "Will Argentina win the 2026 FIFA World Cup?");
        m[1] = MarketDef("FRANCE", "Will France win the 2026 FIFA World Cup?");
        m[2] = MarketDef("BRAZIL", "Will Brazil win the 2026 FIFA World Cup?");
    }

    function run() external {
        uint256 key = vm.envOr("DEPLOYER_PK", uint256(0));
        if (key == 0) key = vm.envOr("PRIVATE_KEY", uint256(0));

        EventMarketFactory factory = EventMarketFactory(vm.envAddress("EVENT_MARKET_FACTORY"));
        uint256 lmsrB = vm.envOr("LMSR_B", uint256(2_000_000));
        uint64 deadline = uint64(block.timestamp + vm.envOr("RESOLUTION_DAYS", uint256(14)) * 1 days);

        MarketDef[] memory defs = _markets();

        // Capacity check against the vault's liquid USDC (fail LOUD before spending gas on a revert).
        uint256 seedEach = LMSRMath.cost(0, 0, lmsrB);
        uint256 totalSeed = seedEach * defs.length;
        LPVault vault = LPVault(vm.envAddress("LP_VAULT_ADDRESS"));
        uint256 liquid = vault.freeAssets();
        console2.log("=== CreateWorldCupMarkets ===");
        console2.log("lmsrB            :", lmsrB);
        console2.log("seed per market  :", seedEach);
        console2.log("markets          :", defs.length);
        console2.log("total seed needed:", totalSeed);
        console2.log("vault freeAssets :", liquid);
        require(totalSeed <= liquid, "insufficient vault liquidity for seeds - lower LMSR_B or deposit USDC");

        if (key == 0) vm.startBroadcast();
        else vm.startBroadcast(key);

        for (uint256 i = 0; i < defs.length; i++) {
            bytes32 subjectId = keccak256(bytes(defs[i].name));
            bytes32 eventId = keccak256(abi.encodePacked(defs[i].name, "-WC2026-WIN"));
            address market = factory.createMarket(
                subjectId, eventId, EVENT_CLASS_UNSET, defs[i].question, deadline, 0, lmsrB
            );
            console2.log("--------------------------------------");
            console2.log(defs[i].name);
            console2.log("  market  :", market);
            console2.log("  eventId :", vm.toString(eventId));
        }

        vm.stopBroadcast();

        console2.log("--------------------------------------");
        console2.log("Done. Testers: get Circle testnet USDC (faucet.circle.com), approve the");
        console2.log("EventMarketRouter once, then POST /api/v1/event-markets/<market>/orders.");
    }
}
