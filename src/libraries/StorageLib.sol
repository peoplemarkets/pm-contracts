// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IPerpEngine} from "../core/IPerpEngine.sol";
import {IOracleRouter} from "../oracle/IOracleRouter.sol";
import {ISubjectRegistry} from "../registry/ISubjectRegistry.sol";

/// @title StorageLib — namespaced storage for People Markets core contracts.
/// @notice Each contract reads its mutable state from a deterministic, collision-free slot derived
///         from a versioned namespace string. This is the Synthetix v3 / Diamond storage pattern: it
///         lets us upgrade individual contracts behind UUPS proxies without auditors having to
///         reason about storage layout drift across versions.
///
/// @dev Slot derivation: `keccak256("people.markets.<contract>.v1")`. The namespace string is the
///      sole identifier — bumping the trailing `.vN` is how we declare a hard storage break (which
///      we should never do without a migration plan and a fresh audit).
///
/// @dev Each library exposes a `load()` that yields a storage pointer. Consumers read and mutate
///      fields directly; there is no per-field accessor wrapper.
///
/// @dev Structs are intentionally additive: new fields MUST be appended at the end, never inserted
///      or reordered. Removing a field is forbidden — replace with a `_deprecated_*` placeholder of
///      the same type to preserve layout. Each namespace lives in its own slot, so independent
///      structs do not collide; the "no insert / no reorder" rule is per-struct.
library PerpStorage {
    bytes32 internal constant SLOT = keccak256("people.markets.perp.v1");

    struct Layout {
        // mark price by subject (USDC-denominated, 1e18 decimals)
        mapping(bytes32 subjectId => uint256) markPrice;
        mapping(bytes32 subjectId => uint64) markUpdatedAt;
        // open interest at OPENING notional (long and short separately), USDC 1e18
        mapping(bytes32 subjectId => uint256) totalLongOI;
        mapping(bytes32 subjectId => uint256) totalShortOI;
        // positions keyed by deterministic id (keccak(trader, subject, nonce)). The position
        // struct itself is owned by `IPerpEngine` so the storage layout and external API stay
        // in sync (mirrors the OracleStorage / RegistryStorage convention).
        mapping(bytes32 positionId => IPerpEngine.Position) positions;
        // per-trader-per-subject open position id (one position per (trader, subject))
        mapping(address trader => mapping(bytes32 subjectId => bytes32)) openPositionId;
        // monotonic nonce for new positions; never reused
        uint256 nextPositionNonce;
        // off-chain mark writer (price keeper). Permissioned. Multiple writers allowed.
        mapping(address writer => bool) markWriters;
        // pending mark-writer adds (timelocked). Revokes are not timelocked — fast cut-off.
        mapping(address writer => uint64) pendingMarkWriterActivatesAt;
        // global trading halt (governance, no timelock — emergency lever)
        bool globalHalt;
        // mark-staleness window in seconds. Spec §1: 30s default.
        uint32 markStaleAfter;
        // dependencies — set in initialize, immutable after
        address subjectRegistry;
        address lpVault;
        // governance + timelock (matches OracleRouter / SubjectRegistry pattern)
        address governance;
        uint32 timelockDelay;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        // ---- APPENDED: Fix #11 LP rebate percent (governance-tunable, bounds [25, 50]) ----
        uint8 lpRebatePct;
        // ---- APPENDED: Fix #7 forced-settlement state per subject ----
        // settlementMark is in 1e18 fixed-point (same scale as markPrice).
        mapping(bytes32 subjectId => uint256) subjectSettlementMark;
        mapping(bytes32 subjectId => bool) subjectForceSettled;
        // ---- APPENDED: v2-audit Fix #5 per-update mark max-delta cap (bps of prior mark) ----
        // Bounds the blast radius of a single compromised mark-writer key. First-ever push for a
        // subject is uncapped (no prior reference); subsequent pushes must satisfy
        // |new - old| × 10_000 ≤ markMaxDeltaBps × old.
        uint16 markMaxDeltaBps;
        // ---- APPENDED: v2-audit Fix #3 slow-moving TVL signal for OI cap ----
        // Snapshot of LPVault.freeAssets(). Updated by a permissionless poker (with cooldown)
        // OR by an authoritative governance call. Used by `_enforceOpenCaps` instead of live
        // freeAssets() to defeat same-block flash-deposit OI cap inflation.
        uint256 cappedTvl;
        uint64 cappedTvlUpdatedAt;
        // ---- APPENDED: Tier-1 funding event stub — FundingEngine v1 wiring ----
        // Authorized writer for `pushFundingIndex`. Rotated through the standard timelocked
        // propose/activate/cancel flow (same shape as `pendingPerpEngine` on LPVault). The
        // funding-math contract has not shipped yet; this address is `0x0` at v0 launch and
        // populated when FundingEngine v1 deploys. Until then, `pushFundingIndex` reverts on
        // every call and traders open positions with `entryFundingIndex = 0`.
        address fundingEngine;
        address pendingFundingEngine;
        uint64 pendingFundingEngineActivatesAt;
    }

    function load() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}

