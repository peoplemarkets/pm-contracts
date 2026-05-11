// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IOracleAdapter} from "./IOracleAdapter.sol";
import {IOracleRouter} from "./IOracleRouter.sol";

/// @notice Minimal Chainlink AggregatorV3 surface. Declared locally so the adapter does not
///         take a transitive dependency on the chainlink-contracts package.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkAdapter — wraps Chainlink price feeds for OracleRouter consumption.
/// @notice One adapter, many metrics. Each metric is bound to its own Chainlink aggregator via a
///         timelocked governance registration. Reads pass through `latestRoundData()`, validate
///         freshness + round completeness, and rescale from the feed's native decimals to the
///         1e18 fixed-point unit used by PerpEngine marks and index components (spec §4).
///
/// @dev    Trust model.
///         - The Chainlink network is trusted to publish honest answers. We do not (and cannot)
///           verify the answer in isolation; we only enforce structural validity (positive, fresh,
///           round-complete).
///         - The governance multi-sig is timelock-gated. It is the canonical attack surface for
///           swapping an aggregator. A typo or compromised key cannot instantly point a metric at
///           a malicious aggregator: every register/update flows through propose → activate with
///           a delay in [MIN_TIMELOCK_DELAY, MAX_TIMELOCK_DELAY]. Governance transfer is itself
///           timelocked for the same reason (matches SignedFeedAdapter Fix #7).
///
/// @dev    Round-completeness check. Chainlink deprecated the `answeredInRound >= roundId` invariant
///         in OCR2, but we keep it as defense-in-depth: on older aggregators it catches the "round
///         carried forward without a fresh answer" failure mode. On OCR2 feeds the check is a no-op
///         because answeredInRound equals roundId.
///
/// @dev    Staleness. We enforce a per-metric `maxStaleness` window here so a misconfigured router
///         staleAfter cannot accept arbitrarily old Chainlink data. The router still enforces its
///         own `staleAfter` on top — defense in depth, asymmetric trust between layers.
///
/// @dev    UUPS upgradeable. State lives in a namespaced slot so the implementation can be swapped
///         without storage layout collisions across versions.
contract ChainlinkAdapter is Initializable, UUPSUpgradeable, IOracleAdapter {
    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    /// @dev Target fixed-point scale for all values returned by the adapter. Matches the
    ///      PerpEngine mark/index unit. Feeds with different `decimals()` are rescaled.
    uint8 internal constant TARGET_DECIMALS = 18;

    /// @dev Bounds on the per-metric `maxStaleness` window, in seconds.
    ///      60s floor: anything tighter than one block on most chains and the feed will appear
    ///      stale even when healthy. 86400s (1 day) ceiling: matches the slowest Chainlink heart-
    ///      beat we expect to support; longer windows defeat the point of a freshness check.
    uint32 public constant MIN_MAX_STALENESS = 60;
    uint32 public constant MAX_MAX_STALENESS = 86_400;

    /// @dev Governance timelock bounds. Mirrors SignedFeedAdapter for operational consistency.
    uint32 public constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 public constant MAX_TIMELOCK_DELAY = 30 days;

    // ------------------------------------------------------------------------------------------
    // Storage (namespaced)
    // ------------------------------------------------------------------------------------------

    /// @dev Namespaced slot. Synthetix v3 / Diamond storage pattern — see StorageLib NatSpec.
    bytes32 internal constant SLOT = keccak256("people.markets.chainlinkadapter.v1");

    /// @dev Active per-metric feed config. `registered == false` is the canonical "not configured"
    ///      sentinel; we keep an explicit flag rather than relying on `aggregator != address(0)`
    ///      so we can tell "never registered" from "deliberately zeroed" in pending-update flows.
    struct ChainlinkFeed {
        address aggregator;
        uint8 decimals;
        uint32 maxStaleness;
        bool registered;
    }

    /// @dev Pending feed registration or update. `exists == false` means no in-flight change.
    struct PendingFeed {
        address aggregator;
        uint8 decimals;
        uint32 maxStaleness;
        uint64 activatesAt;
        bool exists;
    }

    struct Layout {
        IOracleRouter router;
        address governance;
        uint32 timelockDelay;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        mapping(bytes32 metricId => ChainlinkFeed) feeds;
        mapping(bytes32 metricId => PendingFeed) pendingRegister;
        mapping(bytes32 metricId => PendingFeed) pendingUpdate;
    }

    function _layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event FeedRegisterProposed(
        bytes32 indexed metricId, address aggregator, uint8 decimals, uint32 maxStaleness, uint64 activatesAt
    );
    event FeedRegisterActivated(bytes32 indexed metricId, address aggregator, uint8 decimals, uint32 maxStaleness);
    event FeedRegisterCancelled(bytes32 indexed metricId);

    event FeedUpdateProposed(
        bytes32 indexed metricId, address aggregator, uint8 decimals, uint32 maxStaleness, uint64 activatesAt
    );
    event FeedUpdateActivated(bytes32 indexed metricId, address aggregator, uint8 decimals, uint32 maxStaleness);
    event FeedUpdateCancelled(bytes32 indexed metricId);

    event GovernanceTransferProposed(address indexed newGovernance, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceTransferCancelled(address indexed pendingGovernance);

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error Unauthorized(address caller);
    error InvalidConfig();
    error InvalidAggregator();
    error FeedNotRegistered(bytes32 metricId);
    error FeedAlreadyRegistered(bytes32 metricId);
    error PendingProposalExists(bytes32 metricId);
    error NoPendingProposal(bytes32 metricId);
    error TimelockNotElapsed(uint64 readyAt);
    error MaxStalenessOutOfRange(uint32 value);
    error StaleData(bytes32 metricId, uint64 updatedAt, uint64 cutoff);
    error InvalidAnswer(int256 answer);
    error IncompleteRound(uint80 roundId, uint80 answeredInRound);
    error UnsupportedDecimals(uint8 decimals);
    error PendingGovernanceTransferExists();
    error NoPendingGovernanceTransfer();

    // ------------------------------------------------------------------------------------------
    // Init / upgrade authorization
    // ------------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the adapter once via the proxy.
    /// @param router_         OracleRouter — used only as a reference today, kept for symmetry with
    ///                        SignedFeedAdapter and to leave room for future "is-active-source"
    ///                        checks if/when Chainlink-sourced metrics gain a write side.
    /// @param governance_     Multi-sig that proposes/activates/cancels feed and governance changes.
    /// @param timelockDelay_  Seconds. Must lie in [MIN_TIMELOCK_DELAY, MAX_TIMELOCK_DELAY].
    function initialize(IOracleRouter router_, address governance_, uint32 timelockDelay_) external initializer {
        if (address(router_) == address(0)) revert InvalidConfig();
        if (governance_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();
        Layout storage l = _layout();
        l.router = router_;
        l.governance = governance_;
        l.timelockDelay = timelockDelay_;
    }

    /// @dev UUPS authorization. Governance executes upgrades through its own timelock.
    function _authorizeUpgrade(address) internal override onlyGovernance {}

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != _layout().governance) revert Unauthorized(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // Governance: register a feed for a metric (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @notice Propose binding `metricId` to `aggregator`. Activatable after the timelock elapses.
    /// @dev    Decimals are read once at propose time from the aggregator and frozen into the
    ///         pending struct. Activating later does NOT re-query — if Chainlink changes the
    ///         aggregator's decimals between propose and activate (rare; would also invalidate
    ///         every downstream consumer), governance must cancel and re-propose. This is a
    ///         deliberate trade-off: it makes the activation step deterministic and removes a
    ///         class of front-run-the-decimals attack on the activate step.
    /// @param metricId      The composite metric identifier (e.g. keccak(subjectId, metricKindId)).
    /// @param aggregator    Chainlink AggregatorV3 address.
    /// @param maxStaleness  Per-metric staleness ceiling in seconds (bounds enforced).
    function proposeRegisterFeed(
        bytes32 metricId,
        address aggregator,
        uint32 maxStaleness
    )
        external
        onlyGovernance
    {
        if (aggregator == address(0)) revert InvalidAggregator();
        if (maxStaleness < MIN_MAX_STALENESS || maxStaleness > MAX_MAX_STALENESS) {
            revert MaxStalenessOutOfRange(maxStaleness);
        }
        Layout storage l = _layout();
        if (l.feeds[metricId].registered) revert FeedAlreadyRegistered(metricId);
        if (l.pendingRegister[metricId].exists) revert PendingProposalExists(metricId);

        uint8 dec = IAggregatorV3(aggregator).decimals();
        if (dec > TARGET_DECIMALS) revert UnsupportedDecimals(dec);

        uint64 activatesAt = uint64(block.timestamp) + uint64(l.timelockDelay);
        l.pendingRegister[metricId] = PendingFeed({
            aggregator: aggregator,
            decimals: dec,
            maxStaleness: maxStaleness,
            activatesAt: activatesAt,
            exists: true
        });
        emit FeedRegisterProposed(metricId, aggregator, dec, maxStaleness, activatesAt);
    }

    /// @notice Activate a pending registration. Permissionless after timelock — the security gate
    ///         is the propose step.
    /// @param metricId  Metric to activate.
    function activateRegisterFeed(bytes32 metricId) external {
        Layout storage l = _layout();
        PendingFeed memory p = l.pendingRegister[metricId];
        if (!p.exists) revert NoPendingProposal(metricId);
        if (block.timestamp < p.activatesAt) revert TimelockNotElapsed(p.activatesAt);
        if (l.feeds[metricId].registered) revert FeedAlreadyRegistered(metricId);

        l.feeds[metricId] = ChainlinkFeed({
            aggregator: p.aggregator,
            decimals: p.decimals,
            maxStaleness: p.maxStaleness,
            registered: true
        });
        delete l.pendingRegister[metricId];
        emit FeedRegisterActivated(metricId, p.aggregator, p.decimals, p.maxStaleness);
    }

    /// @notice Cancel a pending registration.
    /// @param metricId  Metric whose pending register proposal to cancel.
    function cancelRegisterFeed(bytes32 metricId) external onlyGovernance {
        Layout storage l = _layout();
        if (!l.pendingRegister[metricId].exists) revert NoPendingProposal(metricId);
        delete l.pendingRegister[metricId];
        emit FeedRegisterCancelled(metricId);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: update an already-registered feed (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @notice Propose swapping the aggregator or maxStaleness for an already-registered metric.
    ///         Activatable after the timelock elapses.
    /// @dev    A separate proposal lane from register so an in-flight register cannot be hijacked
    ///         into an update path (or vice versa). Pending register and pending update for the
    ///         same metric are independent slots; the activate paths enforce the matching state
    ///         transition.
    /// @param metricId      Metric whose feed is being updated.
    /// @param aggregator    New Chainlink AggregatorV3 address.
    /// @param maxStaleness  New per-metric staleness window in seconds.
    function proposeUpdateFeed(
        bytes32 metricId,
        address aggregator,
        uint32 maxStaleness
    )
        external
        onlyGovernance
    {
        if (aggregator == address(0)) revert InvalidAggregator();
        if (maxStaleness < MIN_MAX_STALENESS || maxStaleness > MAX_MAX_STALENESS) {
            revert MaxStalenessOutOfRange(maxStaleness);
        }
        Layout storage l = _layout();
        if (!l.feeds[metricId].registered) revert FeedNotRegistered(metricId);
        if (l.pendingUpdate[metricId].exists) revert PendingProposalExists(metricId);

        uint8 dec = IAggregatorV3(aggregator).decimals();
        if (dec > TARGET_DECIMALS) revert UnsupportedDecimals(dec);

        uint64 activatesAt = uint64(block.timestamp) + uint64(l.timelockDelay);
        l.pendingUpdate[metricId] = PendingFeed({
            aggregator: aggregator,
            decimals: dec,
            maxStaleness: maxStaleness,
            activatesAt: activatesAt,
            exists: true
        });
        emit FeedUpdateProposed(metricId, aggregator, dec, maxStaleness, activatesAt);
    }

    /// @notice Activate a pending update. Permissionless after timelock.
    /// @param metricId  Metric whose update proposal to activate.
    function activateUpdateFeed(bytes32 metricId) external {
        Layout storage l = _layout();
        PendingFeed memory p = l.pendingUpdate[metricId];
        if (!p.exists) revert NoPendingProposal(metricId);
        if (block.timestamp < p.activatesAt) revert TimelockNotElapsed(p.activatesAt);
        if (!l.feeds[metricId].registered) revert FeedNotRegistered(metricId);

        l.feeds[metricId] = ChainlinkFeed({
            aggregator: p.aggregator,
            decimals: p.decimals,
            maxStaleness: p.maxStaleness,
            registered: true
        });
        delete l.pendingUpdate[metricId];
        emit FeedUpdateActivated(metricId, p.aggregator, p.decimals, p.maxStaleness);
    }

    /// @notice Cancel a pending feed update.
    /// @param metricId  Metric whose pending update to cancel.
    function cancelUpdateFeed(bytes32 metricId) external onlyGovernance {
        Layout storage l = _layout();
        if (!l.pendingUpdate[metricId].exists) revert NoPendingProposal(metricId);
        delete l.pendingUpdate[metricId];
        emit FeedUpdateCancelled(metricId);
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer (timelocked)
    // ------------------------------------------------------------------------------------------
    // Matches SignedFeedAdapter Fix #7. Single-step transfer is unacceptable here: a typo or
    // compromised key could instantly seize the adapter and from there register a malicious
    // aggregator (subject only to its OWN propose/activate gates, which the new governance also
    // controls). Two timelocks therefore stand between a key compromise and a malicious value.

    /// @notice Propose transferring governance to `newGovernance`. Activatable after timelock.
    /// @param newGovernance  Successor governance address; non-zero.
    function proposeGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidConfig();
        Layout storage l = _layout();
        if (l.pendingGovernanceActivatesAt != 0) revert PendingGovernanceTransferExists();
        uint64 activatesAt = uint64(block.timestamp) + uint64(l.timelockDelay);
        l.pendingGovernance = newGovernance;
        l.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGovernance, activatesAt);
    }

    /// @notice Activate a pending governance transfer. Permissionless after timelock.
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
    // Reads (IOracleAdapter)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleAdapter
    /// @dev Returns the latest reading rescaled to 1e18. Reverts on stale, negative, or incomplete
    ///      rounds. The router applies its own `staleAfter` on top.
    function readMetric(bytes32 metricId) external view override returns (IOracleRouter.OracleReading memory) {
        (uint256 value, uint64 valueTimestamp) = _readAndValidate(metricId);
        return IOracleRouter.OracleReading({value: value, updatedAt: valueTimestamp, degraded: false});
    }

    /// @notice Read the rescaled latest value and its upstream timestamp.
    /// @dev Convenience accessor; identical validation to `readMetric` but a plainer return shape
    ///      for off-chain readers and other on-chain consumers that don't want the OracleReading
    ///      envelope. The router does NOT call this — it calls `readMetric`.
    /// @param metricId        Metric to read.
    /// @return value          Latest answer rescaled to 1e18.
    /// @return valueTimestamp Upstream `updatedAt` from the aggregator round.
    function latestValue(bytes32 metricId) external view returns (uint256 value, uint64 valueTimestamp) {
        return _readAndValidate(metricId);
    }

    /// @inheritdoc IOracleAdapter
    /// @dev Same validation as `latestValue` but returns only the upstream `updatedAt` for `metricId`.
    function latestTimestamp(bytes32 metricId) external view override returns (uint64) {
        (, uint64 ts) = _readAndValidate(metricId);
        return ts;
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    /// @notice Active feed config for `metricId`. Returns the zero struct if not registered.
    function feedOf(bytes32 metricId) external view returns (ChainlinkFeed memory) {
        return _layout().feeds[metricId];
    }

    /// @notice Pending registration for `metricId`. `exists == false` if none.
    function pendingRegisterOf(bytes32 metricId) external view returns (PendingFeed memory) {
        return _layout().pendingRegister[metricId];
    }

    /// @notice Pending update for `metricId`. `exists == false` if none.
    function pendingUpdateOf(bytes32 metricId) external view returns (PendingFeed memory) {
        return _layout().pendingUpdate[metricId];
    }

    /// @notice OracleRouter reference set at initialize.
    function router() external view returns (IOracleRouter) {
        return _layout().router;
    }

    /// @notice Current governance address.
    function governance() external view returns (address) {
        return _layout().governance;
    }

    /// @notice Current timelock delay (seconds).
    function timelockDelay() external view returns (uint32) {
        return _layout().timelockDelay;
    }

    /// @notice Pending governance address (zero if none).
    function pendingGovernance() external view returns (address) {
        return _layout().pendingGovernance;
    }

    /// @notice Activation time for the pending governance transfer (zero if none).
    function pendingGovernanceActivatesAt() external view returns (uint64) {
        return _layout().pendingGovernanceActivatesAt;
    }

    // ------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------

    function _readAndValidate(bytes32 metricId) internal view returns (uint256 value, uint64 valueTimestamp) {
        Layout storage l = _layout();
        ChainlinkFeed memory f = l.feeds[metricId];
        if (!f.registered) revert FeedNotRegistered(metricId);

        (uint80 roundId, int256 answer, /*startedAt*/, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(f.aggregator).latestRoundData();

        // Round completeness: `updatedAt == 0` is the canonical "round not yet answered" sentinel.
        // `answeredInRound < roundId` is the deprecated-but-still-useful "stale carry-forward"
        // detector. Keeping both is cheap and defensive.
        if (updatedAt == 0) revert IncompleteRound(roundId, answeredInRound);
        if (answeredInRound < roundId) revert IncompleteRound(roundId, answeredInRound);

        // Reject non-positive answers. Chainlink uses int256 so a malicious or buggy aggregator
        // could in principle return ≤ 0. We treat that as unconditionally invalid for the metrics
        // we track (mark / index components are always strictly positive).
        if (answer <= 0) revert InvalidAnswer(answer);

        // Staleness: enforce the adapter-level window. Router applies its own staleAfter on top.
        uint64 cutoff = uint64(updatedAt) + uint64(f.maxStaleness);
        if (uint64(block.timestamp) > cutoff) {
            revert StaleData(metricId, uint64(updatedAt), cutoff);
        }

        // Rescale to TARGET_DECIMALS. Feeds with decimals > TARGET_DECIMALS are rejected at
        // registration so the scaling here can never lose precision: we always multiply.
        uint256 scaled;
        if (f.decimals == TARGET_DECIMALS) {
            scaled = uint256(answer);
        } else {
            // factor = 10 ** (TARGET_DECIMALS - decimals). Bounded because TARGET_DECIMALS == 18
            // and decimals ≤ TARGET_DECIMALS — i.e. factor ≤ 1e18. Use mulDiv for overflow safety
            // on the multiplication: practical Chainlink answers comfortably fit, but we are not
            // willing to assume a misconfigured/exotic aggregator does.
            uint256 factor = 10 ** uint256(TARGET_DECIMALS - f.decimals);
            scaled = Math.mulDiv(uint256(answer), factor, 1);
        }

        return (scaled, uint64(updatedAt));
    }
}
