// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IPerpEngine} from "../core/IPerpEngine.sol";

import {IBatchRouter} from "./IBatchRouter.sol";

/// @title  BatchRouter — multi-op atomic-batch perp router.
/// @notice Wave 6C. Executes a sequence of position operations (open / close / add-collateral /
///         remove-collateral) in a single transaction with all-or-nothing semantics. If any leg
///         reverts, Solidity's call unwinding rolls back every other leg — no manual rollback.
///
/// @dev    The router never holds funds and has no internal position storage. The trader
///         (`msg.sender`) is the position owner on every op; PerpEngine's `*For` family debits the
///         trader directly via LPVault. The trader MUST have approved the LPVault for the aggregate
///         collateral + fees required by the OPEN / ADD_COLLATERAL ops.
///
/// @dev    Trust model. The router is registered on PerpEngine via the timelocked
///         `proposeAddRouter` / `activateAddRouter` flow; revocation is immediate. The router
///         itself is permissionless — anyone can call `executeBatch` — but it trusts its caller to
///         be the trader (`msg.sender` forwards directly to PerpEngine as the position owner).
contract BatchRouter is Initializable, UUPSUpgradeable, IBatchRouter {
    // ------------------------------------------------------------------------------------------
    // Storage namespace
    // ------------------------------------------------------------------------------------------

    /// @dev Namespaced storage at `keccak256("people.markets.batchrouter.v1")`.
    bytes32 internal constant BATCH_ROUTER_SLOT = keccak256("people.markets.batchrouter.v1");

    /// @custom:storage-location erc7201:people.markets.batchrouter.v1
    struct Layout {
        address governance;
        uint32 timelockDelay;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        // PerpEngine pointer — set in initialize. Stored rather than immutable so the proxy can
        // upgrade in place; the deployment script wires this once.
        address perpEngine;
        // Hard bound on `ops.length` per batch — defends gas budget against pathological batches.
        uint16 maxBatchSize;
    }

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = BATCH_ROUTER_SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    uint32 internal constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 internal constant MAX_TIMELOCK_DELAY = 30 days;

    uint16 internal constant DEFAULT_MAX_BATCH_SIZE = 20;
    uint16 internal constant MIN_MAX_BATCH_SIZE = 1;
    uint16 internal constant MAX_MAX_BATCH_SIZE = 100;

    // ------------------------------------------------------------------------------------------
    // Constructor / initializer
    // ------------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the router. One-time, called via the proxy.
    /// @param  governance_     Multi-sig that proposes/activates governance transfers; timelocked.
    /// @param  perpEngine_     PerpEngine address. The router must be registered there via
    ///                         `proposeAddRouter` before any `*For` call succeeds.
    /// @param  timelockDelay_  Governance-transfer timelock, seconds. [1h, 30d].
    function initialize(address governance_, address perpEngine_, uint32 timelockDelay_) external initializer {
        if (governance_ == address(0)) revert InvalidConfig();
        if (perpEngine_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();

        Layout storage s = _s();
        s.governance = governance_;
        s.perpEngine = perpEngine_;
        s.timelockDelay = timelockDelay_;
        s.maxBatchSize = DEFAULT_MAX_BATCH_SIZE;

        emit Initialized(governance_, perpEngine_);
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != _s().governance) revert Unauthorized(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // External — batch execution
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IBatchRouter
    /// @dev Atomicity. The router validates the batch envelope (size, deadline) then loops through
    ///      ops. Each cross-call into PerpEngine can revert; Solidity's transaction-level revert
    ///      semantics unwind every preceding leg in the same tx automatically.
    function executeBatch(BatchParams calldata params) external returns (OpResult[] memory results) {
        uint256 count = params.ops.length;
        if (count == 0) revert EmptyBatch();
        uint16 cap = _s().maxBatchSize;
        if (count > uint256(cap)) revert BatchTooLarge(count, uint256(cap));
        if (block.timestamp > params.deadline) revert DeadlineExpired(params.deadline);

        IPerpEngine engine = IPerpEngine(_s().perpEngine);
        results = new OpResult[](count);

        for (uint256 i; i < count; ++i) {
            results[i] = _executeOp(engine, params.ops[i]);
        }

        emit BatchExecuted(msg.sender, count);
    }

    /// @dev Dispatch a single batch op. Each kind branch fully encloses one PerpEngine call and
    ///      one result write; UNSET (and any other unknown discriminator) reverts via
    ///      `InvalidOpKind`. Extracted from the loop so each branch is a self-contained code path
    ///      (cleaner branch coverage; avoids the if/else-if-chain accounting quirk).
    function _executeOp(IPerpEngine engine, BatchOp calldata op) internal returns (OpResult memory) {
        OpKind kind = op.kind;
        if (kind == OpKind.OPEN) {
            IPerpEngine.OpenParams memory openParams = abi.decode(op.openData, (IPerpEngine.OpenParams));
            bytes32 positionId = engine.openPositionFor(msg.sender, openParams);
            return OpResult({kind: kind, positionId: positionId, pnl: int256(0)});
        }
        if (kind == OpKind.CLOSE) {
            IPerpEngine.CloseParams memory closeParams = abi.decode(op.closeData, (IPerpEngine.CloseParams));
            bytes32 closingPositionId = engine.positionIdOf(msg.sender, closeParams.subjectId);
            int256 pnl = engine.closePositionFor(msg.sender, closeParams);
            return OpResult({kind: kind, positionId: closingPositionId, pnl: pnl});
        }
        if (kind == OpKind.ADD_COLLATERAL) {
            engine.addCollateralFor(msg.sender, op.positionId, op.amount);
            return OpResult({kind: kind, positionId: op.positionId, pnl: int256(0)});
        }
        if (kind == OpKind.REMOVE_COLLATERAL) {
            engine.removeCollateralFor(msg.sender, op.positionId, op.amount);
            return OpResult({kind: kind, positionId: op.positionId, pnl: int256(0)});
        }
        // OpKind.UNSET (0) or any unknown discriminator.
        revert InvalidOpKind();
    }

    // ------------------------------------------------------------------------------------------
    // Governance — batch size cap (immediate, no timelock)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IBatchRouter
    function setMaxBatchSize(uint16 newMaxBatchSize) external onlyGovernance {
        if (newMaxBatchSize < MIN_MAX_BATCH_SIZE || newMaxBatchSize > MAX_MAX_BATCH_SIZE) {
            revert MaxBatchSizeOutOfRange(newMaxBatchSize);
        }
        Layout storage s = _s();
        uint16 old = s.maxBatchSize;
        s.maxBatchSize = newMaxBatchSize;
        emit MaxBatchSizeSet(old, newMaxBatchSize);
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IBatchRouter
    function proposeGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        if (s.pendingGovernanceActivatesAt != 0) revert PendingProposalExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingGovernance = newGovernance;
        s.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGovernance, activatesAt);
    }

    /// @inheritdoc IBatchRouter
    function activateGovernanceTransfer() external {
        Layout storage s = _s();
        uint64 readyAt = s.pendingGovernanceActivatesAt;
        if (readyAt == 0) revert NoPendingProposal();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldGov = s.governance;
        address newGov = s.pendingGovernance;
        s.governance = newGov;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferActivated(oldGov, newGov);
    }

    /// @inheritdoc IBatchRouter
    function cancelGovernanceTransfer() external onlyGovernance {
        Layout storage s = _s();
        if (s.pendingGovernanceActivatesAt == 0) revert NoPendingProposal();
        address pending = s.pendingGovernance;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IBatchRouter
    function perpEngine() external view returns (address) {
        return _s().perpEngine;
    }

    /// @inheritdoc IBatchRouter
    function governance() external view returns (address) {
        return _s().governance;
    }

    /// @inheritdoc IBatchRouter
    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        Layout storage s = _s();
        return (s.pendingGovernance, s.pendingGovernanceActivatesAt);
    }

    /// @inheritdoc IBatchRouter
    function timelockDelay() external view returns (uint32) {
        return _s().timelockDelay;
    }

    /// @inheritdoc IBatchRouter
    function maxBatchSize() external view returns (uint16) {
        return _s().maxBatchSize;
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
