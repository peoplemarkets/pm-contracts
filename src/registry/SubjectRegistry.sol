// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {RegistryStorage} from "../libraries/StorageLib.sol";
import {ISubjectRegistry} from "./ISubjectRegistry.sol";

/// @title SubjectRegistry — eligibility, status, and KYC mirror.
/// @notice Tracks the lifecycle state of every listed subject (Person Stock target) and mirrors
///         the off-chain KYC pipeline. Every consumer that needs to gate on subject status or KYC
///         tier reads from this contract.
///
/// @dev    Four roles, three speeds:
///         - `governance` — slow lever (timelocked). Manages role membership and contract
///           upgrades. The 48h baseline matches the spec §3 upgrade policy.
///         - `subjectAdmin` — medium lever (no timelock). Lists subjects, sets policy flags,
///           handles voluntary / involuntary / death delisting flows, and reviews freeze states.
///           Multi-sig in production.
///         - `pauseGuardian` — fast lever (no timelock). Triggers AUTO_PAUSED / COOLDOWN and the
///           AUTO_PAUSED→ACTIVE auto-resume. Designed so a keeper bot can call within seconds of a
///           circuit-breaker trip.
///         - `kycWriter` — narrow lever. Mirrors KYC tier from the off-chain pipeline.
///
/// @dev    Status transitions are validated explicitly per function. The state machine lives in
///         the function bodies (rather than a generic `_requireTransition(from, to)` helper)
///         because each transition has different role permissions and side-effects (writing
///         deadlines, clearing flags), and an explicit form reads clearly for auditors.
///
/// @dev    UUPS upgradeable. State lives in `RegistryStorage`. The `governance` address authorizes
///         upgrades; `governance` is itself a multi-sig in front of an external timelock contract,
///         so an additional in-contract timelock on `_authorizeUpgrade` would only complicate
///         emergency response on a bricked upgrade.
contract SubjectRegistry is Initializable, UUPSUpgradeable, ISubjectRegistry {
    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    uint32 public constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 public constant MAX_TIMELOCK_DELAY = 30 days;

    /// @dev Spec §3: voluntary opt-out triggers a 7-day close window. After the window, anyone may
    ///      call `forceSettle` to transition to DELISTED.
    uint32 public constant DELISTING_WINDOW = 7 days;

    /// @dev Spec §3: death/incapacitation manual flag triggers a 24h halt pending oracle
    ///      confirmation. If unconfirmed at 24h, the halt lifts and the subject returns to ACTIVE.
    uint32 public constant DEATH_PENDING_WINDOW = 24 hours;

    /// @dev KYC tiers per spec §3 are T1–T3 (1, 2, 3). 0 means unverified / no tier.
    uint8 public constant MAX_KYC_TIER = 3;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the registry. One-time, called via the proxy.
    /// @dev    Initial role members are granted directly here without going through the timelock —
    ///         deployment is the moment of trust. After this, every grant/revoke is timelocked.
    /// @param  governance_ Multi-sig that proposes role changes and authorizes upgrades.
    /// @param  timelockDelay_ Seconds. Must be in [MIN_TIMELOCK_DELAY, MAX_TIMELOCK_DELAY].
    /// @param  initialSubjectAdmins  Pre-granted SUBJECT_ADMIN set.
    /// @param  initialPauseGuardians Pre-granted PAUSE_GUARDIAN set.
    /// @param  initialKycWriters     Pre-granted KYC_WRITER set.
    function initialize(
        address governance_,
        uint32 timelockDelay_,
        address[] calldata initialSubjectAdmins,
        address[] calldata initialPauseGuardians,
        address[] calldata initialKycWriters
    )
        external
        initializer
    {
        if (governance_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();

        RegistryStorage.Layout storage s = RegistryStorage.load();
        s.governance = governance_;
        s.timelockDelay = timelockDelay_;

        _grantInitialRoleSet(s.subjectAdmins, initialSubjectAdmins, Role.SUBJECT_ADMIN);
        _grantInitialRoleSet(s.pauseGuardians, initialPauseGuardians, Role.PAUSE_GUARDIAN);
        _grantInitialRoleSet(s.kycWriters, initialKycWriters, Role.KYC_WRITER);
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != RegistryStorage.load().governance) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyAdmin() {
        if (!RegistryStorage.load().subjectAdmins[msg.sender]) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyPauseGuardian() {
        if (!RegistryStorage.load().pauseGuardians[msg.sender]) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyKycWriter() {
        if (!RegistryStorage.load().kycWriters[msg.sender]) revert Unauthorized(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // Listing & policy
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ISubjectRegistry
    function listSubject(bytes32 subjectId, bytes32 categoryId) external onlyAdmin {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        Subject storage subj = s.subjects[subjectId];
        if (subj.status != SubjectStatus.UNREGISTERED) revert SubjectAlreadyRegistered(subjectId);
        if (subj.policyFlag != PolicyFlag.NONE) revert PolicyFlagBlocksListing(subj.policyFlag);

        subj.status = SubjectStatus.ACTIVE;
        subj.listedAt = uint64(block.timestamp);
        subj.statusChangedAt = uint64(block.timestamp);
        subj.categoryId = categoryId;
        emit SubjectListed(subjectId, categoryId);
        emit SubjectStatusChanged(subjectId, SubjectStatus.UNREGISTERED, SubjectStatus.ACTIVE);
    }

    /// @inheritdoc ISubjectRegistry
    function setPolicyFlag(bytes32 subjectId, PolicyFlag flag) external onlyAdmin {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        Subject storage subj = s.subjects[subjectId];
        PolicyFlag old = subj.policyFlag;
        subj.policyFlag = flag;
        emit PolicyFlagSet(subjectId, old, flag);
    }

    // ------------------------------------------------------------------------------------------
    // Voluntary delisting (subject opt-out)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ISubjectRegistry
    function requestDelisting(bytes32 subjectId) external onlyAdmin {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        Subject storage subj = s.subjects[subjectId];
        // From any non-terminal state. DELISTING/DELISTED already terminal-or-pending.
        if (
            subj.status == SubjectStatus.UNREGISTERED || subj.status == SubjectStatus.DELISTING
                || subj.status == SubjectStatus.DELISTED
        ) {
            revert InvalidStatusTransition(subj.status, SubjectStatus.DELISTING);
        }
        SubjectStatus old = subj.status;
        subj.status = SubjectStatus.DELISTING;
        subj.statusChangedAt = uint64(block.timestamp);
        subj.delistingForceSettleAt = uint64(block.timestamp + DELISTING_WINDOW);
        // Death-pending state is mutually exclusive with DELISTING; clear the death deadline.
        subj.deathPendingExpiresAt = 0;
        emit DelistingRequested(subjectId, subj.delistingForceSettleAt);
        emit SubjectStatusChanged(subjectId, old, SubjectStatus.DELISTING);
    }

    /// @inheritdoc ISubjectRegistry
    function forceSettle(bytes32 subjectId) external {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        Subject storage subj = s.subjects[subjectId];
        if (subj.status != SubjectStatus.DELISTING) revert NotInDelisting();
        if (block.timestamp < subj.delistingForceSettleAt) revert WindowNotElapsed(subj.delistingForceSettleAt);
        subj.status = SubjectStatus.DELISTED;
        subj.statusChangedAt = uint64(block.timestamp);
        emit ForceSettled(subjectId);
        emit SubjectStatusChanged(subjectId, SubjectStatus.DELISTING, SubjectStatus.DELISTED);
    }

    // ------------------------------------------------------------------------------------------
    // Involuntary delisting (legal / regulatory)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ISubjectRegistry
    function involuntaryDelist(bytes32 subjectId) external onlyAdmin {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        Subject storage subj = s.subjects[subjectId];
        if (subj.status == SubjectStatus.UNREGISTERED || subj.status == SubjectStatus.DELISTED) {
            revert InvalidStatusTransition(subj.status, SubjectStatus.DELISTED);
        }
        SubjectStatus old = subj.status;
        subj.status = SubjectStatus.DELISTED;
        subj.statusChangedAt = uint64(block.timestamp);
        subj.deathPendingExpiresAt = 0;
        subj.delistingForceSettleAt = 0;
        emit SubjectStatusChanged(subjectId, old, SubjectStatus.DELISTED);
    }

    // ------------------------------------------------------------------------------------------
    // Death / incapacitation
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ISubjectRegistry
    function flagDeathPending(bytes32 subjectId) external onlyAdmin {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        Subject storage subj = s.subjects[subjectId];
        // Allowed from ACTIVE or any pause tier. Not from DELISTING / DELISTED / UNREGISTERED /
        // already-pending-death.
        if (
            subj.status != SubjectStatus.ACTIVE && subj.status != SubjectStatus.AUTO_PAUSED
                && subj.status != SubjectStatus.COOLDOWN && subj.status != SubjectStatus.FROZEN
        ) {
            revert InvalidStatusTransition(subj.status, SubjectStatus.DEATH_PENDING);
        }
        SubjectStatus old = subj.status;
        subj.status = SubjectStatus.DEATH_PENDING;
        subj.statusChangedAt = uint64(block.timestamp);
        subj.deathPendingExpiresAt = uint64(block.timestamp + DEATH_PENDING_WINDOW);
        emit DeathPendingFlagged(subjectId, subj.deathPendingExpiresAt);
        emit SubjectStatusChanged(subjectId, old, SubjectStatus.DEATH_PENDING);
    }

    /// @inheritdoc ISubjectRegistry
    function confirmDeath(bytes32 subjectId) external onlyAdmin {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        Subject storage subj = s.subjects[subjectId];
        if (subj.status != SubjectStatus.DEATH_PENDING) revert NotInDeathPending();
        subj.status = SubjectStatus.DELISTED;
        subj.statusChangedAt = uint64(block.timestamp);
        subj.deathPendingExpiresAt = 0;
        emit SubjectStatusChanged(subjectId, SubjectStatus.DEATH_PENDING, SubjectStatus.DELISTED);
    }

    /// @inheritdoc ISubjectRegistry
    function clearDeathPending(bytes32 subjectId) external {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        Subject storage subj = s.subjects[subjectId];
        if (subj.status != SubjectStatus.DEATH_PENDING) revert NotInDeathPending();
        if (block.timestamp < subj.deathPendingExpiresAt) revert WindowNotElapsed(subj.deathPendingExpiresAt);
        subj.status = SubjectStatus.ACTIVE;
        subj.statusChangedAt = uint64(block.timestamp);
        subj.deathPendingExpiresAt = 0;
        emit SubjectStatusChanged(subjectId, SubjectStatus.DEATH_PENDING, SubjectStatus.ACTIVE);
    }

    // ------------------------------------------------------------------------------------------
    // Pause state machine
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ISubjectRegistry
    function setAutoPaused(bytes32 subjectId, uint8 reasonCode) external onlyPauseGuardian {
        _setPause(subjectId, SubjectStatus.AUTO_PAUSED, reasonCode);
    }

    /// @inheritdoc ISubjectRegistry
    function setCooldown(bytes32 subjectId, uint8 reasonCode) external onlyPauseGuardian {
        _setPause(subjectId, SubjectStatus.COOLDOWN, reasonCode);
    }

    /// @inheritdoc ISubjectRegistry
    function setFrozen(bytes32 subjectId, uint8 reasonCode) external onlyAdmin {
        _setPause(subjectId, SubjectStatus.FROZEN, reasonCode);
    }

    /// @inheritdoc ISubjectRegistry
    function unpauseAuto(bytes32 subjectId) external onlyPauseGuardian {
        _unpauseFrom(subjectId, SubjectStatus.AUTO_PAUSED);
    }

    /// @inheritdoc ISubjectRegistry
    function unpauseCooldown(bytes32 subjectId) external onlyAdmin {
        _unpauseFrom(subjectId, SubjectStatus.COOLDOWN);
    }

    /// @inheritdoc ISubjectRegistry
    function unpauseFrozen(bytes32 subjectId) external onlyAdmin {
        _unpauseFrom(subjectId, SubjectStatus.FROZEN);
    }

    function _setPause(bytes32 subjectId, SubjectStatus newStatus, uint8 reasonCode) internal {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        Subject storage subj = s.subjects[subjectId];
        // Pauses move from ACTIVE only. From a paused tier, transition explicitly through unpause
        // first if a different tier is desired — chaining across tiers (auto→cooldown→frozen) in a
        // single call would obscure the audit trail.
        if (subj.status != SubjectStatus.ACTIVE) revert InvalidStatusTransition(subj.status, newStatus);
        subj.status = newStatus;
        subj.statusChangedAt = uint64(block.timestamp);
        emit PauseTriggered(subjectId, newStatus, reasonCode);
        emit SubjectStatusChanged(subjectId, SubjectStatus.ACTIVE, newStatus);
    }

    function _unpauseFrom(bytes32 subjectId, SubjectStatus expectedFrom) internal {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        Subject storage subj = s.subjects[subjectId];
        if (subj.status != expectedFrom) revert InvalidStatusTransition(subj.status, SubjectStatus.ACTIVE);
        subj.status = SubjectStatus.ACTIVE;
        subj.statusChangedAt = uint64(block.timestamp);
        emit SubjectStatusChanged(subjectId, expectedFrom, SubjectStatus.ACTIVE);
    }

    // ------------------------------------------------------------------------------------------
    // KYC mirror
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ISubjectRegistry
    function setKycTier(address trader, uint8 tier) external onlyKycWriter {
        if (tier > MAX_KYC_TIER) revert InvalidKycTier(tier);
        if (trader == address(0)) revert InvalidConfig();
        RegistryStorage.Layout storage s = RegistryStorage.load();
        uint8 old = s.kycTier[trader];
        s.kycTier[trader] = tier;
        emit KycTierSet(trader, old, tier);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: role management (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ISubjectRegistry
    function proposeRoleChange(address account, Role role, bool grant) external onlyGovernance {
        if (account == address(0)) revert InvalidConfig();
        RegistryStorage.Layout storage s = RegistryStorage.load();

        // Role.NONE is rejected by `_hasRole` below — keeping the validation in one place lets
        // future enum additions fail loudly if `_hasRole` and `_writeRole` aren't updated in lockstep.
        // Block proposing a no-op (grant when held; revoke when not held) so we catch obvious
        // config mistakes early instead of after the timelock has elapsed.
        bool currentlyHeld = _hasRole(s, account, role);
        if (grant && currentlyHeld) revert RoleAlreadyHeld(account, role);
        if (!grant && !currentlyHeld) revert RoleNotHeld(account, role);

        bytes32 key = _roleKey(account, role);
        if (s.pendingRoleChanges[key].exists) revert PendingRoleChangeExists(account, role);

        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingRoleChanges[key] = PendingRoleChange({grant: grant, activatesAt: activatesAt, exists: true});
        emit RoleChangeProposed(account, role, grant, activatesAt);
    }

    /// @inheritdoc ISubjectRegistry
    function activateRoleChange(address account, Role role) external {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        bytes32 key = _roleKey(account, role);
        PendingRoleChange memory p = s.pendingRoleChanges[key];
        if (!p.exists) revert NoPendingRoleChange(account, role);
        if (block.timestamp < p.activatesAt) revert TimelockNotElapsed(p.activatesAt);

        _writeRole(s, account, role, p.grant);
        delete s.pendingRoleChanges[key];
        emit RoleChangeActivated(account, role, p.grant);
    }

    /// @inheritdoc ISubjectRegistry
    function cancelRoleChange(address account, Role role) external onlyGovernance {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        bytes32 key = _roleKey(account, role);
        if (!s.pendingRoleChanges[key].exists) revert NoPendingRoleChange(account, role);
        delete s.pendingRoleChanges[key];
        emit RoleChangeCancelled(account, role);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ISubjectRegistry
    function proposeGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidConfig();
        RegistryStorage.Layout storage s = RegistryStorage.load();
        if (s.pendingGovernanceActivatesAt != 0) revert PendingGovernanceExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingGovernance = newGovernance;
        s.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGovernance, activatesAt);
    }

    /// @inheritdoc ISubjectRegistry
    function activateGovernanceTransfer() external {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        uint64 readyAt = s.pendingGovernanceActivatesAt;
        if (readyAt == 0) revert NoPendingGovernance();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldGov = s.governance;
        address newGov = s.pendingGovernance;
        s.governance = newGov;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferActivated(oldGov, newGov);
    }

    /// @inheritdoc ISubjectRegistry
    function cancelGovernanceTransfer() external onlyGovernance {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        if (s.pendingGovernanceActivatesAt == 0) revert NoPendingGovernance();
        address pending = s.pendingGovernance;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ISubjectRegistry
    function subjectOf(bytes32 subjectId) external view returns (Subject memory) {
        return RegistryStorage.load().subjects[subjectId];
    }

    /// @inheritdoc ISubjectRegistry
    function statusOf(bytes32 subjectId) external view returns (SubjectStatus) {
        return RegistryStorage.load().subjects[subjectId].status;
    }

    /// @inheritdoc ISubjectRegistry
    function isTradeable(bytes32 subjectId) public view returns (bool) {
        Subject storage subj = RegistryStorage.load().subjects[subjectId];
        return subj.status == SubjectStatus.ACTIVE && subj.policyFlag == PolicyFlag.NONE;
    }

    /// @inheritdoc ISubjectRegistry
    function requireTradeable(bytes32 subjectId) external view {
        Subject storage subj = RegistryStorage.load().subjects[subjectId];
        if (subj.status != SubjectStatus.ACTIVE) {
            revert InvalidStatusTransition(subj.status, SubjectStatus.ACTIVE);
        }
        if (subj.policyFlag != PolicyFlag.NONE) revert PolicyFlagBlocksListing(subj.policyFlag);
    }

    /// @inheritdoc ISubjectRegistry
    function kycTierOf(address trader) external view returns (uint8) {
        return RegistryStorage.load().kycTier[trader];
    }

    /// @inheritdoc ISubjectRegistry
    function isAdmin(address account) external view returns (bool) {
        return RegistryStorage.load().subjectAdmins[account];
    }

    /// @inheritdoc ISubjectRegistry
    function isPauseGuardian(address account) external view returns (bool) {
        return RegistryStorage.load().pauseGuardians[account];
    }

    /// @inheritdoc ISubjectRegistry
    function isKycWriter(address account) external view returns (bool) {
        return RegistryStorage.load().kycWriters[account];
    }

    /// @inheritdoc ISubjectRegistry
    function governance() external view returns (address) {
        return RegistryStorage.load().governance;
    }

    /// @inheritdoc ISubjectRegistry
    function timelockDelay() external view returns (uint32) {
        return RegistryStorage.load().timelockDelay;
    }

    /// @inheritdoc ISubjectRegistry
    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        RegistryStorage.Layout storage s = RegistryStorage.load();
        return (s.pendingGovernance, s.pendingGovernanceActivatesAt);
    }

    /// @inheritdoc ISubjectRegistry
    function pendingRoleOf(address account, Role role) external view returns (PendingRoleChange memory) {
        return RegistryStorage.load().pendingRoleChanges[_roleKey(account, role)];
    }

    // ------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------

    function _roleKey(address account, Role role) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, role));
    }

    function _hasRole(RegistryStorage.Layout storage s, address account, Role role) internal view returns (bool) {
        if (role == Role.SUBJECT_ADMIN) return s.subjectAdmins[account];
        if (role == Role.PAUSE_GUARDIAN) return s.pauseGuardians[account];
        if (role == Role.KYC_WRITER) return s.kycWriters[account];
        revert InvalidRole();
    }

    function _writeRole(RegistryStorage.Layout storage s, address account, Role role, bool grant) internal {
        // Validation lives in `_hasRole` and runs during proposeRoleChange. activateRoleChange can
        // only ever be called with a role that is already known to be one of the three valid
        // values, so a missing-case else here is unreachable. Silent fall-through is the right
        // default — louder defensive code would be untestable and rot into coverage debt.
        if (role == Role.SUBJECT_ADMIN) {
            s.subjectAdmins[account] = grant;
        } else if (role == Role.PAUSE_GUARDIAN) {
            s.pauseGuardians[account] = grant;
        } else if (role == Role.KYC_WRITER) {
            s.kycWriters[account] = grant;
        }
    }

    function _grantInitialRoleSet(
        mapping(address => bool) storage roleSet,
        address[] calldata accounts,
        Role role
    )
        internal
    {
        for (uint256 i = 0; i < accounts.length; ++i) {
            address acc = accounts[i];
            if (acc == address(0)) revert InvalidConfig();
            if (roleSet[acc]) revert RoleAlreadyHeld(acc, role);
            roleSet[acc] = true;
            emit RoleChangeActivated(acc, role, true);
        }
    }

    /// @dev UUPS authorization. Upgrades are governance-gated; the timelock is enforced by the
    ///      governance multi-sig executing through its own timelock contract. Same posture as
    ///      OracleRouter — a second in-contract timelock would only complicate emergency response.
    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
