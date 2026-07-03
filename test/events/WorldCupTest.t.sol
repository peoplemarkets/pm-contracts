// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ILPVault} from "../../src/core/ILPVault.sol";
import {EventMarket} from "../../src/events/EventMarket.sol";
import {EventMarketFactory} from "../../src/events/EventMarketFactory.sol";
import {IEventMarket} from "../../src/events/IEventMarket.sol";
import {LMSRMath} from "../../src/events/LMSRMath.sol";
import {IFeedbackController} from "../../src/feedback/IFeedbackController.sol";
import {UMAAdapter} from "../../src/oracle/UMAAdapter.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";
import {TestEventMarket} from "../mocks/TestEventMarket.sol";
import {TestEventVault} from "../mocks/TestEventVault.sol";
import {MockFeedbackController} from "./mocks/MockEventDeps.sol";

/// @title  WorldCupTest — end-to-end coverage of the fresh, isolated World-Cup event stack.
/// @notice Mirrors `DeployWorldCupTest.s.sol`: MockUSDC + MockOptimisticOracleV3 behind a real
///         UMAAdapter + minimal TestEventVault + EventMarketFactory whose market implementation is
///         TestEventMarket. Covers create -> buy -> sell -> resolve(each outcome) -> redeem via the
///         governance one-call override, the `priceOf` scaling fix, and (for fidelity) the full
///         real UMAAdapter -> MockOO resolution path.
contract WorldCupTest is Test {
    EventMarketFactory internal factory;
    MockUSDC internal usdc;
    MockOptimisticOracleV3 internal mockOO;
    UMAAdapter internal uma;
    MockFeedbackController internal feedback;
    TestEventVault internal vault;

    address internal gov; // this test contract == factory governance
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant LMSR_B = 2_000e6; // 6-decimal USDC, within [1000e6, 5000e6] guardrail
    uint64 internal constant DEADLINE = 2_000_000_000;

    bytes32 internal constant SUBJECT_ID = keccak256("worldcup.2026.winner");

    function setUp() public {
        vm.warp(1_900_000_000);
        gov = address(this);

        usdc = new MockUSDC();
        mockOO = new MockOptimisticOracleV3();

        UMAAdapter umaImpl = new UMAAdapter();
        bytes memory umaInit = abi.encodeCall(UMAAdapter.initialize, (mockOO, gov, uint32(1 hours)));
        uma = UMAAdapter(address(new ERC1967Proxy(address(umaImpl), umaInit)));

        feedback = new MockFeedbackController();
        vault = new TestEventVault(IERC20(address(usdc)));

        TestEventMarket marketImpl = new TestEventMarket();
        EventMarketFactory factoryImpl = new EventMarketFactory();
        bytes memory factoryInit = abi.encodeCall(
            EventMarketFactory.initialize,
            (
                gov,
                uint32(0), // no timelock in the fresh test stack
                ILPVault(address(vault)),
                IFeedbackController(address(feedback)),
                uma,
                IERC20(address(usdc)),
                address(marketImpl)
            )
        );
        factory = EventMarketFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));

        vault.setEventMarketFactory(address(factory));
        usdc.mint(address(vault), 1_000_000e6);

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _createMarket(bytes32 eventId) internal returns (TestEventMarket m) {
        address addr = factory.createMarket(SUBJECT_ID, eventId, uint8(6), "Will X win?", DEADLINE, 0, LMSR_B);
        m = TestEventMarket(addr);
    }

    function _buy(TestEventMarket m, address who, bool isYes, uint256 spend) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(m), spend);
        shares = m.buyOutcome(isYes, spend, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------
    // Fresh-stack create -> buy -> sell -> resolve -> redeem (governance one-call override)
    // ------------------------------------------------------------------------------------------

    function test_freshStack_createSeedsMarket() public {
        TestEventMarket m = _createMarket(keccak256("brazil"));
        uint256 expectedSeed = LMSRMath.cost(0, 0, LMSR_B);
        assertEq(usdc.balanceOf(address(m)), expectedSeed, "seed escrowed in market");
        assertEq(vault.eventFundedSeed(), expectedSeed, "vault booked the seed");
        assertEq(uint256(m.status()), uint256(IEventMarket.Status.OPEN), "open");
    }

    function test_buyThenSell_roundTrip() public {
        TestEventMarket m = _createMarket(keccak256("argentina"));
        uint256 shares = _buy(m, alice, true, 100e6);
        assertGt(shares, 0, "shares minted");

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 out = m.sellOutcome(true, shares, 0);
        assertLe(out, 100e6, "no risk-free profit on round trip");
        assertEq(usdc.balanceOf(alice), balBefore + out, "proceeds to seller");
        assertEq(m.yesBalance(alice), 0, "shares burned");
    }

    function test_resolveYes_viaOverride_redeem() public {
        TestEventMarket m = _createMarket(keccak256("france"));
        uint256 yesShares = _buy(m, alice, true, 300e6);
        _buy(m, bob, false, 300e6);

        // ONE governance call resolves the market.
        m.resolveForTest(IEventMarket.Outcome.YES);
        assertEq(uint256(m.outcome()), uint256(IEventMarket.Outcome.YES));
        assertEq(uint256(m.status()), uint256(IEventMarket.Status.RESOLVED));
        assertEq(vault.eventFundedSeed(), 0, "seed settled back to vault");

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = m.redeemWinnings();
        assertEq(payout, yesShares, "winner paid 1 USDC per share");
        assertEq(usdc.balanceOf(alice), balBefore + payout);

        vm.prank(bob);
        vm.expectRevert("EventMarket: no winnings");
        m.redeemWinnings();
    }

    function test_resolveNo_viaOverride_redeem() public {
        TestEventMarket m = _createMarket(keccak256("england"));
        uint256 noShares = _buy(m, bob, false, 250e6);

        m.resolveForTest(IEventMarket.Outcome.NO);
        vm.prank(bob);
        uint256 payout = m.redeemWinnings();
        assertEq(payout, noShares, "NO winner paid per share");
    }

    function test_resolveVoid_viaOverride_redeemHalf() public {
        TestEventMarket m = _createMarket(keccak256("spain"));
        uint256 yesShares = _buy(m, alice, true, 200e6);

        m.resolveForTest(IEventMarket.Outcome.VOID);
        vm.prank(alice);
        uint256 payout = m.redeemWinnings();
        assertEq(payout, yesShares / 2, "VOID refunds half per share");
    }

    function test_resolveForTest_onlyGovernance() public {
        TestEventMarket m = _createMarket(keccak256("germany"));
        vm.expectRevert(abi.encodeWithSelector(TestEventMarket.NotGovernance.selector, stranger));
        vm.prank(stranger);
        m.resolveForTest(IEventMarket.Outcome.YES);
    }

    function test_resolveForTest_rejectsUnresolved() public {
        TestEventMarket m = _createMarket(keccak256("portugal"));
        vm.expectRevert("TestEventMarket: invalid outcome");
        m.resolveForTest(IEventMarket.Outcome.UNRESOLVED);
    }

    function test_resolveForTest_doubleResolveReverts() public {
        TestEventMarket m = _createMarket(keccak256("netherlands"));
        m.resolveForTest(IEventMarket.Outcome.YES);
        vm.expectRevert("TestEventMarket: already resolved");
        m.resolveForTest(IEventMarket.Outcome.NO);
    }

    // ------------------------------------------------------------------------------------------
    // priceOf scaling fix: YES + NO ~= 1e18, and prices move with trades
    // ------------------------------------------------------------------------------------------

    function test_priceOf_sumsToOne_atInit() public {
        TestEventMarket m = _createMarket(keccak256("price.init"));
        uint256 pYes = m.priceOf(true);
        uint256 pNo = m.priceOf(false);
        // Symmetric market: each ~0.5e18.
        assertApproxEqAbs(pYes, 0.5e18, 1e15, "YES ~= 0.5 at init");
        assertApproxEqAbs(pNo, 0.5e18, 1e15, "NO ~= 0.5 at init");
        assertApproxEqAbs(pYes + pNo, 1e18, 2e15, "YES + NO ~= 1");
    }

    function test_priceOf_movesWithTradesAndStaysNormalized() public {
        TestEventMarket m = _createMarket(keccak256("price.moves"));
        uint256 pYes0 = m.priceOf(true);

        // Progressive YES buys must raise the YES price monotonically, keep it < 1e18, and keep
        // YES + NO normalized to ~1e18 throughout.
        _buy(m, alice, true, 1_000e6);
        uint256 pYes1 = m.priceOf(true);
        assertGt(pYes1, pYes0, "YES price rose after first buy");
        assertApproxEqAbs(pYes1 + m.priceOf(false), 1e18, 2e15, "still normalized after buy 1");

        _buy(m, alice, true, 1_000e6);
        uint256 pYes2 = m.priceOf(true);
        assertGt(pYes2, pYes1, "YES price rose after second buy");
        assertLt(pYes2, 1e18, "YES price stays below 1");
        assertApproxEqAbs(pYes2 + m.priceOf(false), 1e18, 2e15, "still normalized after buy 2");
    }

    function test_priceOf_buyingNoLowersYes() public {
        TestEventMarket m = _createMarket(keccak256("price.no"));
        uint256 pYes0 = m.priceOf(true);
        _buy(m, bob, false, 1_000e6);
        assertLt(m.priceOf(true), pYes0, "buying NO lowers YES price");
    }

    // ------------------------------------------------------------------------------------------
    // Fidelity: the real UMAAdapter -> MockOptimisticOracleV3 resolution path also works.
    // (Timelock/liveness are warped past in-test; on live testnet this is the slower alt path.)
    // ------------------------------------------------------------------------------------------

    function test_resolveViaRealUmaAndMockOO() public {
        bytes32 eventId = keccak256("uma.path");
        TestEventMarket m = _createMarket(eventId);
        uint256 yesShares = _buy(m, alice, true, 200e6);

        // 1) Governance registers the metric (metricId == eventId), currency == MockUSDC.
        uint256 bond = 1e6;
        uint64 liveness = 60;
        uma.proposeRegisterMetric(eventId, bond, liveness, bytes32("ASSERT_TRUTH"), address(usdc));
        vm.warp(block.timestamp + 1 hours); // past the adapter's timelock floor
        uma.activateRegisterMetric(eventId);

        // 2) Asserter posts the bond and proposes the YES outcome via the market wrapper.
        usdc.mint(alice, bond);
        vm.startPrank(alice);
        usdc.approve(address(uma), bond);
        m.proposeResolution(IEventMarket.Outcome.YES);
        vm.stopPrank();
        assertEq(uint256(m.status()), uint256(IEventMarket.Status.PENDING_RESOLUTION), "pending");

        // 3) Liveness elapses; settle the assertion in the adapter, then finalize the market.
        bytes32 assertionId = keccak256(abi.encode(address(mockOO), uint256(1)));
        vm.warp(block.timestamp + liveness + 1);
        uma.settleAssertion(assertionId);

        m.settleResolution();
        assertEq(uint256(m.outcome()), uint256(IEventMarket.Outcome.YES), "resolved YES via UMA path");

        vm.prank(alice);
        uint256 payout = m.redeemWinnings();
        assertEq(payout, yesShares, "winner paid via UMA path");
    }
}