library MarginStorage {
    bytes32 internal constant SLOT = keccak256("people.markets.margin.v1");

    /// @dev KYC tiers map to notional caps. Tier 0 is unconfigured/blocked.
    enum KycTier {
        NONE,
        T1,
        T2,
        T3
    }

    struct AccountExposure {
        // sum of |perp_notional| across all subjects, USDC 1e18
        uint256 totalPerpNotional;
        // sum of correlated event-position contributions × c_event_xm × correlation
        uint256 totalEventExposure;
        KycTier tier;
    }

    struct Layout {
        mapping(address trader => AccountExposure) exposure;
        // per-tier combined-exposure cap. Spec: T1 $200K, T2 $1M, T3 $4M (200K × tier multipliers).
        mapping(KycTier => uint256) tierCombinedCap;
        // per-tier per-subject notional cap. Spec: T1 $50K, T2 $250K, T3 $1M.
        mapping(KycTier => uint256) tierPerSubjectCap;
        // c_event_xm: cross-margin multiplier for event-position exposure. Starts at 0.25e18, range
        // 0.20e18-0.40e18. Governance-controlled, timelocked.
        uint256 crossMarginMultiplier;
        // initial margin / maintenance margin / liquidation buffer, in basis points of notional
        uint16 initialMarginBps; // 2000 (20%)
        uint16 maintenanceMarginBps; // 500 (5%)
        uint16 liquidationBufferBps; // 250 (2.5%)
        uint16 maxLeverageBps; // 50000 (5×)
        // per-subject side OI cap as basis points of vault.totalAssets(). Spec §3: 5% (500 bps).
        uint16 perSubjectSideOiCapBps;
        // ---- APPENDED: Tier-1 net-category OI cap (spec §3 line 123: 20% of vault TVL) ----
        // Signed accumulator per category: sum of (longOI − shortOI) at OPENING notional, across
        // every subject sharing the category. Incremented in `openPosition` and decremented in
        // `closePosition` / `closeAtForcedSettlement` by the position's signed contribution.
        // The cap is enforced on |netCategoryOi| post-open.
        mapping(bytes32 categoryId => int256) netCategoryOi;
        // Cap as basis points of `min(cappedTvl, liveTvl)` — same TVL denominator as the
        // per-subject side cap (v2-audit Fix #3). Default 2000 (20%), bounds [500, 5000].
        uint16 categoryNetOiCapBps;
    }

    function load() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}

library FundingStorage {
    bytes32 internal constant SLOT = keccak256("people.markets.funding.v1");

    struct Layout {
        // cumulative funding index per subject (signed, scaled by 1e18). Frozen during pauses.
        mapping(bytes32 subjectId => int256) cumulativeFundingIndex;
        // last accrual timestamp per subject
        mapping(bytes32 subjectId => uint64) lastFundingAt;
        // whether funding accrual is currently frozen for a subject (pause-aware)
        mapping(bytes32 subjectId => bool) frozen;
        // funding parameters (1e18 scale unless stated)
        uint256 kPremium; // 0.0125e18
        uint256 kSentiment; // 0.004e18
        uint256 kSkew; // 0.003e18
        uint256 fMaxPerHour; // 0.00075e18 (0.075%/h)
        uint32 fundingIntervalSeconds; // 3600 default, range 900-28800
        // hard floor for event OI to contribute to sentiment. USDC 1e18. Spec: $25_000.
        uint256 minEventOiForSentiment;
        // permissioned writer for funding-rate keeper pushes
        mapping(address => bool) fundingWriters;
    }

    function load() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}

