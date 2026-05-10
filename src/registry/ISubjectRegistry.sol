// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @notice Subject metadata, status state-machine, KYC mirror, and role management.
/// @dev    Owns its types; `RegistryStorage` imports them so both the storage layout and external
///         API agree by construction. Same pattern as `IOracleRouter` / `OracleStorage`.
interface ISubjectRegistry {
    // ------------------------------------------------------------------------------------------
    // Type re-exports — stable references for consumers
    // ------------------------------------------------------------------------------------------

    /// @dev Status transitions:
    ///        UNREGISTERED  --listSubject--> ACTIVE
    ///        ACTIVE        --setAutoPaused--> AUTO_PAUSED   (5%/30s; pauseGuardian)
    ///        ACTIVE        --setCooldown--> COOLDOWN        (10%/30m; pauseGuardian)
    ///        ACTIVE        --setFrozen--> FROZEN            (20%/1h; subjectAdmin)
    ///        AUTO_PAUSED   --unpauseAuto--> ACTIVE          (after 30s; pauseGuardian)
    ///        COOLDOWN      --unpauseCooldown--> ACTIVE      (subjectAdmin review)
    ///        FROZEN        --unpauseFrozen--> ACTIVE        (subjectAdmin review)
    ///        ACTIVE/paused --requestDelisting--> DELISTING  (7-day close window)
    ///        DELISTING     --forceSettle--> DELISTED        (permissionless after window)
    ///        ACTIVE/paused --involuntaryDelist--> DELISTED  (immediate; legal/regulatory)
    ///        ACTIVE/paused --flagDeathPending--> DEATH_PENDING (24h oracle confirmation window)
    ///        DEATH_PENDING --confirmDeath--> DELISTED       (subjectAdmin)
    ///        DEATH_PENDING --clearDeathPending--> ACTIVE    (permissionless after window)
    ///        DELISTED      --(terminal)
    enum SubjectStatus {
        UNREGISTERED,
        ACTIVE,
        AUTO_PAUSED,
        COOLDOWN,
        FROZEN,
        DEATH_PENDING,
        DELISTING,
        DELISTED
    }

    enum PolicyFlag {
        NONE,
        US_POLITICIAN_ELECTION_YEAR,
        MINOR,
        OTHER_BLOCKED
    }

    enum Role {
        NONE,
        SUBJECT_ADMIN,
        PAUSE_GUARDIAN,
        KYC_WRITER
    }

    /// @dev Carrying timestamps for `deathPendingExpiresAt`, `delistingForceSettleAt`, and
    ///      `autoPauseExpiresAt` makes the state machine auditable from on-chain reads alone.
    struct Subject {
        SubjectStatus status;
        PolicyFlag policyFlag;
        uint64 listedAt;
        uint64 statusChangedAt;
        bytes32 categoryId;
        uint64 deathPendingExpiresAt;
        uint64 delistingForceSettleAt;
        uint64 autoPauseExpiresAt;
    }

    /// @dev Pending role grant or revoke. Keyed by keccak(account, role) — at most one pending
    ///      change per (account, role) pair.
    struct PendingRoleChange {
        bool grant;
        uint64 activatesAt;
        bool exists;
    }

    // ------------------------------------------------------------------------------------------
    // Listing & lifecycle (subjectAdmin)
    // ------------------------------------------------------------------------------------------

    function listSubject(bytes32 subjectId, bytes32 categoryId) external;

    function setPolicyFlag(bytes32 subjectId, PolicyFlag flag) external;

    function requestDelisting(bytes32 subjectId) external;

    /// @notice Permissionless once `delistingForceSettleAt` has elapsed.
    function forceSettle(bytes32 subjectId) external;

    function involuntaryDelist(bytes32 subjectId) external;

    function flagDeathPending(bytes32 subjectId) external;

    function confirmDeath(bytes32 subjectId) external;

    /// @notice Permissionless once the 24h death-pending window has elapsed without confirmation.
    function clearDeathPending(bytes32 subjectId) external;

    // ------------------------------------------------------------------------------------------
    // Pause state machine
    // ------------------------------------------------------------------------------------------

    /// @notice 5%/30s trigger. PauseGuardian only.
    function setAutoPaused(bytes32 subjectId, uint8 reasonCode) external;

