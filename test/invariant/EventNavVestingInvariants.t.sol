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
import {EventNavVestingHandler} from "./EventNavVestingHandler.sol";

/// @title EventNavVestingInvariants — post-settle 5-bucket I1 with the receive-only vesting bucket.
/// @dev    The always-live `EventNavInvariants` never settles a market, so `unvestedEventSurplus`
///         stays 0 and its I1 is the 4-bucket partition. This suite drives create→trade→SETTLE
///         cycles + time warps so the vesting bucket is populated and dripping, and proves the 5th
///         I1 term closes the partition exactly: balance == freeAssets + positionCollateral +
///         insurance + accruedFees + unvestedEventSurplus. It also proves the exclusion is
///         well-formed (unvested never exceeds the raw liquid, so freeAssets never saturates).
contract EventNavVestingInvariants is Test {
    LPVault internal vault;
    EventMarketFactory internal factory;
    MockUSDC internal usdc;
    MockFeedbackController internal feedback;
    MockUMAAdapter internal uma;
    EventNavVestingHandler internal handler;

    address internal governance = makeAddr("governance");
    address internal operator = makeAddr("operator");

    uint32 internal constant TIMELOCK = 1 days;
    uint256 internal constant ONE_USDC = 1e6;

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

        lps = new address[](3);
        traders = new address[](3);
        for (uint256 i; i < 3; ++i) {
            lps[i] = makeAddr(string.concat("lp", vm.toString(i)));
            traders[i] = makeAddr(string.concat("tr", vm.toString(i)));
            usdc.mint(lps[i], 30_000_000 * ONE_USDC);
            usdc.mint(traders[i], 30_000_000 * ONE_USDC);
            vm.prank(lps[i]);
            usdc.approve(address(vault), type(uint256).max);
        }

        // Warm-start LP capital so the handler can immediately seed markets.
        vm.prank(lps[0]);
        vault.deposit(5_000_000 * ONE_USDC, lps[0]);

        handler = new EventNavVestingHandler(vault, factory, usdc, uma, governance, lps, traders);
        targetContract(address(handler));
    }

    /// @notice 5-bucket strict I1, held across mixed ops INCLUDING settles (unvested > 0):
    ///         balance == freeAssets + positionCollateral + insurance + accruedFees + unvestedEventSurplus.
    function invariant_StrictI1_5Bucket() public view {
        uint256 bal = usdc.balanceOf(address(vault));
        uint256 sum = vault.freeAssets() + vault.positionCollateral() + vault.insuranceFundBalance()
            + vault.accruedFees() + vault.unvestedEventSurplus();
        assertEq(bal, sum, "5-bucket I1: balance != free + collateral + insurance + fees + unvested");
    }

    /// @notice The vesting exclusion is well-formed: unvested never exceeds the raw liquid balance,
    ///         so `freeAssets` never has to saturate (the subtraction is exact, keeping I1 tight).
    function invariant_UnvestedNeverExceedsLiquidRaw() public view {
        uint256 liquidRaw = usdc.balanceOf(address(vault)) - vault.positionCollateral() - vault.insuranceFundBalance()
            - vault.accruedFees();
        assertLe(vault.unvestedEventSurplus(), liquidRaw, "unvested exceeds raw liquid (freeAssets would saturate)");
    }

    /// @notice NAV identity still decomposes exactly with the vesting bucket in play.
    function invariant_NavIdentity() public view {
        assertEq(
            vault.totalAssets(), vault.freeAssets() + vault.eventRecoverable(), "NAV: totalAssets != free + recoverable"
        );
    }
}