library LiquidationStorage {
    bytes32 internal constant SLOT = keccak256("people.markets.liquidation.v1");

    /// @dev `inProgress` flag is set on entry to the liquidation flow so margin invariants
    ///      (I5) tolerate transient under-collateralization.
    struct LiquidationState {
        uint8 partialAttempts;
        uint64 lastPartialAt;
        bool inProgress;
    }

    struct Layout {
        mapping(bytes32 positionId => LiquidationState) state;
        // partial liquidation: 25% increments, minimum 4 attempts before full
        uint16 partialIncrementBps; // 2500
        uint8 minPartialsBeforeFull; // 4
        uint16 mmRestoreBufferBps; // 100 (restore to MM + 100bps buffer)
        // bounty paid to liquidator on full liquidation, basis points of notional
        uint16 fullLiquidationBountyBps; // 100 (1%)
        // LP socialization cap per single event, basis points of vault TVL
        uint16 lpSocializationCapBps; // 3000 (30%)
    }

    function load() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}

library VaultStorage {
    bytes32 internal constant SLOT = keccak256("people.markets.vault.v1");

    /// @dev Fix #5: governance-timelocked withdrawal of `accruedFees` (residual treasury bucket).
    ///      Single in-flight; matches the `pendingPerpEngine` pattern.
    struct PendingFeeWithdrawal {
        address recipient;
        uint256 amount;
        uint64 activatesAt;
        bool exists;
    }

    /// @dev `freeAssets` is computed (not stored): balance(USDC) − positionCollateral −
    ///      insuranceFundBalance − accruedFees. The four storage counters always sum to the
    ///      USDC balance owned by the vault contract (invariant I1). LP shares are priced off
    ///      `freeAssets` only — locked collateral, insurance fund, and treasury fees are not
    ///      redeemable.
    struct Layout {
        // bookkeeping buckets (sum = USDC.balanceOf(vault))
        uint256 positionCollateral;
        uint256 accruedFees;
        uint256 insuranceFundBalance;
        // collateral operator — the live PerpEngine address. Only this address may move locked
        // collateral, accrue fees, or settle position PnL.
        address perpEngine;
        // governance: timelocked admin (proposes operator + governance transfers)
        address governance;
        uint32 timelockDelay;
        address pendingPerpEngine;
        uint64 pendingPerpEngineActivatesAt;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        // operator: fast lever for deposit/withdrawal pause toggles. NO timelock.
        address operator;
        // pause flags
        bool depositsPaused;
        bool withdrawalsPaused;
        // ---- APPENDED: Fix #6 cumulative insurance-fund seed counter (USDC, 6-dec) ----
        uint256 insuranceSeedDeposited;
        // ---- APPENDED: Fix #5 pending fee withdrawal (single in-flight) ----
        PendingFeeWithdrawal pendingFeeWithdrawal;
        // ---- APPENDED: Tier-1 insurance cap + floor (spec §3 lines 157–163) ----
        // Cap: max insurance bookkeeper balance as basis points of `totalAssets()` (= freeAssets).
        // Default 1000 (10%), bounds [100, 5000]. Excess accrual is left in the share pool
        // (not booked into insuranceFundBalance), letting `freeAssets` absorb it as LP yield.
        uint16 insuranceCapBps;
        // Floor: informational lower-bound on the insurance bookkeeper as basis points of
        // `totalAssets()`. Default 500 (5%), bounds [0, 1000]; MUST be strictly below the cap.
        // Crossing emits `InsuranceFloorBreached` — no auto-debit; treasury responds off-chain.
        uint16 insuranceFloorBps;
    }

    function load() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}

library FeedbackStorage {
    bytes32 internal constant SLOT = keccak256("people.markets.feedback.v1");

    enum EventClass {
        UNSET,
        MAJOR,
        STANDARD,
        MINOR
    }

    /// @dev `cEventPositiveBps` and `cEventNegativeBps` are basis points of mark.
    ///      Per spec: negative = 1.5× positive, enforced at config time.
    struct CategoryCoefficients {
        uint16 cEventPositiveBps;
        uint16 cEventNegativeBps;
    }

    struct Layout {
        mapping(EventClass => CategoryCoefficients) coefficients;
        // per-resolution impulse cap, basis points of mark. Spec: 1500 (15%).
        uint16 impulseCapBps;
        // late-move discount params (1e18 scale)
        // late_move_factor = late_move / lateMoveDenominator
        // discount = min(maxDiscount, late_move_factor × discountSlope)
        uint256 lateMoveDenominator; // 0.5e18
        uint256 discountSlope; // 0.6e18
        uint256 maxDiscount; // 0.5e18
        // permissioned event-resolution caller (EventMarket / EventMarketFactory)
        mapping(address resolver => bool) authorizedResolvers;
    }

    function load() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}

