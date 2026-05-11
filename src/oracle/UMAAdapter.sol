// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IOracleAdapter} from "./IOracleAdapter.sol";
import {IOracleRouter} from "./IOracleRouter.sol";

/// @notice Minimal subset of UMA's OptimisticOracleV3 we depend on.
/// @dev    UMA's full interface is broader; we only wrap the surface we actually use. The mock used
///         in tests implements exactly this interface and nothing else.
interface IOptimisticOracleV3 {
    /// @dev Submit a truth claim. The caller (this adapter) must have approved `bond` of `currency`
    ///      to the OO. Returns a unique `assertionId` that identifies the claim through its lifecycle.
    function assertTruth(
        bytes calldata claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        address currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 domainId
    )
        external
        returns (bytes32 assertionId);

    /// @dev Settle a previously-asserted claim after liveness has elapsed (or after the DVM has
    ///      resolved a dispute). Returns the final truth value.
    function settleAndGetAssertionResult(bytes32 assertionId) external returns (bool truthful);
}

/// @title UMAAdapter — wraps UMA OptimisticOracleV3 for per-metric numeric truth assertions.
/// @notice The third oracle source in the People Markets stack. Used for subjective, dispute-prone
///         resolutions where neither Chainlink (no public feed) nor the in-house signed feed (not
///         trustworthy enough on its own) is appropriate — event-contract resolutions, polling-basket
///         averages, narrative metrics, identity assertions.
///
/// @dev    Lifecycle (per assertion):
///         1. `proposeAssertion(metricId, claimedValue, claim)` — caller posts `bond` of `currency`,
///            adapter forwards it to OOv3 with `assertTruth`, OOv3 returns an `assertionId`.
///         2. Liveness window elapses. If nobody disputed via OOv3, the claim is automatically
///            considered truthful by UMA.
///         3. `settleAssertion(assertionId)` — anyone may call. Adapter asks OOv3 for the final
///            verdict (truthful or not) and, if truthful, records `(value, assertionTime)` against
///            the metric. If the claim is rejected, nothing is recorded; the metric retains its
///            previous value.
///
/// @dev    Per-metric configuration (`UMAMetric`) is governance-managed, timelocked. Bond and
///         liveness bounds are enforced on `proposeRegisterMetric` / `proposeUpdateMetric`.
///
/// @dev    UUPS upgradeable. State lives in a deterministic namespaced slot so the implementation
///         can be swapped without storage-layout drift. Slot:
///         `keccak256("people.markets.umaadapter.v1")`.
///
/// @dev    Trust model: governance can register / update / pause metrics. Anyone may propose an
///         assertion against a registered metric — they post the bond, they take the dispute risk.
///         Settlement is permissionless. The asserter does NOT get the bond refunded by this
///         adapter — UMA handles bond economics on its side (refund on truthful, slash on dispute
///         loss). This adapter only forwards bonds to OOv3 and records resolved values.
contract UMAAdapter is Initializable, UUPSUpgradeable, IOracleAdapter {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    /// @dev Minimum allowed bond. 1 USDC scaled at 6 decimals == 1e6. Below this, dispute griefing
    ///      is essentially free; above it, we need at least some bond to make assertion attacks
    ///      expensive. We do NOT enforce token-specific decimals here — the registering governance
    ///      must set bond in the currency's native units; the floor is the spec-defined minimum.
    uint256 public constant MIN_BOND = 1e6;

    /// @dev Maximum allowed bond. 1e30 == 1 trillion units of any token with up to 18 decimals.
    ///      Caps misconfiguration footguns ("type two extra zeros" => 1e32 bond locking up the
    ///      asserter's entire treasury).
    uint256 public constant MAX_BOND = 1e30;

    /// @dev Minimum dispute window in seconds. Below 60s the asserter could win a race with any
    ///      reasonably-funded watcher; the spec calls 60s the absolute floor and most metrics will
    ///      use hours-to-days.
    uint64 public constant MIN_LIVENESS = 60;

    /// @dev Maximum dispute window in seconds. 7 days matches the UMA reference design and is the
    ///      operational ceiling for any event resolution path we plan to run through OOv3.
    uint64 public constant MAX_LIVENESS = 7 days;

    /// @dev Governance timelock bounds. Matches SignedFeedAdapter and OracleRouter.
    uint32 public constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 public constant MAX_TIMELOCK_DELAY = 30 days;

    // ------------------------------------------------------------------------------------------
    // Storage (namespaced)
    // ------------------------------------------------------------------------------------------

    /// @dev Per-metric registration. `registered == false` is the canonical "not registered"
    ///      sentinel. Fields are documented inline below.
    struct UMAMetric {
        /// @dev Bond denominated in `currency`'s native units. Bounds: [MIN_BOND, MAX_BOND].
        uint256 bond;
        /// @dev Dispute window in seconds. Bounds: [MIN_LIVENESS, MAX_LIVENESS].
        uint64 livenessSeconds;
        /// @dev UMA price identifier (e.g. `ASSERT_TRUTH` / catalog-managed bytes32 tag). Passed
        ///      through to `assertTruth` so UMA's DVM can route disputes correctly.
        bytes32 identifier;
        /// @dev Bond currency. Adapter does NOT validate the address points to a real ERC20 — that
        ///      check is part of governance review. We DO require non-zero.
        address currency;
        /// @dev True once registered. Used as the "exists" sentinel.
        bool registered;
    }

    /// @dev Per-metric latest-settled state. Updated only on successful (truthful) settlements.
    struct UMAReading {
        uint256 value;
        uint64 valueTimestamp;
    }

    /// @dev Per-assertion state held inside this adapter. We need it to (a) re-validate during
    ///      settle that the assertion came from THIS adapter and (b) emit useful events.
    struct AssertionRecord {
        bytes32 metricId;
        uint256 claimedValue;
        address asserter;
        uint64 assertedAt;
        /// @dev Set to true once `settleAssertion` runs. Prevents double-settle bookkeeping.
        bool settled;
    }

    /// @dev A pending governance change. Either a new metric registration (`update == false`) or an
    ///      update to an existing one (`update == true`). At most one pending change per metricId.
    struct PendingMetric {
        UMAMetric config;
        uint64 activatesAt;
        bool isUpdate;
        bool exists;
    }

    /// @dev Namespaced layout for the adapter. Slot: keccak256("people.markets.umaadapter.v1").
    struct Layout {
        IOptimisticOracleV3 oo;
        address governance;
        uint32 timelockDelay;
        // pending governance transfer (timelocked, matches SignedFeedAdapter)
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        // metric registry
        mapping(bytes32 metricId => UMAMetric) metrics;
        mapping(bytes32 metricId => UMAReading) readings;
        mapping(bytes32 metricId => PendingMetric) pendingMetric;
        // assertion index
        mapping(bytes32 assertionId => AssertionRecord) assertions;
    }

    /// @dev keccak256("people.markets.umaadapter.v1"). Matches the StorageLib convention. Using
    ///      the string-via-keccak form keeps the slot deterministic without committing a wrong
    ///      precomputed literal to source.
    bytes32 private constant LAYOUT_SLOT = keccak256("people.markets.umaadapter.v1");

    function _layout() private pure returns (Layout storage l) {
        bytes32 slot = LAYOUT_SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event MetricRegisterProposed(bytes32 indexed metricId, UMAMetric config, uint64 activatesAt);
    event MetricRegisterActivated(bytes32 indexed metricId, UMAMetric config);
    event MetricRegisterCancelled(bytes32 indexed metricId);

    event MetricUpdateProposed(bytes32 indexed metricId, UMAMetric config, uint64 activatesAt);
    event MetricUpdateActivated(bytes32 indexed metricId, UMAMetric config);
    event MetricUpdateCancelled(bytes32 indexed metricId);

    event AssertionProposed(
        bytes32 indexed metricId,
        bytes32 indexed assertionId,
        address indexed asserter,
        uint256 claimedValue,
        uint256 bond,
        uint64 expiresAt
    );
    event AssertionSettled(bytes32 indexed metricId, bytes32 indexed assertionId, uint256 settledValue, bool disputed);

    event GovernanceTransferProposed(address indexed newGovernance, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceTransferCancelled(address indexed pendingGovernance);

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error Unauthorized(address caller);
    error InvalidConfig();
    error MetricNotRegistered(bytes32 metricId);
    error MetricAlreadyRegistered(bytes32 metricId);
    error AssertionNotFound(bytes32 assertionId);
    error AssertionNotSettled(bytes32 assertionId);
    error AssertionAlreadySettled(bytes32 assertionId);
    error BondTransferFailed();
    error BondOutOfRange(uint256 value);
    error LivenessOutOfRange(uint64 value);
    error NoPendingProposal(bytes32 metricId);
    error TimelockNotElapsed(uint64 readyAt);
    error PendingProposalExists(bytes32 metricId);
    error PendingGovernanceTransferExists();
    error NoPendingGovernanceTransfer();
    error WrongPendingKind();

    // ------------------------------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the adapter behind a UUPS proxy.
    /// @param  oo_            UMA OptimisticOracleV3 (or compatible mock).
    /// @param  governance_    Multi-sig that registers / updates metrics. Timelocked.
    /// @param  timelockDelay_ Seconds. Must be in [MIN_TIMELOCK_DELAY, MAX_TIMELOCK_DELAY].
    function initialize(IOptimisticOracleV3 oo_, address governance_, uint32 timelockDelay_) external initializer {
        if (address(oo_) == address(0)) revert InvalidConfig();
        if (governance_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) {
            revert InvalidConfig();
        }
        Layout storage l = _layout();
        l.oo = oo_;
        l.governance = governance_;
        l.timelockDelay = timelockDelay_;
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != _layout().governance) revert Unauthorized(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // Governance: register metric (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @notice Propose registration of a new metric. Times out into `activateRegisterMetric` after
    ///         the timelock elapses.
    /// @param  metricId   Canonical metric identifier (keccak hash convention; opaque to adapter).
    /// @param  bond       Bond in `currency` native units. Must be in [MIN_BOND, MAX_BOND].
    /// @param  liveness   Dispute window in seconds. Must be in [MIN_LIVENESS, MAX_LIVENESS].
    /// @param  identifier UMA price identifier passed to `assertTruth`.
    /// @param  currency   Bond currency. Must be non-zero.
    function proposeRegisterMetric(
        bytes32 metricId,
        uint256 bond,
        uint64 liveness,
        bytes32 identifier,
        address currency
    )
        external
        onlyGovernance
    {
        Layout storage l = _layout();
        if (l.metrics[metricId].registered) revert MetricAlreadyRegistered(metricId);
        if (l.pendingMetric[metricId].exists) revert PendingProposalExists(metricId);
        _validateBond(bond);
        _validateLiveness(liveness);
        if (currency == address(0)) revert InvalidConfig();

        UMAMetric memory cfg = UMAMetric({
            bond: bond,
            livenessSeconds: liveness,
            identifier: identifier,
            currency: currency,
            registered: true
        });
        uint64 activatesAt = uint64(block.timestamp) + uint64(l.timelockDelay);
        l.pendingMetric[metricId] =
            PendingMetric({config: cfg, activatesAt: activatesAt, isUpdate: false, exists: true});
        emit MetricRegisterProposed(metricId, cfg, activatesAt);
    }

    /// @notice Activate a previously-proposed registration. Reverts before the timelock elapses.
    function activateRegisterMetric(bytes32 metricId) external {
        Layout storage l = _layout();
        PendingMetric memory p = l.pendingMetric[metricId];
        if (!p.exists) revert NoPendingProposal(metricId);
        if (p.isUpdate) revert WrongPendingKind();
        if (block.timestamp < p.activatesAt) revert TimelockNotElapsed(p.activatesAt);

        l.metrics[metricId] = p.config;
        delete l.pendingMetric[metricId];
        emit MetricRegisterActivated(metricId, p.config);
    }

    /// @notice Cancel a pending registration proposal.
    function cancelRegisterMetric(bytes32 metricId) external onlyGovernance {
        Layout storage l = _layout();
        PendingMetric memory p = l.pendingMetric[metricId];
        if (!p.exists) revert NoPendingProposal(metricId);
        if (p.isUpdate) revert WrongPendingKind();
        delete l.pendingMetric[metricId];
        emit MetricRegisterCancelled(metricId);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: update metric (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @notice Propose an update to an existing metric's config. Times out into
    ///         `activateUpdateMetric` after the timelock elapses. Existing in-flight assertions are
    ///         unaffected (UMA still settles them with their original bond / liveness).
    function proposeUpdateMetric(
        bytes32 metricId,
        uint256 bond,
        uint64 liveness,
        bytes32 identifier,
        address currency
    )
        external
        onlyGovernance
    {
        Layout storage l = _layout();
        if (!l.metrics[metricId].registered) revert MetricNotRegistered(metricId);
        if (l.pendingMetric[metricId].exists) revert PendingProposalExists(metricId);
        _validateBond(bond);
        _validateLiveness(liveness);
        if (currency == address(0)) revert InvalidConfig();

        UMAMetric memory cfg = UMAMetric({
            bond: bond,
            livenessSeconds: liveness,
            identifier: identifier,
            currency: currency,
            registered: true
        });
        uint64 activatesAt = uint64(block.timestamp) + uint64(l.timelockDelay);
        l.pendingMetric[metricId] = PendingMetric({config: cfg, activatesAt: activatesAt, isUpdate: true, exists: true});
        emit MetricUpdateProposed(metricId, cfg, activatesAt);
    }

    /// @notice Activate a previously-proposed update. Reverts before the timelock elapses.
    function activateUpdateMetric(bytes32 metricId) external {
        Layout storage l = _layout();
        PendingMetric memory p = l.pendingMetric[metricId];
        if (!p.exists) revert NoPendingProposal(metricId);
        if (!p.isUpdate) revert WrongPendingKind();
        if (block.timestamp < p.activatesAt) revert TimelockNotElapsed(p.activatesAt);

        l.metrics[metricId] = p.config;
        delete l.pendingMetric[metricId];
        emit MetricUpdateActivated(metricId, p.config);
    }

    /// @notice Cancel a pending update proposal.
    function cancelUpdateMetric(bytes32 metricId) external onlyGovernance {
        Layout storage l = _layout();
        PendingMetric memory p = l.pendingMetric[metricId];
        if (!p.exists) revert NoPendingProposal(metricId);
        if (!p.isUpdate) revert WrongPendingKind();
        delete l.pendingMetric[metricId];
        emit MetricUpdateCancelled(metricId);
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer (timelocked, matches SignedFeedAdapter pattern)
    // ------------------------------------------------------------------------------------------

    /// @notice Propose a governance transfer. Activates after `timelockDelay` seconds.
    function proposeGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidConfig();
        Layout storage l = _layout();
        if (l.pendingGovernanceActivatesAt != 0) revert PendingGovernanceTransferExists();
        uint64 activatesAt = uint64(block.timestamp + l.timelockDelay);
        l.pendingGovernance = newGovernance;
        l.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGovernance, activatesAt);
    }

    /// @notice Activate a previously-proposed governance transfer. Permissionless.
    function activateGovernanceTransfer() external {
        Layout storage l = _layout();
        uint64 readyAt = l.pendingGovernanceActivatesAt;
        if (readyAt == 0) revert NoPendingGovernanceTransfer();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldGov = l.governance;
        address newGov = l.pendingGovernance;
        l.governance = newGov;
        delete l.pendingGovernance;
        delete l.pendingGovernanceActivatesAt;
        emit GovernanceTransferActivated(oldGov, newGov);
    }

    /// @notice Cancel a pending governance transfer.
    function cancelGovernanceTransfer() external onlyGovernance {
        Layout storage l = _layout();
        if (l.pendingGovernanceActivatesAt == 0) revert NoPendingGovernanceTransfer();
        address pending = l.pendingGovernance;
        delete l.pendingGovernance;
        delete l.pendingGovernanceActivatesAt;
        emit GovernanceTransferCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Assertion lifecycle
    // ------------------------------------------------------------------------------------------

    /// @notice Submit a truth claim for `metricId` with `claimedValue`. The caller posts `bond` of
    ///         the metric's bond currency; the adapter forwards it to OOv3.
    /// @dev    UMA's `assertTruth` takes a free-form `claim` payload — we let the caller provide it
    ///         so off-chain UIs can include catalog-specific context. The adapter still anchors the
    ///         claim to (metricId, claimedValue, asserter, timestamp) on-chain via storage and
    ///         events, so disputers do not have to trust the asserter's narrative.
    /// @param  metricId     Registered metric.
    /// @param  claimedValue The value the asserter claims is true. Recorded on truthful settlement.
    /// @param  claim        UMA claim payload. Convention: ASCII like
    ///                      `"metricId=0x...value=N at <timestamp>"`. Adapter does not parse.
    /// @return assertionId  UMA's identifier for the new assertion.
    function proposeAssertion(
        bytes32 metricId,
        uint256 claimedValue,
        bytes calldata claim
    )
        external
        returns (bytes32 assertionId)
    {
        Layout storage l = _layout();
        UMAMetric memory cfg = l.metrics[metricId];
        if (!cfg.registered) revert MetricNotRegistered(metricId);

        // Pull the bond from the caller and approve OOv3 to spend exactly that amount. We re-set
        // the approval each time to a known value to avoid stuck-approval footguns.
        IERC20 token = IERC20(cfg.currency);
        token.safeTransferFrom(msg.sender, address(this), cfg.bond);
        token.forceApprove(address(l.oo), cfg.bond);

        assertionId = l.oo.assertTruth(
            claim,
            msg.sender, // asserter
            address(0), // callbackRecipient — not used
            address(0), // escalationManager — not used
            cfg.livenessSeconds,
            cfg.currency,
            cfg.bond,
            cfg.identifier,
            bytes32(0) // domainId — default
        );

        // Defense-in-depth: OOv3 returning a zero assertionId would be a contract bug, but if it
        // ever happens (or a malicious mock does) we would silently overwrite a real record.
        if (assertionId == bytes32(0)) revert AssertionNotFound(assertionId);
        if (l.assertions[assertionId].asserter != address(0)) {
            // Two assertions cannot share an id — but if they did, refuse rather than overwrite.
            revert AssertionNotFound(assertionId);
        }

        l.assertions[assertionId] = AssertionRecord({
            metricId: metricId,
            claimedValue: claimedValue,
            asserter: msg.sender,
            assertedAt: uint64(block.timestamp),
            settled: false
        });

        uint64 expiresAt = uint64(block.timestamp) + cfg.livenessSeconds;
        emit AssertionProposed(metricId, assertionId, msg.sender, claimedValue, cfg.bond, expiresAt);
    }

    /// @notice Settle a previously-asserted claim. Calls into OOv3 to finalize and reads the
    ///         truth verdict; on truthful, records `(claimedValue, assertedAt)` against the metric.
    /// @dev    Permissionless. Idempotent: a second call reverts with `AssertionAlreadySettled`.
    /// @param  assertionId The UMA assertion id returned by `proposeAssertion`.
    function settleAssertion(bytes32 assertionId) external {
        Layout storage l = _layout();
        AssertionRecord storage rec = l.assertions[assertionId];
        if (rec.asserter == address(0)) revert AssertionNotFound(assertionId);
        if (rec.settled) revert AssertionAlreadySettled(assertionId);

        // Ask OOv3 for the verdict. If OOv3 has not yet reached a settled state (e.g. liveness has
        // not elapsed AND no dispute has been resolved), UMA itself reverts; we surface that as
        // AssertionNotSettled by translating the upstream revert via a try/catch so consumers get
        // a typed error.
        bool truthful;
        try l.oo.settleAndGetAssertionResult(assertionId) returns (bool t) {
            truthful = t;
        } catch {
            revert AssertionNotSettled(assertionId);
        }

        rec.settled = true;

        if (truthful) {
            // Update latest reading. Reject backdated overwrite: a slower-settled older assertion
            // must NOT clobber a newer already-settled value.
            UMAReading storage cur = l.readings[rec.metricId];
            if (rec.assertedAt >= cur.valueTimestamp) {
                cur.value = rec.claimedValue;
                cur.valueTimestamp = rec.assertedAt;
            }
            emit AssertionSettled(rec.metricId, assertionId, rec.claimedValue, false);
        } else {
            // Disputed-and-rejected: do not record. The metric retains its previous value.
            emit AssertionSettled(rec.metricId, assertionId, 0, true);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Reads
    // ------------------------------------------------------------------------------------------

    /// @notice Latest settled value and the timestamp of the assertion that produced it.
    /// @param  metricId Registered metric.
    /// @return value          Last truthfully-resolved claimed value, or 0 if never settled.
    /// @return valueTimestamp Timestamp of the assertion that produced `value`.
    function latestValue(bytes32 metricId) external view returns (uint256 value, uint64 valueTimestamp) {
        UMAReading memory r = _layout().readings[metricId];
        return (r.value, r.valueTimestamp);
    }

    /// @inheritdoc IOracleAdapter
    /// @dev    Returns the latest settled value. Reverts on unregistered metric. Staleness is the
    ///         OracleRouter's job — we return whatever we have, including (0, 0) before the first
    ///         settlement.
    function readMetric(bytes32 metricId) external view override returns (IOracleRouter.OracleReading memory) {
        Layout storage l = _layout();
        if (!l.metrics[metricId].registered) revert MetricNotRegistered(metricId);
        UMAReading memory r = l.readings[metricId];
        return IOracleRouter.OracleReading({value: r.value, updatedAt: r.valueTimestamp, degraded: false});
    }

    /// @inheritdoc IOracleAdapter
    /// @dev    Returns the timestamp of the last truthfully-settled assertion (0 before first
    ///         settlement). Reverts on unregistered metric — same gate as `readMetric` so the
    ///         OracleRouter's auto-degraded check fails closed on a misconfigured metric.
    function latestTimestamp(bytes32 metricId) external view override returns (uint64) {
        Layout storage l = _layout();
        if (!l.metrics[metricId].registered) revert MetricNotRegistered(metricId);
        return l.readings[metricId].valueTimestamp;
    }

    /// @notice Read the active UMA configuration for a metric.
    function metricOf(bytes32 metricId) external view returns (UMAMetric memory) {
        return _layout().metrics[metricId];
    }

    /// @notice Read a pending metric proposal.
    function pendingMetricOf(bytes32 metricId) external view returns (PendingMetric memory) {
        return _layout().pendingMetric[metricId];
    }

    /// @notice Read the in-flight assertion record for `assertionId`.
    function assertionOf(bytes32 assertionId) external view returns (AssertionRecord memory) {
        return _layout().assertions[assertionId];
    }

    /// @notice Configured UMA OptimisticOracleV3 address.
    function oracle() external view returns (address) {
        return address(_layout().oo);
    }

    /// @notice Current governance address.
    function governance() external view returns (address) {
        return _layout().governance;
    }

    /// @notice Current timelock delay in seconds.
    function timelockDelay() external view returns (uint32) {
        return _layout().timelockDelay;
    }

    /// @notice Pending governance address and activation time. Either pair is zero if no transfer
    ///         is pending.
    function pendingGovernanceTransfer() external view returns (address pending, uint64 activatesAt) {
        Layout storage l = _layout();
        return (l.pendingGovernance, l.pendingGovernanceActivatesAt);
    }

    // ------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------

    function _validateBond(uint256 bond) internal pure {
        if (bond < MIN_BOND || bond > MAX_BOND) revert BondOutOfRange(bond);
    }

    function _validateLiveness(uint64 liveness) internal pure {
        if (liveness < MIN_LIVENESS || liveness > MAX_LIVENESS) revert LivenessOutOfRange(liveness);
    }

    /// @dev UUPS authorization. Upgrades are governance-gated; the timelock is enforced by the
    ///      governance multi-sig executing through its own timelock contract.
    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