    /// @notice 10%/30m trigger. PauseGuardian only.
    function setCooldown(bytes32 subjectId, uint8 reasonCode) external;

    /// @notice 20%/1h trigger. SubjectAdmin only — admin review is required to even enter this state.
    function setFrozen(bytes32 subjectId, uint8 reasonCode) external;

    function unpauseAuto(bytes32 subjectId) external;
    function unpauseCooldown(bytes32 subjectId) external;
    function unpauseFrozen(bytes32 subjectId) external;

    // ------------------------------------------------------------------------------------------
    // KYC mirror (kycWriter)
    // ------------------------------------------------------------------------------------------

    function setKycTier(address trader, uint8 tier) external;

    // ------------------------------------------------------------------------------------------
    // Governance: role management (timelocked)
    // ------------------------------------------------------------------------------------------

    function proposeRoleChange(address account, Role role, bool grant) external;
    function activateRoleChange(address account, Role role) external;
    function cancelRoleChange(address account, Role role) external;

    function proposeGovernanceTransfer(address newGovernance) external;
    function activateGovernanceTransfer() external;
    function cancelGovernanceTransfer() external;

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function subjectOf(bytes32 subjectId) external view returns (Subject memory);
    function statusOf(bytes32 subjectId) external view returns (SubjectStatus);

    /// @notice True if the subject can be the target of a NEW position right now.
    /// @dev    `status == ACTIVE && policyFlag == NONE`. Consumers should call
    ///         `requireTradeable` for the revert path (cheaper than checking + reverting twice).
    function isTradeable(bytes32 subjectId) external view returns (bool);
    function requireTradeable(bytes32 subjectId) external view;

    function kycTierOf(address trader) external view returns (uint8);
    function autoPauseExpiresAt(bytes32 subjectId) external view returns (uint64);

    function isAdmin(address account) external view returns (bool);
    function isPauseGuardian(address account) external view returns (bool);
    function isKycWriter(address account) external view returns (bool);

    function governance() external view returns (address);
    function timelockDelay() external view returns (uint32);
    function pendingGovernance() external view returns (address account, uint64 activatesAt);
    function pendingRoleOf(address account, Role role) external view returns (PendingRoleChange memory);

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event SubjectListed(bytes32 indexed subjectId, bytes32 indexed categoryId);
    event SubjectStatusChanged(bytes32 indexed subjectId, SubjectStatus oldStatus, SubjectStatus newStatus);
    event PolicyFlagSet(bytes32 indexed subjectId, PolicyFlag oldFlag, PolicyFlag newFlag);
    event DeathPendingFlagged(bytes32 indexed subjectId, uint64 expiresAt);
    event DelistingRequested(bytes32 indexed subjectId, uint64 forceSettleAt);
    event ForceSettled(bytes32 indexed subjectId);
    event PauseTriggered(bytes32 indexed subjectId, SubjectStatus newStatus, uint8 reasonCode);
    event KycTierSet(address indexed trader, uint8 oldTier, uint8 newTier);
    event RoleChangeProposed(address indexed account, Role indexed role, bool grant, uint64 activatesAt);
    event RoleChangeActivated(address indexed account, Role indexed role, bool grant);
    event RoleChangeCancelled(address indexed account, Role indexed role);
    event GovernanceTransferProposed(address indexed newGovernance, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceTransferCancelled(address indexed pendingGovernance);

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error Unauthorized(address caller);
    error InvalidConfig();
    error InvalidStatusTransition(SubjectStatus from, SubjectStatus to);
    error SubjectNotRegistered(bytes32 subjectId);
    error SubjectAlreadyRegistered(bytes32 subjectId);
    error PolicyFlagBlocksListing(PolicyFlag flag);
    error InvalidKycTier(uint8 tier);
    error InvalidRole();
    error PendingRoleChangeExists(address account, Role role);
    error NoPendingRoleChange(address account, Role role);
    error PendingGovernanceExists();
    error NoPendingGovernance();
    error TimelockNotElapsed(uint64 readyAt);
    error WindowNotElapsed(uint64 readyAt);
    error NotInDeathPending();
    error NotInDelisting();
    error RoleAlreadyHeld(address account, Role role);
    error RoleNotHeld(address account, Role role);
}