library OracleStorage {
    bytes32 internal constant SLOT = keccak256("people.markets.oracle.v1");

    /// @dev Pending config changes are timelocked. `pendingConfig` is a full replacement on activate.
    struct PendingChange {
        IOracleRouter.MetricConfig config;
        uint64 activatesAt;
        bool exists;
    }

    struct Layout {
        // active configs
        mapping(bytes32 metricId => IOracleRouter.MetricConfig) configs;
        // pending registration / config-replacement proposals
        mapping(bytes32 metricId => PendingChange) pending;
        // pending fallback-adapter changes (separate from full config replacements)
        mapping(bytes32 metricId => address) pendingFallback;
        mapping(bytes32 metricId => uint64) pendingFallbackActivatesAt;
        // governance: rotates configs, timelocked
        address governance;
        // operator: fast lever for setDegraded only, NO timelock. Separate multi-sig from governance.
        address operator;
        // timelock delay for governance changes, in seconds (spec: 48h baseline)
        uint32 timelockDelay;
    }

    function load() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}

library RegistryStorage {
    bytes32 internal constant SLOT = keccak256("people.markets.registry.v1");

    struct Layout {
        // subjects
        mapping(bytes32 subjectId => ISubjectRegistry.Subject) subjects;
        // KYC tier per trader, mirrored from the off-chain KYC pipeline by an authorized writer
        mapping(address trader => uint8) kycTier;
        // governance: timelocked admin (role grants, contract upgrades)
        address governance;
        uint32 timelockDelay;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        // role sets
        mapping(address account => bool) subjectAdmins;
        mapping(address account => bool) pauseGuardians;
        mapping(address account => bool) kycWriters;
        // pending role changes, keyed by keccak(account, role)
        mapping(bytes32 changeKey => ISubjectRegistry.PendingRoleChange) pendingRoleChanges;
    }

    function load() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}

library PauseGuardianStorage {
    bytes32 internal constant SLOT = keccak256("people.markets.pauseguardian.v1");

    /// @dev Number of slots in the per-subject mark-observation ring buffer. Sized so that, in
    ///      normal operation (mark pushes every ~30s under the spec §1 default `markStaleAfter`),
    ///      the buffer spans roughly 60 minutes — the longest breaker window. With the 5-second
    ///      minimum-interval rate-limit, the worst-case buffer span is 128 × 5s = 10.6 minutes,
    ///      which still covers the 30-second and 30-minute windows. Operators who push marks at
    ///      a higher cadence may briefly under-cover the 1-hour window during ramp-up; this is an
    ///      explicit tradeoff against per-subject storage cost (a denser buffer costs more gas on
    ///      every `observe`).
    uint16 internal constant RING_SIZE = 128;

    /// @dev Single observation of a subject's mark. Packed so each entry occupies one storage slot
    ///      (uint192 mark + uint64 timestamp = 256 bits). MAX_MARK in PerpEngine is 1e36 which fits
    ///      comfortably in uint192 (~6.3e57).
    struct Observation {
        uint192 mark;
        uint64 timestamp;
    }

    /// @dev Per-subject ring buffer. `head` is the index of the next slot to write. `length` is the
    ///      number of valid entries (saturates at RING_SIZE). When `length == RING_SIZE`, oldest
    ///      entry is at `head` (the slot we are about to overwrite).
    struct Ring {
        uint16 head;
        uint16 length;
        Observation[RING_SIZE] entries;
    }

    /// @dev Pending threshold/window change (one in-flight). Single struct because all three tiers
    ///      change together — operators reason about the full breaker schedule at once, not slice
    ///      by slice.
    struct PendingThresholds {
        uint16 auto5MinBps;
        uint16 cooldown30MinBps;
        uint16 frozen60MinBps;
        uint32 auto5WindowSeconds;
        uint32 cooldown30WindowSeconds;
        uint32 frozen60WindowSeconds;
        uint64 activatesAt;
        bool exists;
    }

    struct Layout {
        // dependencies — set in initialize, immutable after
        address perpEngine;
        address subjectRegistry;
        // governance + timelock (matches the OracleRouter / PerpEngine pattern)
        address governance;
        uint32 timelockDelay;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        // breaker thresholds (basis points of the reference mark; defaults 500 / 1000 / 2000)
        uint16 auto5MinBps;
        uint16 cooldown30MinBps;
        uint16 frozen60MinBps;
        // breaker windows (seconds; defaults 30 / 1800 / 3600)
        uint32 auto5WindowSeconds;
        uint32 cooldown30WindowSeconds;
        uint32 frozen60WindowSeconds;
        // pending threshold / window change (single in-flight)
        PendingThresholds pendingThresholds;
        // per-subject mark observation history
        mapping(bytes32 subjectId => Ring) rings;
    }

    function load() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}
