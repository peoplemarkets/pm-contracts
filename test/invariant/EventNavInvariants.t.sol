// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ILPVault} from "../../src/core/ILPVault.sol";
import {LPVault} from "../../src/core/LPVault.sol";

import {EventMarket} from "../../src/events/EventMarket.sol";
import {EventMarketFactory} from "../../src/events/EventMarketFactory.sol";
import {IFeedbackController} from "../../src/feedback/IFeedbackController.sol";
import {UMAAdapter} from "../../src/oracle/UMAAdapter.sol";

import {MockFeedbackController, MockUMAAdapter} from "../events/mocks/MockEventDeps.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {EventNavHandler} from "./EventNavHandler.sol";

/// @title EventNavInvariants — fuzz the event-NAV accounting with a live market.
/// @dev    Proves the properties the mark-to-zero (PR #12) and drip (Design 3) alternatives fail:
///         - I1 strict: balance == freeAssets + positionCollateral + insurance + accruedFees, held
///           WHILE a market is live (event seed is not phantom-counted into freeAssets).
///         - NAV identity: totalAssets == freeAssets + eventRecoverable.
///         - No over-mark: eventRecoverable <= the live market's own USDC cash.
contract EventNavInvariants is Test {
    LPVault internal vault;
    EventMarketFactory internal factory;
    EventMarket internal market;
    MockUSDC internal usdc;
    MockFeedbackController internal feedback;
    MockUMAAdapter internal uma;
    EventNavHandler internal handler;

    address internal governance = makeAddr("governance");
    address internal operator = makeAddr("operator");

    uint32 internal constant TIMELOCK = 1 days;
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant LMSR_B = 10_000e6;
    uint64 internal constant DEADLINE = 2_000_000_000;

    address[] internal lps;
    address[] internal traders;

    function setUp() public {
        vm.warp(1_900_000_000);
        usdc = new MockUSDC();

        LPVault vaultImpl = new LPVault();
        vault = LPVault(
            address(
                new ERC1967Proxy(
                    address(vaultImpl),
                    abi.encodeCall(
                        LPVault.initialize, (IERC20(address(usdc)), governance, operator, TIMELOCK, "pm LP", "pmUSDC")
                    )
                )
            )
        );

        feedback = new MockFeedbackController();
        uma = new MockUMAAdapter();
        EventMarket marketImpl = new EventMarket();
        EventMarketFactory factoryImpl = new EventMarketFactory();
        factory = EventMarketFactory(
            address(
                new ERC1967Proxy(
                    address(factoryImpl),
                    abi.encodeCall(
                        EventMarketFactory.initialize,
                        (
                            governance,
                            TIMELOCK,
                            ILPVault(address(vault)),
                            IFeedbackController(address(feedback)),
                            UMAAdapter(address(uma)),
                            IERC20(address(usdc)),
                            address(marketImpl)
                        )
                    )
                )
            )
        );

        vm.prank(governance);
        vault.proposeSetEventMarketFactory(address(factory));
        vm.warp(block.timestamp + TIMELOCK);
        vault.activateSetEventMarketFactory();

        // Actors.
        lps = new address[](3);
        traders = new address[](3);
        for (uint256 i; i < 3; ++i) {
            lps[i] = makeAddr(string.concat("lp", vm.toString(i)));
            traders[i] = makeAddr(string.concat("tr", vm.toString(i)));
            usdc.mint(lps[i], 20_000_000 * ONE_USDC);
            usdc.mint(traders[i], 20_000_000 * ONE_USDC);
            vm.prank(lps[i]);
            usdc.approve(address(vault), type(uint256).max);
        }

        // Warm-start LP capital, then create an always-live market (UMA stays unresolved).
        vm.prank(lps[0]);
        vault.deposit(3_000_000 * ONE_USDC, lps[0]);
        vm.prank(governance);
        market = EventMarket(
            factory.createMarket(keccak256("inv.event"), keccak256("inv.event"), uint8(1), "Q?", DEADLINE, 0, LMSR_B)
        );

        handler = new EventNavHandler(vault, market, usdc, lps, traders);
        targetContract(address(handler));
    }

    /// @notice I1 strict — holds WITH a live market (the property Designs 2/3 fail).
    function invariant_StrictI1WithLiveMarket() public view {
        uint256 bal = usdc.balanceOf(address(vault));
        uint256 sum =
            vault.freeAssets() + vault.positionCollateral() + vault.insuranceFundBalance() + vault.accruedFees();
        assertEq(bal, sum, "I1: balance != sum-of-buckets with live market");
    }

    /// @notice NAV identity — share-price denominator decomposes exactly into liquid + recoverable.
    function invariant_NavIdentity() public view {
        assertEq(
            vault.totalAssets(), vault.freeAssets() + vault.eventRecoverable(), "NAV: totalAssets != free + recoverable"
        );
    }

    /// @notice No over-mark — the recoverable never exceeds the live market's own USDC cash.
    function invariant_RecoverableNeverExceedsMarketCash() public view {
        assertLe(vault.eventRecoverable(), usdc.balanceOf(address(market)), "recoverable over-marks system cash");
    }

    /// @notice The single market stays registered throughout (never settled during the run).
    function invariant_MarketStaysLive() public view {
        assertEq(vault.liveEventMarketCount(), 1, "market must remain live");
    }
}
