// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test} from "forge-std/Test.sol";

import {ISubjectRegistry} from "../src/registry/ISubjectRegistry.sol";
import {SubjectRegistry} from "../src/registry/SubjectRegistry.sol";

contract SubjectRegistryTest is Test {
    SubjectRegistry internal registry;

    address internal governance = makeAddr("governance");
    address internal admin = makeAddr("admin");
    address internal admin2 = makeAddr("admin2");
    address internal guardian = makeAddr("guardian");
    address internal kycWriter = makeAddr("kycWriter");
    address internal stranger = makeAddr("stranger");
    address internal trader = makeAddr("trader");

    bytes32 internal constant SUBJECT_ID = keccak256("drake");
    bytes32 internal constant CATEGORY_ID = keccak256("musician");
    uint32 internal constant TIMELOCK_DELAY = 2 days;

    // ------------------------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------------------------

    function setUp() public {
        SubjectRegistry impl = new SubjectRegistry();

        address[] memory admins = new address[](2);
        admins[0] = admin;
        admins[1] = admin2;
        address[] memory guardians = new address[](1);
        guardians[0] = guardian;
        address[] memory writers = new address[](1);
        writers[0] = kycWriter;

        bytes memory initData =
            abi.encodeCall(SubjectRegistry.initialize, (governance, TIMELOCK_DELAY, admins, guardians, writers));
        registry = SubjectRegistry(address(new ERC1967Proxy(address(impl), initData)));
    }

    // helpers ---------------------------------------------------------------------------------

    function _list() internal {
        vm.prank(admin);
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);
    }

    function _setStatusTo(ISubjectRegistry.SubjectStatus target) internal {
        _list();
        if (target == ISubjectRegistry.SubjectStatus.ACTIVE) return;
        if (target == ISubjectRegistry.SubjectStatus.AUTO_PAUSED) {
            vm.prank(guardian);
            registry.setAutoPaused(SUBJECT_ID, 1);
        } else if (target == ISubjectRegistry.SubjectStatus.COOLDOWN) {
            vm.prank(guardian);
            registry.setCooldown(SUBJECT_ID, 2);
        } else if (target == ISubjectRegistry.SubjectStatus.FROZEN) {
            vm.prank(admin);
            registry.setFrozen(SUBJECT_ID, 3);
        } else if (target == ISubjectRegistry.SubjectStatus.DEATH_PENDING) {
            vm.prank(admin);
            registry.flagDeathPending(SUBJECT_ID);
        } else if (target == ISubjectRegistry.SubjectStatus.DELISTING) {
            vm.prank(admin);
            registry.requestDelisting(SUBJECT_ID);
        } else if (target == ISubjectRegistry.SubjectStatus.DELISTED) {
            vm.prank(admin);
            registry.involuntaryDelist(SUBJECT_ID);
        }
    }

    // ------------------------------------------------------------------------------------------
    // initialize
    // ------------------------------------------------------------------------------------------

    function test_Initialize_StoresParamsAndRoles() public view {
        assertEq(registry.governance(), governance);
        assertEq(registry.timelockDelay(), TIMELOCK_DELAY);
        assertTrue(registry.isAdmin(admin));
        assertTrue(registry.isAdmin(admin2));
        assertTrue(registry.isPauseGuardian(guardian));
        assertTrue(registry.isKycWriter(kycWriter));
        assertFalse(registry.isAdmin(stranger));
    }

    function test_Initialize_RevertOnZeroGovernance() public {
        SubjectRegistry impl = new SubjectRegistry();
        address[] memory empty = new address[](0);
        bytes memory initData =
            abi.encodeCall(SubjectRegistry.initialize, (address(0), TIMELOCK_DELAY, empty, empty, empty));
        vm.expectRevert(ISubjectRegistry.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooShort() public {
        SubjectRegistry impl = new SubjectRegistry();
        address[] memory empty = new address[](0);
        bytes memory initData =
            abi.encodeCall(SubjectRegistry.initialize, (governance, uint32(1 minutes), empty, empty, empty));
        vm.expectRevert(ISubjectRegistry.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnTimelockTooLong() public {
        SubjectRegistry impl = new SubjectRegistry();
        address[] memory empty = new address[](0);
        bytes memory initData =
            abi.encodeCall(SubjectRegistry.initialize, (governance, uint32(60 days), empty, empty, empty));
        vm.expectRevert(ISubjectRegistry.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnZeroAddressInRoleSet() public {
        SubjectRegistry impl = new SubjectRegistry();
        address[] memory empty = new address[](0);
        address[] memory bad = new address[](1);
        bad[0] = address(0);
        bytes memory initData =
            abi.encodeCall(SubjectRegistry.initialize, (governance, TIMELOCK_DELAY, bad, empty, empty));
        vm.expectRevert(ISubjectRegistry.InvalidConfig.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertOnDuplicateInRoleSet() public {
        SubjectRegistry impl = new SubjectRegistry();
        address[] memory empty = new address[](0);
        address[] memory dups = new address[](2);
        dups[0] = admin;
        dups[1] = admin;
        bytes memory initData =
            abi.encodeCall(SubjectRegistry.initialize, (governance, TIMELOCK_DELAY, dups, empty, empty));
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.RoleAlreadyHeld.selector, admin, ISubjectRegistry.Role.SUBJECT_ADMIN
            )
        );
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_DoubleInitReverts() public {
        address[] memory empty = new address[](0);
        vm.expectRevert();
        registry.initialize(governance, TIMELOCK_DELAY, empty, empty, empty);
    }

    // ------------------------------------------------------------------------------------------
    // listSubject
    // ------------------------------------------------------------------------------------------

    function test_ListSubject_HappyPath() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit ISubjectRegistry.SubjectListed(SUBJECT_ID, CATEGORY_ID);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ISubjectRegistry.SubjectStatusChanged(
            SUBJECT_ID, ISubjectRegistry.SubjectStatus.UNREGISTERED, ISubjectRegistry.SubjectStatus.ACTIVE
        );
        vm.prank(admin);
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);

        ISubjectRegistry.Subject memory s = registry.subjectOf(SUBJECT_ID);
        assertEq(uint8(s.status), uint8(ISubjectRegistry.SubjectStatus.ACTIVE));
        assertEq(s.categoryId, CATEGORY_ID);
        assertEq(s.listedAt, uint64(block.timestamp));
        assertEq(s.statusChangedAt, uint64(block.timestamp));
    }

    function test_ListSubject_RevertOnAlreadyRegistered() public {
        _list();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.SubjectAlreadyRegistered.selector, SUBJECT_ID));
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);
    }

    function test_ListSubject_RevertOnPolicyFlagBlock() public {
        // pre-set MINOR flag on an unregistered subject
        vm.prank(admin);
        registry.setPolicyFlag(SUBJECT_ID, ISubjectRegistry.PolicyFlag.MINOR);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ISubjectRegistry.PolicyFlagBlocksListing.selector, ISubjectRegistry.PolicyFlag.MINOR)
        );
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);
    }

    function test_ListSubject_RevertOnNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.listSubject(SUBJECT_ID, CATEGORY_ID);
    }

    // ------------------------------------------------------------------------------------------
    // setPolicyFlag
    // ------------------------------------------------------------------------------------------

    function test_SetPolicyFlag_HappyPath() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit ISubjectRegistry.PolicyFlagSet(
            SUBJECT_ID, ISubjectRegistry.PolicyFlag.NONE, ISubjectRegistry.PolicyFlag.US_POLITICIAN_ELECTION_YEAR
        );
        vm.prank(admin);
        registry.setPolicyFlag(SUBJECT_ID, ISubjectRegistry.PolicyFlag.US_POLITICIAN_ELECTION_YEAR);
        assertEq(
            uint8(registry.subjectOf(SUBJECT_ID).policyFlag),
            uint8(ISubjectRegistry.PolicyFlag.US_POLITICIAN_ELECTION_YEAR)
        );
    }

    function test_SetPolicyFlag_PostListingBlocksTradeable() public {
        _list();
        assertTrue(registry.isTradeable(SUBJECT_ID));
        vm.prank(admin);
        registry.setPolicyFlag(SUBJECT_ID, ISubjectRegistry.PolicyFlag.OTHER_BLOCKED);
        assertFalse(registry.isTradeable(SUBJECT_ID));
    }

    function test_SetPolicyFlag_RevertOnNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.setPolicyFlag(SUBJECT_ID, ISubjectRegistry.PolicyFlag.MINOR);
    }

    // ------------------------------------------------------------------------------------------
    // requestDelisting / forceSettle
    // ------------------------------------------------------------------------------------------

    function test_RequestDelisting_FromActive() public {
        _list();
        uint64 before = uint64(block.timestamp);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ISubjectRegistry.DelistingRequested(SUBJECT_ID, before + 7 days);
        vm.prank(admin);
        registry.requestDelisting(SUBJECT_ID);
        ISubjectRegistry.Subject memory s = registry.subjectOf(SUBJECT_ID);
        assertEq(uint8(s.status), uint8(ISubjectRegistry.SubjectStatus.DELISTING));
        assertEq(s.delistingForceSettleAt, before + 7 days);
    }

    function test_RequestDelisting_FromAnyPauseTier() public {
        // auto-paused
        _setStatusTo(ISubjectRegistry.SubjectStatus.AUTO_PAUSED);
        vm.prank(admin);
        registry.requestDelisting(SUBJECT_ID);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.DELISTING));
    }

    function test_RequestDelisting_RevertFromUnregistered() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.UNREGISTERED,
                ISubjectRegistry.SubjectStatus.DELISTING
            )
        );
        registry.requestDelisting(SUBJECT_ID);
    }

    function test_RequestDelisting_RevertFromDelisting() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.DELISTING);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.DELISTING,
                ISubjectRegistry.SubjectStatus.DELISTING
            )
        );
        registry.requestDelisting(SUBJECT_ID);
    }

    function test_RequestDelisting_RevertFromDelisted() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.DELISTED);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.DELISTED,
                ISubjectRegistry.SubjectStatus.DELISTING
            )
        );
        registry.requestDelisting(SUBJECT_ID);
    }

    function test_RequestDelisting_RevertOnNonAdmin() public {
        _list();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.requestDelisting(SUBJECT_ID);
    }

    function test_RequestDelisting_ClearsDeathPendingFromMixedFlow() public {
        // edge case: subject is ACTIVE → flag death → admin override to delist
        _setStatusTo(ISubjectRegistry.SubjectStatus.DEATH_PENDING);
        vm.prank(admin);
        registry.requestDelisting(SUBJECT_ID);
        assertEq(registry.subjectOf(SUBJECT_ID).deathPendingExpiresAt, 0);
    }

    function test_ForceSettle_AfterWindowPermissionless() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.DELISTING);
        uint64 readyAt = registry.subjectOf(SUBJECT_ID).delistingForceSettleAt;
        vm.warp(readyAt);
        vm.prank(stranger); // permissionless
        vm.expectEmit(true, false, false, true, address(registry));
        emit ISubjectRegistry.ForceSettled(SUBJECT_ID);
        registry.forceSettle(SUBJECT_ID);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.DELISTED));
    }

    function test_ForceSettle_RevertBeforeWindow() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.DELISTING);
        uint64 readyAt = registry.subjectOf(SUBJECT_ID).delistingForceSettleAt;
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.WindowNotElapsed.selector, readyAt));
        registry.forceSettle(SUBJECT_ID);
    }

    function test_ForceSettle_RevertWhenNotInDelisting() public {
        _list();
        vm.expectRevert(ISubjectRegistry.NotInDelisting.selector);
        registry.forceSettle(SUBJECT_ID);
    }

    // ------------------------------------------------------------------------------------------
    // involuntaryDelist
    // ------------------------------------------------------------------------------------------

    function test_InvoluntaryDelist_FromActive() public {
        _list();
        vm.prank(admin);
        registry.involuntaryDelist(SUBJECT_ID);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.DELISTED));
    }

    function test_InvoluntaryDelist_FromDeathPending() public {
        // emergency override path
        _setStatusTo(ISubjectRegistry.SubjectStatus.DEATH_PENDING);
        vm.prank(admin);
        registry.involuntaryDelist(SUBJECT_ID);
        ISubjectRegistry.Subject memory s = registry.subjectOf(SUBJECT_ID);
        assertEq(uint8(s.status), uint8(ISubjectRegistry.SubjectStatus.DELISTED));
        assertEq(s.deathPendingExpiresAt, 0);
    }

    function test_InvoluntaryDelist_RevertFromUnregistered() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.UNREGISTERED,
                ISubjectRegistry.SubjectStatus.DELISTED
            )
        );
        registry.involuntaryDelist(SUBJECT_ID);
    }

    function test_InvoluntaryDelist_RevertFromDelisted() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.DELISTED);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.DELISTED,
                ISubjectRegistry.SubjectStatus.DELISTED
            )
        );
        registry.involuntaryDelist(SUBJECT_ID);
    }

    function test_InvoluntaryDelist_RevertOnNonAdmin() public {
        _list();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.involuntaryDelist(SUBJECT_ID);
    }

    // ------------------------------------------------------------------------------------------
    // Death flow
    // ------------------------------------------------------------------------------------------

    function test_FlagDeathPending_FromActive() public {
        _list();
        uint64 before = uint64(block.timestamp);
        vm.expectEmit(true, false, false, true, address(registry));
        emit ISubjectRegistry.DeathPendingFlagged(SUBJECT_ID, before + 24 hours);
        vm.prank(admin);
        registry.flagDeathPending(SUBJECT_ID);
        assertEq(registry.subjectOf(SUBJECT_ID).deathPendingExpiresAt, before + 24 hours);
    }

    function test_FlagDeathPending_FromAnyPauseTier() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.FROZEN);
        vm.prank(admin);
        registry.flagDeathPending(SUBJECT_ID);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.DEATH_PENDING));
    }

    function test_FlagDeathPending_RevertFromDelisting() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.DELISTING);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.DELISTING,
                ISubjectRegistry.SubjectStatus.DEATH_PENDING
            )
        );
        registry.flagDeathPending(SUBJECT_ID);
    }

    function test_FlagDeathPending_RevertFromAlreadyPending() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.DEATH_PENDING);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.DEATH_PENDING,
                ISubjectRegistry.SubjectStatus.DEATH_PENDING
            )
        );
        registry.flagDeathPending(SUBJECT_ID);
    }

    function test_FlagDeathPending_RevertOnNonAdmin() public {
        _list();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.flagDeathPending(SUBJECT_ID);
    }

    function test_ConfirmDeath_HappyPath() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.DEATH_PENDING);
        vm.prank(admin);
        registry.confirmDeath(SUBJECT_ID);
        ISubjectRegistry.Subject memory s = registry.subjectOf(SUBJECT_ID);
        assertEq(uint8(s.status), uint8(ISubjectRegistry.SubjectStatus.DELISTED));
        assertEq(s.deathPendingExpiresAt, 0);
    }

    function test_ConfirmDeath_RevertWhenNotInDeathPending() public {
        _list();
        vm.prank(admin);
        vm.expectRevert(ISubjectRegistry.NotInDeathPending.selector);
        registry.confirmDeath(SUBJECT_ID);
    }

    function test_ConfirmDeath_RevertOnNonAdmin() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.DEATH_PENDING);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.confirmDeath(SUBJECT_ID);
    }

    function test_ClearDeathPending_AfterWindowPermissionless() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.DEATH_PENDING);
        uint64 readyAt = registry.subjectOf(SUBJECT_ID).deathPendingExpiresAt;
        vm.warp(readyAt);
        vm.prank(stranger);
        registry.clearDeathPending(SUBJECT_ID);
        ISubjectRegistry.Subject memory s = registry.subjectOf(SUBJECT_ID);
        assertEq(uint8(s.status), uint8(ISubjectRegistry.SubjectStatus.ACTIVE));
        assertEq(s.deathPendingExpiresAt, 0);
    }

    function test_ClearDeathPending_RevertBeforeWindow() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.DEATH_PENDING);
        uint64 readyAt = registry.subjectOf(SUBJECT_ID).deathPendingExpiresAt;
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.WindowNotElapsed.selector, readyAt));
        registry.clearDeathPending(SUBJECT_ID);
    }

    function test_ClearDeathPending_RevertWhenNotInDeathPending() public {
        _list();
        vm.expectRevert(ISubjectRegistry.NotInDeathPending.selector);
        registry.clearDeathPending(SUBJECT_ID);
    }

    // ------------------------------------------------------------------------------------------
    // Pause state machine
    // ------------------------------------------------------------------------------------------

    function test_SetAutoPaused_HappyPath() public {
        _list();
        vm.expectEmit(true, false, false, true, address(registry));
        emit ISubjectRegistry.PauseTriggered(SUBJECT_ID, ISubjectRegistry.SubjectStatus.AUTO_PAUSED, 1);
        vm.prank(guardian);
        registry.setAutoPaused(SUBJECT_ID, 1);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.AUTO_PAUSED));
    }

    function test_SetAutoPaused_RevertFromNonActive() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.AUTO_PAUSED);
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.AUTO_PAUSED,
                ISubjectRegistry.SubjectStatus.AUTO_PAUSED
            )
        );
        registry.setAutoPaused(SUBJECT_ID, 1);
    }

    function test_SetAutoPaused_RevertOnNonGuardian() public {
        _list();
        vm.prank(admin); // admin is NOT a guardian
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, admin));
        registry.setAutoPaused(SUBJECT_ID, 1);
    }

    function test_SetCooldown_HappyPath() public {
        _list();
        vm.prank(guardian);
        registry.setCooldown(SUBJECT_ID, 2);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.COOLDOWN));
    }

    function test_SetCooldown_RevertOnNonGuardian() public {
        _list();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.setCooldown(SUBJECT_ID, 2);
    }

    function test_SetFrozen_HappyPath() public {
        _list();
        vm.prank(admin);
        registry.setFrozen(SUBJECT_ID, 3);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.FROZEN));
    }

    function test_SetFrozen_RevertOnNonAdmin() public {
        _list();
        vm.prank(guardian); // guardian alone CAN'T freeze; admin review required
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, guardian));
        registry.setFrozen(SUBJECT_ID, 3);
    }

    function test_UnpauseAuto_HappyPath() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.AUTO_PAUSED);
        vm.prank(guardian);
        registry.unpauseAuto(SUBJECT_ID);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.ACTIVE));
    }

    function test_UnpauseAuto_RevertWhenNotInAutoPaused() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.COOLDOWN);
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.COOLDOWN,
                ISubjectRegistry.SubjectStatus.ACTIVE
            )
        );
        registry.unpauseAuto(SUBJECT_ID);
    }

    function test_UnpauseAuto_RevertOnNonGuardian() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.AUTO_PAUSED);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.unpauseAuto(SUBJECT_ID);
    }

    function test_UnpauseCooldown_HappyPath() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.COOLDOWN);
        vm.prank(admin);
        registry.unpauseCooldown(SUBJECT_ID);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.ACTIVE));
    }

    function test_UnpauseCooldown_RevertWhenNotInCooldown() public {
        _list();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.ACTIVE,
                ISubjectRegistry.SubjectStatus.ACTIVE
            )
        );
        registry.unpauseCooldown(SUBJECT_ID);
    }

    function test_UnpauseCooldown_RevertOnNonAdmin() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.COOLDOWN);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, guardian));
        registry.unpauseCooldown(SUBJECT_ID);
    }

    function test_UnpauseFrozen_HappyPath() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.FROZEN);
        vm.prank(admin);
        registry.unpauseFrozen(SUBJECT_ID);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.ACTIVE));
    }

    function test_UnpauseFrozen_RevertWhenNotInFrozen() public {
        _list();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.ACTIVE,
                ISubjectRegistry.SubjectStatus.ACTIVE
            )
        );
        registry.unpauseFrozen(SUBJECT_ID);
    }

    function test_UnpauseFrozen_RevertOnNonAdmin() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.FROZEN);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.unpauseFrozen(SUBJECT_ID);
    }

    // ------------------------------------------------------------------------------------------
    // KYC mirror
    // ------------------------------------------------------------------------------------------

    function test_SetKycTier_HappyPath() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit ISubjectRegistry.KycTierSet(trader, 0, 2);
        vm.prank(kycWriter);
        registry.setKycTier(trader, 2);
        assertEq(registry.kycTierOf(trader), 2);
    }

    function test_SetKycTier_RevertOnTierTooHigh() public {
        vm.prank(kycWriter);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.InvalidKycTier.selector, uint8(4)));
        registry.setKycTier(trader, 4);
    }

    function test_SetKycTier_RevertOnZeroAddress() public {
        vm.prank(kycWriter);
        vm.expectRevert(ISubjectRegistry.InvalidConfig.selector);
        registry.setKycTier(address(0), 1);
    }

    function test_SetKycTier_RevertOnNonWriter() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.setKycTier(trader, 1);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: role management
    // ------------------------------------------------------------------------------------------

    function test_RoleChange_GrantHappyPath() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(governance);
        registry.proposeRoleChange(newAdmin, ISubjectRegistry.Role.SUBJECT_ADMIN, true);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(stranger); // permissionless activation
        registry.activateRoleChange(newAdmin, ISubjectRegistry.Role.SUBJECT_ADMIN);
        assertTrue(registry.isAdmin(newAdmin));
    }

    function test_RoleChange_RevokeHappyPath() public {
        // revoke admin2 to keep `admin` working in the rest of the suite
        vm.prank(governance);
        registry.proposeRoleChange(admin2, ISubjectRegistry.Role.SUBJECT_ADMIN, false);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        registry.activateRoleChange(admin2, ISubjectRegistry.Role.SUBJECT_ADMIN);
        assertFalse(registry.isAdmin(admin2));
    }

    function test_ProposeRoleChange_GrantsAndRevokesAcrossAllRoleTypes() public {
        address acc = makeAddr("multi");
        // grant guardian
        vm.startPrank(governance);
        registry.proposeRoleChange(acc, ISubjectRegistry.Role.PAUSE_GUARDIAN, true);
        vm.stopPrank();
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        registry.activateRoleChange(acc, ISubjectRegistry.Role.PAUSE_GUARDIAN);
        assertTrue(registry.isPauseGuardian(acc));

        // grant kyc writer
        vm.prank(governance);
        registry.proposeRoleChange(acc, ISubjectRegistry.Role.KYC_WRITER, true);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        registry.activateRoleChange(acc, ISubjectRegistry.Role.KYC_WRITER);
        assertTrue(registry.isKycWriter(acc));
    }

    function test_ProposeRoleChange_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.proposeRoleChange(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN, true);
    }

    function test_ProposeRoleChange_RevertOnZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(ISubjectRegistry.InvalidConfig.selector);
        registry.proposeRoleChange(address(0), ISubjectRegistry.Role.SUBJECT_ADMIN, true);
    }

    function test_ProposeRoleChange_RevertOnRoleNone() public {
        vm.prank(governance);
        vm.expectRevert(ISubjectRegistry.InvalidRole.selector);
        registry.proposeRoleChange(stranger, ISubjectRegistry.Role.NONE, true);
    }

    function test_ProposeRoleChange_RevertOnRedundantGrant() public {
        // admin already has SUBJECT_ADMIN
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.RoleAlreadyHeld.selector, admin, ISubjectRegistry.Role.SUBJECT_ADMIN
            )
        );
        registry.proposeRoleChange(admin, ISubjectRegistry.Role.SUBJECT_ADMIN, true);
    }

    function test_ProposeRoleChange_RevertOnRedundantRevoke() public {
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(ISubjectRegistry.RoleNotHeld.selector, stranger, ISubjectRegistry.Role.SUBJECT_ADMIN)
        );
        registry.proposeRoleChange(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN, false);
    }

    function test_ProposeRoleChange_RevertOnPendingExists() public {
        vm.startPrank(governance);
        registry.proposeRoleChange(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.PendingRoleChangeExists.selector, stranger, ISubjectRegistry.Role.SUBJECT_ADMIN
            )
        );
        registry.proposeRoleChange(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN, true);
        vm.stopPrank();
    }

    function test_ActivateRoleChange_RevertOnNoPending() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.NoPendingRoleChange.selector, stranger, ISubjectRegistry.Role.SUBJECT_ADMIN
            )
        );
        registry.activateRoleChange(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN);
    }

    function test_ActivateRoleChange_RevertBeforeTimelock() public {
        vm.prank(governance);
        registry.proposeRoleChange(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN, true);
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.TimelockNotElapsed.selector, readyAt));
        registry.activateRoleChange(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN);
    }

    function test_CancelRoleChange_HappyPath() public {
        vm.prank(governance);
        registry.proposeRoleChange(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN, true);
        vm.expectEmit(true, true, false, true, address(registry));
        emit ISubjectRegistry.RoleChangeCancelled(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN);
        vm.prank(governance);
        registry.cancelRoleChange(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN);
        assertFalse(registry.pendingRoleOf(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN).exists);
    }

    function test_CancelRoleChange_RevertOnNonGovernance() public {
        vm.prank(governance);
        registry.proposeRoleChange(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN, true);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.cancelRoleChange(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN);
    }

    function test_CancelRoleChange_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.NoPendingRoleChange.selector, stranger, ISubjectRegistry.Role.SUBJECT_ADMIN
            )
        );
        registry.cancelRoleChange(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: transfer
    // ------------------------------------------------------------------------------------------

    function test_GovernanceTransfer_HappyPath() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        registry.proposeGovernanceTransfer(newGov);
        (address pending, uint64 readyAt) = registry.pendingGovernance();
        assertEq(pending, newGov);
        assertEq(readyAt, uint64(block.timestamp + TIMELOCK_DELAY));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(stranger);
        registry.activateGovernanceTransfer();
        assertEq(registry.governance(), newGov);
    }

    function test_ProposeGovernanceTransfer_RevertOnNonGovernance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.proposeGovernanceTransfer(makeAddr("newGov"));
    }

    function test_ProposeGovernanceTransfer_RevertOnZero() public {
        vm.prank(governance);
        vm.expectRevert(ISubjectRegistry.InvalidConfig.selector);
        registry.proposeGovernanceTransfer(address(0));
    }

    function test_ProposeGovernanceTransfer_RevertOnPendingExists() public {
        vm.startPrank(governance);
        registry.proposeGovernanceTransfer(makeAddr("g1"));
        vm.expectRevert(ISubjectRegistry.PendingGovernanceExists.selector);
        registry.proposeGovernanceTransfer(makeAddr("g2"));
        vm.stopPrank();
    }

    function test_ActivateGovernanceTransfer_RevertOnNoPending() public {
        vm.expectRevert(ISubjectRegistry.NoPendingGovernance.selector);
        registry.activateGovernanceTransfer();
    }

    function test_ActivateGovernanceTransfer_RevertBeforeTimelock() public {
        vm.prank(governance);
        registry.proposeGovernanceTransfer(makeAddr("g1"));
        uint64 readyAt = uint64(block.timestamp + TIMELOCK_DELAY);
        vm.warp(uint256(readyAt) - 1);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.TimelockNotElapsed.selector, readyAt));
        registry.activateGovernanceTransfer();
    }

    function test_CancelGovernanceTransfer_HappyPath() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        registry.proposeGovernanceTransfer(newGov);
        vm.prank(governance);
        registry.cancelGovernanceTransfer();
        (address pending, uint64 readyAt) = registry.pendingGovernance();
        assertEq(pending, address(0));
        assertEq(readyAt, 0);
    }

    function test_CancelGovernanceTransfer_RevertOnNonGovernance() public {
        vm.prank(governance);
        registry.proposeGovernanceTransfer(makeAddr("newGov"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.cancelGovernanceTransfer();
    }

    function test_CancelGovernanceTransfer_RevertOnNoPending() public {
        vm.prank(governance);
        vm.expectRevert(ISubjectRegistry.NoPendingGovernance.selector);
        registry.cancelGovernanceTransfer();
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function test_IsTradeable_AllStatuses() public {
        // unregistered → false
        assertFalse(registry.isTradeable(SUBJECT_ID));

        // active + no flag → true
        _list();
        assertTrue(registry.isTradeable(SUBJECT_ID));

        // active + flag → false
        vm.prank(admin);
        registry.setPolicyFlag(SUBJECT_ID, ISubjectRegistry.PolicyFlag.MINOR);
        assertFalse(registry.isTradeable(SUBJECT_ID));
        // clear and re-test
        vm.prank(admin);
        registry.setPolicyFlag(SUBJECT_ID, ISubjectRegistry.PolicyFlag.NONE);
        assertTrue(registry.isTradeable(SUBJECT_ID));

        // each non-active status → false
        vm.prank(guardian);
        registry.setAutoPaused(SUBJECT_ID, 1);
        assertFalse(registry.isTradeable(SUBJECT_ID));
    }

    function test_RequireTradeable_RevertsAppropriately() public {
        // unregistered
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.UNREGISTERED,
                ISubjectRegistry.SubjectStatus.ACTIVE
            )
        );
        registry.requireTradeable(SUBJECT_ID);

        // listed
        _list();
        registry.requireTradeable(SUBJECT_ID); // no revert

        // listed + flag
        vm.prank(admin);
        registry.setPolicyFlag(SUBJECT_ID, ISubjectRegistry.PolicyFlag.MINOR);
        vm.expectRevert(
            abi.encodeWithSelector(ISubjectRegistry.PolicyFlagBlocksListing.selector, ISubjectRegistry.PolicyFlag.MINOR)
        );
        registry.requireTradeable(SUBJECT_ID);
    }

    function test_PendingRoleOf_ReflectsProposal() public {
        vm.prank(governance);
        registry.proposeRoleChange(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN, true);
        ISubjectRegistry.PendingRoleChange memory p =
            registry.pendingRoleOf(stranger, ISubjectRegistry.Role.SUBJECT_ADMIN);
        assertTrue(p.exists);
        assertTrue(p.grant);
        assertEq(p.activatesAt, uint64(block.timestamp + TIMELOCK_DELAY));
    }

    // ------------------------------------------------------------------------------------------
    // Fix #8 — auto-pause expiry
    // ------------------------------------------------------------------------------------------

    function test_SetAutoPaused_WritesExpiry() public {
        _list();
        uint64 before = uint64(block.timestamp);
        vm.prank(guardian);
        registry.setAutoPaused(SUBJECT_ID, 1);
        assertEq(registry.autoPauseExpiresAt(SUBJECT_ID), before + 30);
    }

    function test_UnpauseAuto_GuardianBeforeDeadline() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.AUTO_PAUSED);
        vm.warp(block.timestamp + 1);
        vm.prank(guardian);
        registry.unpauseAuto(SUBJECT_ID);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.ACTIVE));
        assertEq(registry.autoPauseExpiresAt(SUBJECT_ID), 0);
    }

    function test_UnpauseAuto_PermissionlessAfterDeadline() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.AUTO_PAUSED);
        uint64 readyAt = registry.autoPauseExpiresAt(SUBJECT_ID);
        vm.warp(uint256(readyAt) + 1);
        vm.prank(stranger);
        registry.unpauseAuto(SUBJECT_ID);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.ACTIVE));
    }

    function test_UnpauseAuto_PermissionlessAtExactDeadline() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.AUTO_PAUSED);
        uint64 readyAt = registry.autoPauseExpiresAt(SUBJECT_ID);
        vm.warp(uint256(readyAt));
        vm.prank(stranger);
        registry.unpauseAuto(SUBJECT_ID);
        assertEq(uint8(registry.statusOf(SUBJECT_ID)), uint8(ISubjectRegistry.SubjectStatus.ACTIVE));
    }

    function test_UnpauseAuto_RevertOnStrangerBeforeDeadline() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.AUTO_PAUSED);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.unpauseAuto(SUBJECT_ID);
    }

    function test_AutoPauseRedeposit_ResetsDeadline() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.AUTO_PAUSED);
        uint64 firstDeadline = registry.autoPauseExpiresAt(SUBJECT_ID);
        // unpause early via guardian
        vm.warp(uint256(firstDeadline) - 5);
        vm.prank(guardian);
        registry.unpauseAuto(SUBJECT_ID);

        // re-pause; new deadline should reflect current time, NOT carry the old one
        vm.warp(block.timestamp + 100);
        vm.prank(guardian);
        registry.setAutoPaused(SUBJECT_ID, 1);
        uint64 secondDeadline = registry.autoPauseExpiresAt(SUBJECT_ID);
        assertEq(secondDeadline, uint64(block.timestamp + 30));
        assertGt(secondDeadline, firstDeadline);
    }

    function test_UnpauseAuto_ClearsDeadline() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.AUTO_PAUSED);
        vm.warp(block.timestamp + 31);
        vm.prank(stranger);
        registry.unpauseAuto(SUBJECT_ID);
        assertEq(registry.autoPauseExpiresAt(SUBJECT_ID), 0);
    }

    function test_UnpauseAuto_RevertOnCooldown() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.COOLDOWN);
        vm.warp(block.timestamp + 1000);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.COOLDOWN,
                ISubjectRegistry.SubjectStatus.ACTIVE
            )
        );
        registry.unpauseAuto(SUBJECT_ID);
    }

    function test_UnpauseAuto_RevertOnFrozen() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.FROZEN);
        vm.warp(block.timestamp + 1000);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISubjectRegistry.InvalidStatusTransition.selector,
                ISubjectRegistry.SubjectStatus.FROZEN,
                ISubjectRegistry.SubjectStatus.ACTIVE
            )
        );
        registry.unpauseAuto(SUBJECT_ID);
    }

    function test_AutoPauseExpiresAt_View_MatchesStruct() public {
        _setStatusTo(ISubjectRegistry.SubjectStatus.AUTO_PAUSED);
        ISubjectRegistry.Subject memory s = registry.subjectOf(SUBJECT_ID);
        assertEq(s.autoPauseExpiresAt, registry.autoPauseExpiresAt(SUBJECT_ID));
    }

    // ------------------------------------------------------------------------------------------
    // UUPS upgrade authorization
    // ------------------------------------------------------------------------------------------

    function test_UpgradeAuthorization_RevertOnNonGovernance() public {
        SubjectRegistry newImpl = new SubjectRegistry();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISubjectRegistry.Unauthorized.selector, stranger));
        registry.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeAuthorization_GovernanceCanUpgrade() public {
        SubjectRegistry newImpl = new SubjectRegistry();
        vm.prank(governance);
        registry.upgradeToAndCall(address(newImpl), "");
        // sanity: state preserved post-upgrade
        assertEq(registry.governance(), governance);
    }
}
