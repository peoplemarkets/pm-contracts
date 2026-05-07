// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ECDSA} from "solady/utils/ECDSA.sol";
import {EIP712} from "solady/utils/EIP712.sol";

import {IOracleAdapter} from "./IOracleAdapter.sol";
import {IOracleRouter} from "./IOracleRouter.sol";

/// @title SignedFeedAdapter — 3-of-5 EIP-712 signed in-house data feed.
/// @notice Adapter for licensed APIs (Spotify, YouTube, X, Google Trends, Wikipedia, Billboard).
///         The relayer pulls data on a per-metric cadence, packages it as an EIP-712 typed message,
///         collects 3-of-5 signatures from independently operated signers, and pushes the payload
///         on-chain. Anyone may submit a payload — the signature gate is the security boundary.
///
/// @dev    v1 trust model. The TEE migration target is documented in spec §4. Until then, the
///         multi-sig is the canonical attack surface. Mitigations:
///         - Distinct signers across cloud KMS, bare-metal HSM, and an independent custodian.
///         - Each signer re-fetches the data before signing.
///         - Signer rotation is timelocked (governance) so a single key compromise cannot cascade.
///         - Per-refresh max-delta cap (sourced from OracleRouter config) caps single-update damage.
///         - Operator (separate multi-sig) may pause pushes immediately, no timelock.
///
/// @dev    Replay defense: per-metric monotonic nonce + strictly-increasing `valueTimestamp`.
///         Both are required: nonce prevents same-payload replay; timestamp prevents a stale-but-
///         differently-nonced message from being accepted out of order.
contract SignedFeedAdapter is EIP712, IOracleAdapter {
    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    uint256 public constant SIGNER_COUNT = 5;
    uint256 public constant THRESHOLD = 3;

    /// @dev EIP-712 type hash for the signed payload.
    ///      Signers sign over (metricId, value, valueTimestamp, nonce) inside the standard EIP-712
    ///      domain (name, version, chainId, verifyingContract).
    bytes32 public constant SIGNED_UPDATE_TYPEHASH =
        keccak256("SignedUpdate(bytes32 metricId,uint256 value,uint64 valueTimestamp,uint64 nonce)");

    uint32 public constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 public constant MAX_TIMELOCK_DELAY = 30 days;

    // ------------------------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------------------------

    /// @dev Active signer set. Indexed by uint8 in submitted SignerSig.signerIndex. Order matters
    ///      for the ascending-index-no-duplicates check on push.
    address[SIGNER_COUNT] public signers;

    address public governance;
    address public operator;
    uint32 public timelockDelay;

    address[SIGNER_COUNT] public pendingSigners;
    uint64 public pendingActivatesAt;
    bool public pendingExists;

    /// @dev OracleRouter — used to look up per-metric maxDeltaBps caps. Set once at deploy.
    IOracleRouter public immutable router;

    /// @dev Latest signed reading per metric. Pushes overwrite. Reads from `router.read()` flow
    ///      through `readMetric()` below.
    struct SignedReading {
        uint256 value;
        uint64 valueTimestamp;
        uint64 nonce;
    }

    mapping(bytes32 metricId => SignedReading) public latest;

    /// @dev When true, `pushUpdate` reverts. The router can still read the last good value (this is
    ///      the desired behavior — pausing pushes is a "freeze the feed" action, not a "halt
    ///      reads" action; routing changes are made via OracleRouter.setDegraded).
    bool public paused;

    /// @dev Submission shape. `signerIndex` selects which slot in `signers` produced the sig.
    struct SignerSig {
        uint8 signerIndex;
        bytes signature;
    }

    // ------------------------------------------------------------------------------------------
    // Events / Errors
    // ------------------------------------------------------------------------------------------

    event Pushed(bytes32 indexed metricId, uint256 value, uint64 valueTimestamp, uint64 nonce);
    event SignerRotationProposed(address[SIGNER_COUNT] newSigners, uint64 activatesAt);
    event SignerRotationActivated(address[SIGNER_COUNT] newSigners);
    event SignerRotationCancelled();
    event PausedSet(bool paused);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);
    event OperatorTransferred(address indexed oldOperator, address indexed newOperator);

    error Unauthorized(address caller);
    error AdapterPaused();
    error MetricNotConfiguredHere(bytes32 metricId);
    error BadNonce(uint64 expected, uint64 got);
    error NonMonotonicTimestamp(uint64 stored, uint64 incoming);
    error TimestampInFuture(uint64 incoming, uint64 nowTs);
    error DeltaCapExceeded(uint256 oldValue, uint256 newValue, uint32 maxDeltaBps);
    error WrongSignatureCount(uint256 expected, uint256 got);
    error SignerIndexOutOfRange(uint8 index);
    error SignerIndicesNotAscending();
    error InvalidSignature(uint8 signerIndex);
    error NoPendingRotation();
    error TimelockNotElapsed(uint64 readyAt);
    error PendingRotationExists();
    error InvalidSigners();
    error InvalidConfig();

    // ------------------------------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------------------------------

    /// @param router_ OracleRouter — used to look up per-metric maxDeltaBps and to confirm this
    ///                adapter is the active source for any given metric on push.
    /// @param governance_ Multi-sig that proposes signer rotations. Timelocked.
    /// @param operator_ Multi-sig that can flip `paused`. NO timelock.
    /// @param timelockDelay_ Seconds. Must lie in [MIN_TIMELOCK_DELAY, MAX_TIMELOCK_DELAY].
    /// @param initialSigners Five distinct, non-zero signer addresses.
    constructor(
        IOracleRouter router_,
        address governance_,
        address operator_,
        uint32 timelockDelay_,
        address[SIGNER_COUNT] memory initialSigners
    ) {
        if (address(router_) == address(0)) revert InvalidConfig();
        if (governance_ == address(0) || operator_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();
        _validateSignerSet(initialSigners);

        router = router_;
        governance = governance_;
        operator = operator_;
        timelockDelay = timelockDelay_;
        signers = initialSigners;
    }

    // ------------------------------------------------------------------------------------------
    // EIP-712 domain
    // ------------------------------------------------------------------------------------------

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        return ("PeopleMarketsSignedFeed", "1");
    }

    /// @notice Expose the typed-data hash externally so off-chain signing tools can compute and
    ///         verify the digest without having to re-derive the domain separator.
    function hashTypedData(
        bytes32 metricId,
        uint256 value,
        uint64 valueTimestamp,
        uint64 nonce
    )
        external
        view
        returns (bytes32)
    {
        return _hashTypedData(_structHash(metricId, value, valueTimestamp, nonce));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    function _structHash(
        bytes32 metricId,
        uint256 value,
        uint64 valueTimestamp,
        uint64 nonce
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(SIGNED_UPDATE_TYPEHASH, metricId, value, valueTimestamp, nonce));
    }

    // ------------------------------------------------------------------------------------------
    // Push
    // ------------------------------------------------------------------------------------------

    /// @notice Submit a 3-of-5 signed update for a metric.
    /// @dev    Anyone may call. The signature set is the gate.
    /// @param  metricId        Composite metric identifier (e.g. keccak(subjectId, metricKindId)).
    /// @param  value           New value, scale defined by the metric.
    /// @param  valueTimestamp  Wall-clock time at which the upstream source produced the value.
    /// @param  nonce           Per-metric monotonic counter; must equal `latest.nonce + 1`.
    /// @param  sigs            Exactly THRESHOLD signatures, indices ascending, no duplicates.
    function pushUpdate(
        bytes32 metricId,
        uint256 value,
        uint64 valueTimestamp,
        uint64 nonce,
        SignerSig[] calldata sigs
    )
        external
    {
        if (paused) revert AdapterPaused();

        // Confirm this adapter is the active source for the metric in the router. This stops
        // signers from being able to push values for metrics this adapter is not authorized for —
        // useful when a metric has been migrated to a fallback or a different adapter type.
        IOracleRouter.MetricConfig memory cfg = router.configOf(metricId);
        if (cfg.sourceType != IOracleRouter.SourceType.SIGNED || cfg.adapter != address(this)) {
            revert MetricNotConfiguredHere(metricId);
        }

        SignedReading memory stored = latest[metricId];

        // Replay defense pt. 1: per-metric monotonic nonce. First push is nonce == 1.
        uint64 expectedNonce = stored.nonce + 1;
        if (nonce != expectedNonce) revert BadNonce(expectedNonce, nonce);

        // Replay defense pt. 2: monotonic value timestamp. Defends against an out-of-order signed
        // payload that happens to match the next nonce (only theoretical given nonce defense, but
        // cheap insurance and required by spec §4 "TWAP on all index-component metrics").
        if (valueTimestamp <= stored.valueTimestamp) {
            revert NonMonotonicTimestamp(stored.valueTimestamp, valueTimestamp);
        }
        if (valueTimestamp > block.timestamp) revert TimestampInFuture(valueTimestamp, uint64(block.timestamp));

        // Max-delta cap: skip on first-ever push (stored.value == 0). After that, |Δ| / oldValue
        // (in bps) must be ≤ cfg.maxDeltaBps.
        if (stored.value != 0) {
            uint256 oldValue = stored.value;
            uint256 diff = value > oldValue ? value - oldValue : oldValue - value;
            // Multiplication-first form avoids precision loss on small diffs.
            if (diff * 10_000 > uint256(cfg.maxDeltaBps) * oldValue) {
                revert DeltaCapExceeded(oldValue, value, cfg.maxDeltaBps);
            }
        }

        // 3-of-5 signature verification.
        bytes32 digest = _hashTypedData(_structHash(metricId, value, valueTimestamp, nonce));
        _verifySignatures(digest, sigs);

        latest[metricId] = SignedReading({value: value, valueTimestamp: valueTimestamp, nonce: nonce});
        emit Pushed(metricId, value, valueTimestamp, nonce);
    }

    function _verifySignatures(bytes32 digest, SignerSig[] calldata sigs) internal view {
        if (sigs.length != THRESHOLD) revert WrongSignatureCount(THRESHOLD, sigs.length);

        int256 lastIndex = -1;
        // Resolve into memory once to avoid repeated SLOAD on the signers array.
        address[SIGNER_COUNT] memory s = signers;

        for (uint256 i = 0; i < THRESHOLD;) {
            uint8 idx = sigs[i].signerIndex;
            if (uint256(idx) >= SIGNER_COUNT) revert SignerIndexOutOfRange(idx);
            if (int256(uint256(idx)) <= lastIndex) revert SignerIndicesNotAscending();
            address recovered = ECDSA.recoverCalldata(digest, sigs[i].signature);
            if (recovered != s[idx]) revert InvalidSignature(idx);
            lastIndex = int256(uint256(idx));
            unchecked {
                ++i;
            }
        }
    }

    // ------------------------------------------------------------------------------------------
    // Read (IOracleAdapter)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleAdapter
    /// @dev OracleRouter is the staleness gate. We return the raw stored reading; the router checks
    ///      `updatedAt` against the configured `staleAfter` and reverts if too old.
    function readMetric(bytes32 metricId) external view override returns (IOracleRouter.OracleReading memory) {
        SignedReading memory r = latest[metricId];
        return IOracleRouter.OracleReading({value: r.value, updatedAt: r.valueTimestamp, degraded: false});
    }

    // ------------------------------------------------------------------------------------------
    // Governance: signer rotation (timelocked)
    // ------------------------------------------------------------------------------------------

    function proposeSignerRotation(address[SIGNER_COUNT] calldata newSigners) external {
        if (msg.sender != governance) revert Unauthorized(msg.sender);
        if (pendingExists) revert PendingRotationExists();
        _validateSignerSet(newSigners);
        pendingSigners = newSigners;
        uint64 activatesAt = uint64(block.timestamp) + uint64(timelockDelay);
        pendingActivatesAt = activatesAt;
        pendingExists = true;
        emit SignerRotationProposed(newSigners, activatesAt);
    }

    function activateSignerRotation() external {
        if (!pendingExists) revert NoPendingRotation();
        if (block.timestamp < pendingActivatesAt) revert TimelockNotElapsed(pendingActivatesAt);
        address[SIGNER_COUNT] memory ns = pendingSigners;
        signers = ns;
        delete pendingSigners;
        delete pendingActivatesAt;
        delete pendingExists;
        emit SignerRotationActivated(ns);
    }

    function cancelSignerRotation() external {
        if (msg.sender != governance) revert Unauthorized(msg.sender);
        if (!pendingExists) revert NoPendingRotation();
        delete pendingSigners;
        delete pendingActivatesAt;
        delete pendingExists;
        emit SignerRotationCancelled();
    }

    // ------------------------------------------------------------------------------------------
    // Operator: pause / unpause
    // ------------------------------------------------------------------------------------------

    function setPaused(bool p) external {
        if (msg.sender != operator) revert Unauthorized(msg.sender);
        paused = p;
        emit PausedSet(p);
    }

    // ------------------------------------------------------------------------------------------
    // Role transfers (kept simple — caller transfers to a new address; receiver claim could be
    // added later if needed)
    // ------------------------------------------------------------------------------------------

    function transferGovernance(address newGovernance) external {
        if (msg.sender != governance) revert Unauthorized(msg.sender);
        if (newGovernance == address(0)) revert InvalidConfig();
        emit GovernanceTransferred(governance, newGovernance);
        governance = newGovernance;
    }

    function transferOperator(address newOperator) external {
        if (msg.sender != governance) revert Unauthorized(msg.sender);
        if (newOperator == address(0)) revert InvalidConfig();
        emit OperatorTransferred(operator, newOperator);
        operator = newOperator;
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function getSigners() external view returns (address[SIGNER_COUNT] memory) {
        return signers;
    }

    function getPendingSigners() external view returns (address[SIGNER_COUNT] memory) {
        return pendingSigners;
    }

    function readingOf(bytes32 metricId) external view returns (SignedReading memory) {
        return latest[metricId];
    }

    // ------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------

    function _validateSignerSet(address[SIGNER_COUNT] memory candidate) internal pure {
        for (uint256 i = 0; i < SIGNER_COUNT; ++i) {
            if (candidate[i] == address(0)) revert InvalidSigners();
            for (uint256 j = i + 1; j < SIGNER_COUNT; ++j) {
                if (candidate[i] == candidate[j]) revert InvalidSigners();
            }
        }
    }
}
