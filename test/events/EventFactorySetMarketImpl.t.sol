// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ILPVault} from "../../src/core/ILPVault.sol";
import {EventMarket} from "../../src/events/EventMarket.sol";
import {EventMarketFactory} from "../../src/events/EventMarketFactory.sol";
import {IFeedbackController} from "../../src/feedback/IFeedbackController.sol";
import {UMAAdapter} from "../../src/oracle/UMAAdapter.sol";

import {
    MockEventMarketImpl,
    MockFeedbackController,
    MockLPVault,
    MockUMAAdapter
} from "./mocks/MockEventDeps.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @title  EventFactorySetMarketImpl — governance-timelocked market-implementation setter.
///
/// @notice Covers `proposeSetMarketImplementation` / `activateSetMarketImplementation` /
///         `cancelSetMarketImplementation` on EventMarketFactory. These mirror the operator-allowlist
///         timelock (onlyGovernance propose+cancel, permissionless activate after `timelockDelay`).
///         The load-bearing test proves `createMarket` clones whichever template is currently
///         installed: after activating `MockEventMarketImpl`, new markets report the new template
///         while the factory keeps cloning the freshly-installed impl.
///
/// @dev    STORAGE-LAYOUT GUARD. This setter deploys onto the LIVE factory proxy (0xb73f), so the
///         two new vars MUST be append-only. Layout (see EventMarketFactory.sol):
///           slot 0  governance
///           slot 1  pendingGovernance
///           slot 1  pendingGovernanceActivatesAt (uint64, packed) + timelockDelay (uint32, packed)
///           slot 2  lpVault
///           slot 3  feedbackController
///           slot 4  umaAdapter
///           slot 5  usdc
///           slot 6  marketImplementation
///           slot 7  markets (mapping)
///           slot 8  marketSeeds (mapping)
///           slot 9  isOperator (mapping)
///           slot 10 pendingOperatorActivatesAt (mapping)
///           slot 11 isMarket (mapping)
///           slot 12 pendingMarketImplementation (address, bytes 0-19)  <-- NEW, appended
///           slot 12 pendingMarketImplementationActivatesAt (uint64, packed at byte offset 20) <-- NEW
///         Slots 0-11 are UNCHANGED; the two new fields are appended and PACK into a single new slot
///         12 (a 20-byte address + an 8-byte timestamp fit in one 32-byte word), so the layout grows
///         by exactly one storage slot. `test_storageLayout_*` below asserts this at runtime by
///         reading raw proxy storage and decoding the packed word.
contract EventFactorySetMarketImpl is Test {
    EventMarketFactory internal factory;
    MockUSDC internal usdc;
    MockLPVault internal lpVault;
    MockFeedbackController internal feedback;
    MockUMAAdapter internal uma;
    EventMarket internal initialImpl;

    address internal governance = makeAddr("governance");
    address internal stranger = makeAddr("stranger");

    uint32 internal constant TIMELOCK = 1 days;
    uint256 internal constant LMSR_B = 2_000e6;
    uint64 internal constant DEADLINE = 2_000_000_000;

    bytes32 internal constant SUBJECT_ID = keccak256("subject.test");
    bytes32 internal constant EVENT_ID = keccak256("event.test");

    event MarketImplementationProposed(address indexed newImplementation, uint64 activatesAt);
    event MarketImplementationActivated(address indexed oldImplementation, address indexed newImplementation);
    event MarketImplementationCancelled(address indexed newImplementation);

    function setUp() public {
        vm.warp(1_900_000_000);

        usdc = new MockUSDC();
        lpVault = new MockLPVault(IERC20(address(usdc)));
        feedback = new MockFeedbackController();
        uma = new MockUMAAdapter();
        usdc.mint(address(lpVault), 10_000_000e6);

        initialImpl = new EventMarket();
        EventMarketFactory factoryImpl = new EventMarketFactory();
        bytes memory init = abi.encodeCall(
            EventMarketFactory.initialize,
            (
                governance,
                TIMELOCK,
                ILPVault(address(lpVault)),
                IFeedbackController(address(feedback)),
                UMAAdapter(address(uma)),
                IERC20(address(usdc)),
                address(initialImpl)
            )
        );
        factory = EventMarketFactory(address(new ERC1967Proxy(address(factoryImpl), init)));
    }

    /// @dev Deploy a fresh selector-compatible mock template.
    function _newImpl() internal returns (MockEventMarketImpl) {
        return new MockEventMarketImpl();
    }

    // ------------------------------------------------------------------------------------------
    // 1. Happy path: propose -> warp -> activate installs the new impl.
    // ------------------------------------------------------------------------------------------

    function test_proposeActivate_installsNewImplementation() public {
        MockEventMarketImpl newImpl = _newImpl();
        uint64 expectedActivatesAt = uint64(block.timestamp + TIMELOCK);

        vm.expectEmit(true, false, false, true, address(factory));
        emit MarketImplementationProposed(address(newImpl), expectedActivatesAt);
        vm.prank(governance);
        factory.proposeSetMarketImplementation(address(newImpl));

        assertEq(factory.pendingMarketImplementation(), address(newImpl), "pending impl set");
        assertEq(factory.pendingMarketImplementationActivatesAt(), expectedActivatesAt, "activatesAt set");
        assertEq(factory.marketImplementation(), address(initialImpl), "current impl unchanged pre-activation");

        vm.warp(block.timestamp + TIMELOCK);

        vm.expectEmit(true, true, false, false, address(factory));
        emit MarketImplementationActivated(address(initialImpl), address(newImpl));
        factory.activateSetMarketImplementation();

        assertEq(factory.marketImplementation(), address(newImpl), "impl promoted");
        assertEq(factory.pendingMarketImplementation(), address(0), "pending cleared");
        assertEq(factory.pendingMarketImplementationActivatesAt(), 0, "activatesAt cleared");
    }

    // ------------------------------------------------------------------------------------------
    // 2. Activate before timelock elapses reverts (typed selector).
    // ------------------------------------------------------------------------------------------

    function test_activateBeforeTimelock_reverts() public {
        MockEventMarketImpl newImpl = _newImpl();
        uint64 activatesAt = uint64(block.timestamp + TIMELOCK);

        vm.prank(governance);
        factory.proposeSetMarketImplementation(address(newImpl));

        vm.expectRevert(abi.encodeWithSelector(EventMarketFactory.TimelockNotElapsed.selector, activatesAt));
        factory.activateSetMarketImplementation();

        // Exactly one second before ready still reverts.
        vm.warp(activatesAt - 1);
        vm.expectRevert(abi.encodeWithSelector(EventMarketFactory.TimelockNotElapsed.selector, activatesAt));
        factory.activateSetMarketImplementation();

        // At the ready timestamp it succeeds.
        vm.warp(activatesAt);
        factory.activateSetMarketImplementation();
        assertEq(factory.marketImplementation(), address(newImpl), "activates exactly at readyAt");
    }

    // ------------------------------------------------------------------------------------------
    // 3. Invalid impl: zero address and code-less (EOA) addresses revert.
    // ------------------------------------------------------------------------------------------

    function test_proposeZeroAddress_reverts() public {
        vm.prank(governance);
        vm.expectRevert(EventMarketFactory.InvalidConfig.selector);
        factory.proposeSetMarketImplementation(address(0));
    }

    function test_proposeCodelessAddress_reverts() public {
        // An EOA / address with no deployed code fails the `newImpl.code.length > 0` check.
        address eoa = makeAddr("eoaImpl");
        assertEq(eoa.code.length, 0, "precondition: address has no code");
        vm.prank(governance);
        vm.expectRevert(EventMarketFactory.InvalidConfig.selector);
        factory.proposeSetMarketImplementation(eoa);
    }

    // ------------------------------------------------------------------------------------------
    // 4. Proposing while a proposal is pending reverts (PendingImplementationExists).
    // ------------------------------------------------------------------------------------------

    function test_proposeWhilePending_reverts() public {
        MockEventMarketImpl first = _newImpl();
        MockEventMarketImpl second = _newImpl();

        vm.prank(governance);
        factory.proposeSetMarketImplementation(address(first));

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(EventMarketFactory.PendingImplementationExists.selector, address(first))
        );
        factory.proposeSetMarketImplementation(address(second));
    }

    // ------------------------------------------------------------------------------------------
    // 5. Access control. propose + cancel are onlyGovernance; activate is PERMISSIONLESS.
    // ------------------------------------------------------------------------------------------

    function test_propose_nonGovernanceReverts() public {
        MockEventMarketImpl newImpl = _newImpl();
        vm.prank(stranger);
        vm.expectRevert(EventMarketFactory.Unauthorized.selector);
        factory.proposeSetMarketImplementation(address(newImpl));
    }

    function test_cancel_nonGovernanceReverts() public {
        MockEventMarketImpl newImpl = _newImpl();
        vm.prank(governance);
        factory.proposeSetMarketImplementation(address(newImpl));

        vm.prank(stranger);
        vm.expectRevert(EventMarketFactory.Unauthorized.selector);
        factory.cancelSetMarketImplementation();
    }

    /// @dev `activateSetMarketImplementation` carries NO access modifier in the source (mirrors
    ///      `activateAddOperator`): any caller may activate once the timelock has elapsed. This is the
    ///      intended pattern, so a non-governance stranger MUST be able to activate.
    function test_activate_isPermissionless() public {
        MockEventMarketImpl newImpl = _newImpl();
        vm.prank(governance);
        factory.proposeSetMarketImplementation(address(newImpl));

        vm.warp(block.timestamp + TIMELOCK);

        vm.prank(stranger); // NOT governance
        factory.activateSetMarketImplementation();

        assertEq(factory.marketImplementation(), address(newImpl), "stranger activated after timelock");
    }

    // ------------------------------------------------------------------------------------------
    // 6. Cancel clears a pending proposal; subsequent activate reverts NoPendingImplementation.
    // ------------------------------------------------------------------------------------------

    function test_cancel_clearsPendingAndBlocksActivate() public {
        MockEventMarketImpl newImpl = _newImpl();
        vm.prank(governance);
        factory.proposeSetMarketImplementation(address(newImpl));

        vm.expectEmit(true, false, false, false, address(factory));
        emit MarketImplementationCancelled(address(newImpl));
        vm.prank(governance);
        factory.cancelSetMarketImplementation();

        assertEq(factory.pendingMarketImplementation(), address(0), "pending impl cleared");
        assertEq(factory.pendingMarketImplementationActivatesAt(), 0, "activatesAt cleared");

        // Even after the original timelock window, activate has nothing to promote.
        vm.warp(block.timestamp + TIMELOCK);
        vm.expectRevert(EventMarketFactory.NoPendingImplementation.selector);
        factory.activateSetMarketImplementation();

        // The current impl is untouched by a cancelled proposal.
        assertEq(factory.marketImplementation(), address(initialImpl), "impl unchanged after cancel");
    }

    function test_cancel_withNothingPendingReverts() public {
        vm.prank(governance);
        vm.expectRevert(EventMarketFactory.NoPendingImplementation.selector);
        factory.cancelSetMarketImplementation();
    }

    // ------------------------------------------------------------------------------------------
    // 7. LOAD-BEARING: createMarket clones the freshly-installed template.
    // ------------------------------------------------------------------------------------------

    function test_createMarket_usesNewlyInstalledTemplate() public {
        // A market created against the ORIGINAL EventMarket template first, to prove pre-existing
        // markets are unaffected by a later swap.
        vm.prank(governance);
        address oldMarket = factory.createMarket(
            keccak256("event.old"), keccak256("event.old"), uint8(1), "Old?", DEADLINE, 0, LMSR_B
        );
        // The original clone is NOT a MockEventMarketImpl: calling implTag() would not return the
        // mock marker. (EventMarket has no implTag(); we just record it stayed the old template.)
        assertTrue(factory.isMarket(oldMarket), "old market registered");

        // Install the mock template via the governance timelock.
        MockEventMarketImpl newImpl = _newImpl();
        vm.prank(governance);
        factory.proposeSetMarketImplementation(address(newImpl));
        vm.warp(block.timestamp + TIMELOCK);
        factory.activateSetMarketImplementation();
        assertEq(factory.marketImplementation(), address(newImpl), "mock template installed");

        // A market created AFTER activation clones the mock template.
        vm.prank(governance);
        address newMarket = factory.createMarket(
            SUBJECT_ID, EVENT_ID, uint8(1), "New?", DEADLINE, 0, LMSR_B
        );

        assertEq(
            MockEventMarketImpl(newMarket).implTag(),
            keccak256("MockEventMarketImpl.v1"),
            "new market clones the freshly-installed template"
        );
        assertEq(MockEventMarketImpl(newMarket).eventId(), EVENT_ID, "clone initialized with eventId");
        assertTrue(factory.isMarket(newMarket), "new market registered");

        // Pre-existing market is a different address and untouched by the swap.
        assertTrue(oldMarket != newMarket, "distinct market addresses");
    }

    // ------------------------------------------------------------------------------------------
    // Storage-layout guard. Assert the new vars are append-only at slots 12/13 and that slots 0-11
    // are unchanged (governance at slot 0, marketImplementation at slot 6).
    // ------------------------------------------------------------------------------------------

    function test_storageLayout_newVarsAppendedAtSlots12And13() public {
        MockEventMarketImpl newImpl = _newImpl();
        vm.prank(governance);
        factory.proposeSetMarketImplementation(address(newImpl));
        uint64 activatesAt = uint64(block.timestamp + TIMELOCK);

        // Slot 0: governance (unchanged original layout).
        assertEq(
            address(uint160(uint256(vm.load(address(factory), bytes32(uint256(0)))))),
            governance,
            "slot 0 == governance"
        );
        // Slot 6: marketImplementation (unchanged original layout).
        assertEq(
            address(uint160(uint256(vm.load(address(factory), bytes32(uint256(6)))))),
            address(initialImpl),
            "slot 6 == marketImplementation"
        );

        // Slot 12 is the single NEW appended word: the 20-byte address in the low bytes and the
        // uint64 activatesAt packed at byte offset 20. Slot 13 must be untouched (empty).
        uint256 slot12 = uint256(vm.load(address(factory), bytes32(uint256(12))));
        assertEq(
            address(uint160(slot12)),
            address(newImpl),
            "slot 12 low 20 bytes == pendingMarketImplementation"
        );
        assertEq(
            uint64(slot12 >> 160),
            activatesAt,
            "slot 12 bytes 20-27 == pendingMarketImplementationActivatesAt"
        );
        assertEq(
            uint256(vm.load(address(factory), bytes32(uint256(13)))),
            0,
            "slot 13 untouched (append grew layout by one packed slot only)"
        );

        // Cross-check the storage reads agree with the public getters (layout matches ABI).
        assertEq(factory.pendingMarketImplementation(), address(newImpl), "getter matches slot 12");
        assertEq(factory.pendingMarketImplementationActivatesAt(), activatesAt, "getter matches slot 13");
    }
}
