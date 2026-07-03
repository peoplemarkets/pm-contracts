// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ILPVault} from "../../src/core/ILPVault.sol";
import {EventMarket} from "../../src/events/EventMarket.sol";
import {EventMarketFactory} from "../../src/events/EventMarketFactory.sol";
import {EventMarketRouter} from "../../src/events/EventMarketRouter.sol";
import {IEventMarket} from "../../src/events/IEventMarket.sol";
import {IEventMarketRouter} from "../../src/events/IEventMarketRouter.sol";
import {IFeedbackController} from "../../src/feedback/IFeedbackController.sol";
import {UMAAdapter} from "../../src/oracle/UMAAdapter.sol";

import {MockFeedbackController, MockLPVault, MockUMAAdapter} from "../events/mocks/MockEventDeps.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @title  EventDispatchE2E — custodial event-dispatch path, enabled via the real Sepolia sequence.
///
/// @notice pm-engine #10 dogfood proof. Stands up the production EventMarketFactory + EventMarket
///         Router (both behind UUPS proxies), then enables the custodial path using the EXACT
///         two-layer, timelocked propose -> wait -> activate allowlisting that
///         `script/EnableEventOperator.s.sol` performs on Base Sepolia — including the router's
///         MIN_TIMELOCK_DELAY = 1h floor. It then proves the operator-relayed buy/sell credit the
///         trader (not the operator/router), and that non-operators and removed operators are
///         rejected on both trust layers.
///
/// @dev    This is the on-chain-behaviour twin of the deploy + enable tooling: if this test is
///         green, the Sepolia command sequence in docs/ENABLE_EVENT_DISPATCH.md yields a working
///         custodial path.
contract EventDispatchE2E is Test {
    EventMarketFactory internal factory;
    EventMarketRouter internal router;
    MockUSDC internal usdc;
    MockLPVault internal lpVault;
    MockFeedbackController internal feedback;
    MockUMAAdapter internal uma;

    address internal governance = makeAddr("governance");
    address internal eventOperator = makeAddr("eventOperator"); // engine signer (EVENT_OPERATOR)
    address internal trader = makeAddr("trader");
    address internal stranger = makeAddr("stranger");

    // Base Sepolia dogfood timelock. NOTE: the router hard-floors timelockDelay at
    // MIN_TIMELOCK_DELAY = 1 hours in initialize(), so 1h is the shortest achievable delay for the
    // custodial enable (the factory alone would allow shorter, but the router path gates the floor).
    uint32 internal constant SEPOLIA_TIMELOCK = 1 hours;
    uint256 internal constant LMSR_B = 2_000e6;
    uint64 internal constant DEADLINE = 2_000_000_000;

    bytes32 internal constant SUBJECT_ID = keccak256("subject.worldcup.argentina");
    bytes32 internal constant EVENT_ID = keccak256("event.worldcup.argentina.win");

    EventMarket internal market;

    function setUp() public {
        vm.warp(1_900_000_000);

        usdc = new MockUSDC();
        lpVault = new MockLPVault(IERC20(address(usdc)));
        feedback = new MockFeedbackController();
        uma = new MockUMAAdapter();
        usdc.mint(address(lpVault), 10_000_000e6);

        // --- Deploy factory + router behind proxies (mirrors DeployEventMarkets.s.sol) ---
        EventMarket marketImpl = new EventMarket();
        EventMarketFactory factoryImpl = new EventMarketFactory();
        bytes memory fInit = abi.encodeCall(
            EventMarketFactory.initialize,
            (
                governance,
                SEPOLIA_TIMELOCK,
                ILPVault(address(lpVault)),
                IFeedbackController(address(feedback)),
                UMAAdapter(address(uma)),
                IERC20(address(usdc)),
                address(marketImpl)
            )
        );
        factory = EventMarketFactory(address(new ERC1967Proxy(address(factoryImpl), fInit)));

        EventMarketRouter routerImpl = new EventMarketRouter();
        bytes memory rInit = abi.encodeCall(
            EventMarketRouter.initialize, (governance, address(factory), address(usdc), SEPOLIA_TIMELOCK)
        );
        router = EventMarketRouter(address(new ERC1967Proxy(address(routerImpl), rInit)));

        // --- Enable the custodial path via the EnableEventOperator propose->wait->activate flow ---
        _enableCustodialPath();

        // A live market to trade.
        vm.prank(governance);
        market = EventMarket(
            factory.createMarket(SUBJECT_ID, EVENT_ID, uint8(6), "Will Argentina win?", DEADLINE, 0, LMSR_B)
        );

        usdc.mint(trader, 1_000_000e6);
    }

    /// @dev The exact effect of `EnableEventOperator.propose()` then `.activate()` on Sepolia.
    function _enableCustodialPath() internal {
        // STEP 1 — propose (governance).
        vm.startPrank(governance);
        factory.proposeAddOperator(address(router)); // layer (i)
        router.proposeAddOperator(eventOperator); // layer (ii)
        vm.stopPrank();

        // Not active until the timelock elapses.
        assertFalse(factory.isOperator(address(router)), "router not yet a factory operator");
        assertFalse(router.isOperator(eventOperator), "operator not yet on router");

        // ...wait the Sepolia timelock...
        vm.warp(block.timestamp + SEPOLIA_TIMELOCK);

        // STEP 2 — activate (permissionless once ready).
        factory.activateAddOperator(address(router));
        router.activateAddOperator(eventOperator);

        assertTrue(factory.isOperator(address(router)), "layer (i) enabled");
        assertTrue(router.isOperator(eventOperator), "layer (ii) enabled");
    }

    // ------------------------------------------------------------------------------------------
    // Enablement wiring
    // ------------------------------------------------------------------------------------------

    function test_enable_activateBeforeTimelockReverts() public {
        // Re-propose a fresh operator to prove the timelock is enforced (not zero on Sepolia).
        address freshOp = makeAddr("freshOp");
        vm.prank(governance);
        router.proposeAddOperator(freshOp);
        vm.expectRevert(); // TimelockNotElapsed
        router.activateAddOperator(freshOp);
        vm.warp(block.timestamp + SEPOLIA_TIMELOCK);
        router.activateAddOperator(freshOp);
        assertTrue(router.isOperator(freshOp));
    }

    // ------------------------------------------------------------------------------------------
    // Custodial buy: operator relays, trader is credited + charged
    // ------------------------------------------------------------------------------------------

    function test_custodialBuy_creditsTrader_pullsTraderUsdc() public {
        uint256 spend = 500e6;

        // Trader gives a single approval to the ROUTER (the one approval target).
        vm.prank(trader);
        usdc.approve(address(router), type(uint256).max);

        uint256 traderBefore = usdc.balanceOf(trader);

        // Engine operator relays the buy on the trader's behalf.
        vm.prank(eventOperator);
        uint256 shares = router.buyOutcomeFor(trader, address(market), true, spend, 0);

        assertGt(shares, 0, "shares minted");
        assertEq(market.yesBalance(trader), shares, "shares credited to trader");
        assertEq(market.yesBalance(eventOperator), 0, "operator not credited");
        assertEq(market.yesBalance(address(router)), 0, "router not credited");
        assertEq(usdc.balanceOf(trader), traderBefore - spend, "USDC pulled from trader");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds no funds at rest");
        assertEq(usdc.allowance(address(router), address(market)), 0, "router->market allowance cleared");
    }

    // ------------------------------------------------------------------------------------------
    // Custodial sell: proceeds paid directly to the trader
    // ------------------------------------------------------------------------------------------

    function test_custodialSell_paysTrader() public {
        vm.prank(trader);
        usdc.approve(address(router), type(uint256).max);

        vm.prank(eventOperator);
        uint256 shares = router.buyOutcomeFor(trader, address(market), true, 500e6, 0);

        uint256 traderBefore = usdc.balanceOf(trader);

        vm.prank(eventOperator);
        uint256 out = router.sellOutcomeFor(trader, address(market), true, shares, 0);

        assertGt(out, 0, "proceeds returned");
        assertEq(market.yesBalance(trader), 0, "shares burned");
        assertEq(usdc.balanceOf(trader), traderBefore + out, "proceeds paid to trader");
        assertEq(usdc.balanceOf(address(router)), 0, "router never custodies sell proceeds");
    }

    // ------------------------------------------------------------------------------------------
    // Access control — non-operator + removed operator rejected
    // ------------------------------------------------------------------------------------------

    function test_custodial_nonOperatorReverts() public {
        vm.prank(trader);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NotOperator.selector, stranger));
        vm.prank(stranger);
        router.buyOutcomeFor(trader, address(market), true, 500e6, 0);
    }

    function test_custodial_removedOperatorReverts() public {
        // Governance kill switch on layer (ii): immediate removal.
        vm.prank(governance);
        router.removeOperator(eventOperator);

        vm.prank(trader);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IEventMarketRouter.NotOperator.selector, eventOperator));
        vm.prank(eventOperator);
        router.buyOutcomeFor(trader, address(market), true, 500e6, 0);
    }

    function test_custodial_routerRemovedFromFactoryReverts() public {
        // Governance kill switch on layer (i): remove router as a factory operator -> markets reject.
        vm.prank(governance);
        factory.removeOperator(address(router));

        vm.prank(trader);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(EventMarket.NotOperator.selector, address(router)));
        vm.prank(eventOperator);
        router.buyOutcomeFor(trader, address(market), true, 500e6, 0);
    }
}
