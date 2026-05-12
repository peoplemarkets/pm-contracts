// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IPerpEngine} from "../core/IPerpEngine.sol";

import {IPairTradeRouter} from "./IPairTradeRouter.sol";

/// @title  PairTradeRouter — atomic long-A / short-B perp pair trade router.
/// @notice Spec §0: "Pair Trades... are the headline UX." This router is a thin, stateless
///         orchestrator over `PerpEngine.openPositionFor`. The trader signs a single transaction
///         that opens two positions atomically — long on subject A, short on subject B. Either
///         both succeed or the whole tx reverts; Solidity's call semantics provide atomicity for
///         free.
///
/// @dev    The router does NOT hold funds and has no internal position storage. The trader is the
///         position owner on both legs; the trader (not the router) must have approved the
///         LPVault for at least `longCollateral + shortCollateral + combinedFee`. PerpEngine pulls
///         collateral via the existing `openPositionFlow` path on the vault.
///
/// @dev    Trust model. The router is registered on PerpEngine via the timelocked
///         `proposeAddRouter` / `activateAddRouter` flow; revocation is immediate. The router
///         itself is permissionless — anyone can call `openPair` — but it trusts its caller to be
///         the trader (`msg.sender` is forwarded directly to `openPositionFor` as the position
///         owner). Same-subject opens are rejected to prevent a self-cancelling long+short pair
///         on a single subject (which would just churn fees).
contract PairTradeRouter is Initializable, UUPSUpgradeable, IPairTradeRouter {
    // ------------------------------------------------------------------------------------------
    // Storage namespace
    // ------------------------------------------------------------------------------------------

    /// @dev Namespaced storage at `keccak256("people.markets.pairtraderouter.v1")`. Owns
    ///      governance + timelock + perp engine pointer + pending governance.
    bytes32 internal constant PAIR_ROUTER_SLOT = keccak256("people.markets.pairtraderouter.v1");

    /// @custom:storage-location erc7201:people.markets.pairtraderouter.v1
    struct Layout {
        // governance + timelock (same shape as PerpEngine)
        address governance;
        uint32 timelockDelay;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        // PerpEngine pointer — set in initialize. Stored (rather than immutable) so the proxy can
        // upgrade in place; rotation is intentionally not exposed since the deployment script
        // wires this once and the upgrade path is via UUPSUpgradeable.
        address perpEngine;
    }

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = PAIR_ROUTER_SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    uint32 internal constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 internal constant MAX_TIMELOCK_DELAY = 30 days;

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
    ///                         `proposeAddRouter` before `openPair` can succeed.
    /// @param  timelockDelay_  Governance-transfer timelock, seconds. [1h, 30d].
    function initialize(address governance_, address perpEngine_, uint32 timelockDelay_) external initializer {
        if (governance_ == address(0)) revert InvalidConfig();
        if (perpEngine_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();

        Layout storage s = _s();
        s.governance = governance_;
        s.perpEngine = perpEngine_;
        s.timelockDelay = timelockDelay_;
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != _s().governance) revert Unauthorized(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // External — pair open
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPairTradeRouter
    /// @dev Open path:
    ///        1. Reject same-subject pairs (long+short on same id is a self-cancelling no-op
    ///           that would burn fees).
    ///        2. Reject expired deadline at the router level so the trader gets a router-side
    ///           revert before the first engine call.
    ///        3. Enforce `longCollateral + shortCollateral ≤ maxTotalCollateral` (safety bound;
    ///           the engine still re-validates collateral on each leg independently).
    ///        4. Build the LONG leg OpenParams and call `openPositionFor(msg.sender, ...)`.
    ///        5. Build the SHORT leg OpenParams and call `openPositionFor(msg.sender, ...)`.
    ///        6. Emit `PairOpened` with both ids and the total collateral locked.
    ///
    ///      If leg A succeeds and leg B reverts, the whole tx reverts atomically; no manual
    ///      rollback is necessary. The router never holds funds.
    function openPair(PairParams calldata p) external returns (PairResult memory result) {
        if (p.longSubjectId == p.shortSubjectId) revert SameSubject(p.longSubjectId);
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        if (p.longCollateral == 0 || p.shortCollateral == 0) revert InvalidConfig();
        if (p.longSizeNotional == 0 || p.shortSizeNotional == 0) revert InvalidConfig();

        uint256 totalCollateral = p.longCollateral + p.shortCollateral;
        if (totalCollateral > p.maxTotalCollateral) {
            revert TotalCollateralTooHigh(totalCollateral, p.maxTotalCollateral);
        }

        IPerpEngine engine = IPerpEngine(_s().perpEngine);

        // Leg A — LONG. Body extracted to a helper to keep the via-IR stack within bounds.
        result.longPositionId = _openLeg(
            engine,
            msg.sender,
            IPerpEngine.Side.LONG,
            p.longSubjectId,
            p.longCollateral,
            p.longSizeNotional,
            p.longExpectedMark,
            p.longMaxSlippageBps,
            p.longIsMaker,
            p.deadline
        );

        // Leg B — SHORT. If this reverts the whole tx unwinds (atomic by EVM semantics).
        result.shortPositionId = _openLeg(
            engine,
            msg.sender,
            IPerpEngine.Side.SHORT,
            p.shortSubjectId,
            p.shortCollateral,
            p.shortSizeNotional,
            p.shortExpectedMark,
            p.shortMaxSlippageBps,
            p.shortIsMaker,
            p.deadline
        );

        result.totalCollateralLocked = totalCollateral;

        emit PairOpened(
            msg.sender,
            result.longPositionId,
            p.longSubjectId,
            result.shortPositionId,
            p.shortSubjectId,
            totalCollateral
        );
    }

    /// @dev Build the OpenParams for a single leg and forward to `openPositionFor`. Splitting
    ///      this out of `openPair` keeps the via-IR stack under solc's depth limit (the inline
    ///      version exceeded the bound by two slots).
    function _openLeg(
        IPerpEngine engine,
        address trader,
        IPerpEngine.Side side,
        bytes32 subjectId,
        uint256 collateral,
        uint256 sizeNotional,
        uint256 expectedMark,
        uint16 maxSlippageBps,
        bool isMaker,
        uint64 deadline
    )
        internal
        returns (bytes32 positionId)
    {
        IPerpEngine.OpenParams memory params = IPerpEngine.OpenParams({
            subjectId: subjectId,
            side: side,
            collateralAmount: collateral,
            sizeNotional: sizeNotional,
            expectedMark: expectedMark,
            maxSlippageBps: maxSlippageBps,
            deadline: deadline,
            isMaker: isMaker
        });
        return engine.openPositionFor(trader, params);
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IPairTradeRouter
    function proposeGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        if (s.pendingGovernanceActivatesAt != 0) revert PendingProposalExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingGovernance = newGovernance;
        s.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGovernance, activatesAt);
    }

    /// @inheritdoc IPairTradeRouter
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

    /// @inheritdoc IPairTradeRouter
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

    /// @inheritdoc IPairTradeRouter
    function perpEngine() external view returns (address) {
        return _s().perpEngine;
    }

    /// @inheritdoc IPairTradeRouter
    function governance() external view returns (address) {
        return _s().governance;
    }

    /// @inheritdoc IPairTradeRouter
    function timelockDelay() external view returns (uint32) {
        return _s().timelockDelay;
    }

    /// @inheritdoc IPairTradeRouter
    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        Layout storage s = _s();
        return (s.pendingGovernance, s.pendingGovernanceActivatesAt);
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
