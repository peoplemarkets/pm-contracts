// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {AssertEventResolution} from "../../script/AssertEventResolution.s.sol";
import {RegisterEventMetric} from "../../script/RegisterEventMetric.s.sol";
import {ILPVault} from "../../src/core/ILPVault.sol";
import {EventMarket} from "../../src/events/EventMarket.sol";
import {EventMarketFactory} from "../../src/events/EventMarketFactory.sol";
import {IEventMarket} from "../../src/events/IEventMarket.sol";
import {IFeedbackController} from "../../src/feedback/IFeedbackController.sol";
import {IOptimisticOracleV3, UMAAdapter} from "../../src/oracle/UMAAdapter.sol";

import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockFeedbackController, MockLPVault} from "./mocks/MockEventDeps.sol";

/// @title  Fix C — RegisterEventMetric + AssertEventResolution script simulations.
/// @notice Both env-driven runbook scripts are simulated end-to-end against REAL UMAAdapter /
///         EventMarket proxies IN A SINGLE SUITE (they share process env, so keeping them in one
///         file makes the `vm.setEnv` sequence deterministic — forge runs a suite's tests serially).
///
///           RegisterEventMetric: propose -> (timelock) -> activate -> verify flips metricOf().registered.
///           AssertEventResolution: approve -> propose (self-bond) -> (liveness) -> settle finalizes YES.
contract ScriptRunbookSimsTest is Test {
    MockOptimisticOracleV3 internal oo;
    MockUSDC internal usdc;
    UMAAdapter internal adapter;
    EventMarketFactory internal factory;
    MockLPVault internal lpVault;
    MockFeedbackController internal feedback;

    RegisterEventMetric internal registerScript;
    AssertEventResolution internal assertScript;

    uint256 internal constant GOV_PK = 0xB0B;
    address internal governance = vm.addr(GOV_PK);
    uint256 internal constant ASSERTER_PK = 0xA55E7;
    address internal asserter = vm.addr(ASSERTER_PK);

    uint32 internal constant TIMELOCK_DELAY = 1 hours;
    uint256 internal constant LMSR_B = 10_000e6;
    uint64 internal constant DEADLINE = 2_000_000_000;
    uint256 internal constant BOND = 1e6;
    uint64 internal constant LIVENESS = 7200;
    bytes32 internal constant IDENTIFIER = bytes32("ASSERT_TRUTH");

    // Distinct metrics/events per script so a stale env read cannot cross-contaminate on-chain state.
    bytes32 internal constant REGISTER_EVENT_ID = keccak256("uma.metric.election.2028");
    bytes32 internal constant ASSERT_EVENT_ID = keccak256("uma.event.election.win");
    bytes32 internal constant SUBJECT_ID = keccak256("subject.candidate");

    function setUp() public {
        vm.warp(1_900_000_000);
        oo = new MockOptimisticOracleV3();
        usdc = new MockUSDC();
        lpVault = new MockLPVault(IERC20(address(usdc)));
        feedback = new MockFeedbackController();
        usdc.mint(address(lpVault), 10_000_000e6);

        UMAAdapter umaImpl = new UMAAdapter();
        adapter = UMAAdapter(
            address(
                new ERC1967Proxy(
                    address(umaImpl),
                    abi.encodeCall(
                        UMAAdapter.initialize, (IOptimisticOracleV3(address(oo)), governance, TIMELOCK_DELAY)
                    )
                )
            )
        );

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
                            TIMELOCK_DELAY,
                            ILPVault(address(lpVault)),
                            IFeedbackController(address(feedback)),
                            adapter,
                            IERC20(address(usdc)),
                            address(marketImpl)
                        )
                    )
                )
            )
        );

        registerScript = new RegisterEventMetric();
        assertScript = new AssertEventResolution();

        usdc.mint(asserter, 100e6);
    }

    // ------------------------------------------------------------------------------------------
    // RegisterEventMetric
    // ------------------------------------------------------------------------------------------

    function _wireRegisterEnv() internal {
        vm.setEnv("DEPLOYER_PK", vm.toString(GOV_PK));
        vm.setEnv("UMA_ADAPTER", vm.toString(address(adapter)));
        vm.setEnv("EVENT_ID", vm.toString(REGISTER_EVENT_ID));
        vm.setEnv("BOND", vm.toString(BOND));
        vm.setEnv("LIVENESS", vm.toString(uint256(LIVENESS)));
        vm.setEnv("UMA_IDENTIFIER", vm.toString(IDENTIFIER));
        vm.setEnv("BOND_CURRENCY", vm.toString(address(usdc)));
    }

    /// @dev SINGLE test body so every `vm.setEnv` sequence is strictly ordered — forge may run
    ///      separate test functions on parallel threads that share process env, so the register and
    ///      assert runbooks (which both write EVENT_ID / BOND) MUST NOT be split across functions.
    function test_scriptRunbooks_simulateEndToEnd() public {
        _run_register();
        _run_registerProposeIdempotent();
        _run_assert();
    }

    function _run_register() internal {
        _wireRegisterEnv();
        registerScript.propose();
        assertTrue(adapter.pendingMetricOf(REGISTER_EVENT_ID).exists, "pending after propose");
        assertFalse(adapter.metricOf(REGISTER_EVENT_ID).registered, "not yet registered");

        vm.warp(block.timestamp + adapter.timelockDelay() + 1);

        _wireRegisterEnv();
        registerScript.activate();
        assertTrue(adapter.metricOf(REGISTER_EVENT_ID).registered, "registered after activate");

        UMAAdapter.UMAMetric memory m = adapter.metricOf(REGISTER_EVENT_ID);
        assertEq(m.bond, BOND, "bond");
        assertEq(uint256(m.livenessSeconds), uint256(LIVENESS), "liveness");
        assertEq(m.identifier, IDENTIFIER, "identifier");
        assertEq(m.currency, address(usdc), "currency");

        _wireRegisterEnv();
        registerScript.verify();
    }

    function _run_registerProposeIdempotent() internal {
        // Use a fresh metricId so this leg is independent of the already-activated one.
        bytes32 freshId = keccak256("uma.metric.idempotent.check");
        vm.setEnv("DEPLOYER_PK", vm.toString(GOV_PK));
        vm.setEnv("UMA_ADAPTER", vm.toString(address(adapter)));
        vm.setEnv("EVENT_ID", vm.toString(freshId));
        vm.setEnv("BOND", vm.toString(BOND));
        vm.setEnv("LIVENESS", vm.toString(uint256(LIVENESS)));
        vm.setEnv("UMA_IDENTIFIER", vm.toString(IDENTIFIER));
        vm.setEnv("BOND_CURRENCY", vm.toString(address(usdc)));
        registerScript.propose();
        registerScript.propose(); // skip, no revert
        assertTrue(adapter.pendingMetricOf(freshId).exists, "one pending");
    }

    // ------------------------------------------------------------------------------------------
    // AssertEventResolution
    // ------------------------------------------------------------------------------------------

    function _registerAssertMetricAndMarket() internal returns (EventMarket market) {
        vm.startPrank(governance);
        adapter.proposeRegisterMetric(ASSERT_EVENT_ID, BOND, LIVENESS, IDENTIFIER, address(usdc));
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        adapter.activateRegisterMetric(ASSERT_EVENT_ID);
        market = EventMarket(factory.createMarket(SUBJECT_ID, ASSERT_EVENT_ID, uint8(1), "Win?", DEADLINE, 0, LMSR_B));
        vm.stopPrank();
    }

    function _wireAssertEnv(address market) internal {
        vm.setEnv("ASSERTER_PK", vm.toString(ASSERTER_PK));
        vm.setEnv("UMA_ADAPTER", vm.toString(address(adapter)));
        vm.setEnv("EVENT_ID", vm.toString(ASSERT_EVENT_ID));
        vm.setEnv("OUTCOME", "1"); // YES
        vm.setEnv("MARKET_ADDRESS", vm.toString(market));
        vm.setEnv("BOND", vm.toString(BOND));
        vm.setEnv("BOND_CURRENCY", vm.toString(address(usdc)));
    }

    function _run_assert() internal {
        EventMarket market = _registerAssertMetricAndMarket();

        _wireAssertEnv(address(market));
        assertScript.approve();
        assertEq(usdc.allowance(asserter, address(adapter)), BOND, "bond approved");

        uint256 asserterBefore = usdc.balanceOf(asserter);
        _wireAssertEnv(address(market));
        assertScript.propose();
        assertEq(usdc.balanceOf(asserter), asserterBefore - BOND, "bond pulled from asserter");

        // The mock OO derives the first assertionId deterministically as keccak(oo, nextSeed=1).
        bytes32 assertionId = keccak256(abi.encode(address(oo), uint256(1)));
        assertTrue(adapter.assertionOf(assertionId).asserter == asserter, "assertion recorded");

        vm.warp(block.timestamp + LIVENESS + 1);

        _wireAssertEnv(address(market));
        vm.setEnv("ASSERTION_ID", vm.toString(assertionId));
        assertScript.settle();

        assertEq(uint256(market.outcome()), uint256(IEventMarket.Outcome.YES), "market settled YES");
        assertEq(uint256(market.status()), uint256(IEventMarket.Status.RESOLVED), "resolved");
    }
}
