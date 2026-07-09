// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IEventMarket} from "../../../src/events/IEventMarket.sol";
import {IFeedbackController} from "../../../src/feedback/IFeedbackController.sol";
import {IOracleRouter} from "../../../src/oracle/IOracleRouter.sol";
import {UMAAdapter} from "../../../src/oracle/UMAAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal LPVault stand-in for EventMarketFactory tests. The factory calls
///         `fundEventMarket` (expects to receive `amount` USDC) and `settleEventMarket` (the factory
///         approves it `returnedAmount` beforehand). We avoid pulling the full perp LPVault into the
///         event-market unit tests; the resolve→settle accounting is covered by the LPVault suite.
contract MockLPVault {
    IERC20 public immutable usdc;
    uint256 public lastSeed;
    uint256 public lastReturned;
    uint256 public lastLockedSurplus;
    address public lastMarket;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    /// @dev Send `amount` USDC to the caller (the factory), modelling seed funding. Records the
    ///      registered `market` (event-NAV v2 signature).
    function fundEventMarket(address market, uint256 amount) external {
        lastMarket = market;
        usdc.transfer(msg.sender, amount);
    }

    /// @dev Pull `returnedAmount` back from the caller (the factory approved us first). Records the
    ///      de-registered `market` (event-NAV v2 signature).
    function settleEventMarket(
        address market,
        uint256 originalSeed,
        uint256 returnedAmount,
        uint256 lockedSurplus
    )
        external
    {
        lastMarket = market;
        lastSeed = originalSeed;
        lastReturned = returnedAmount;
        lastLockedSurplus = lockedSurplus;
        if (returnedAmount > 0) {
            usdc.transferFrom(msg.sender, address(this), returnedAmount);
        }
    }
}

/// @notice No-op FeedbackController for event-market tests; the factory calls `applyResolution`
///         on resolve. Feedback math is covered by FeedbackController.t.sol.
contract MockFeedbackController {
    IFeedbackController.ResolutionInput public lastInput;
    bool public called;

    function applyResolution(IFeedbackController.ResolutionInput calldata input) external {
        lastInput = input;
        called = true;
    }
}

/// @notice Mock of the concrete UMAAdapter type the market/factory hold. We only need
///         `proposeAssertion` (no-op) and `latestValue` (settable) for resolution tests, so we cast
///         this address to `UMAAdapter` when wiring the factory. The runtime call dispatches here.
contract MockUMAAdapter {
    uint256 internal _value;
    uint64 internal _ts;
    // Fix D readiness gate: metrics are registered BY DEFAULT so pre-existing tests (which never
    // registered a UMA metric) keep passing. A test can call `setRegistered(id, false)` to exercise
    // the `MetricNotReady` revert path.
    mapping(bytes32 => bool) internal _unregistered;

    function setLatestValue(uint256 value_, uint64 ts_) external {
        _value = value_;
        _ts = ts_;
    }

    /// @dev Test helper for the factory's Fix D readiness gate
    ///      (`umaAdapter.metricOf(eventId).registered`). Default is registered; pass `false` to
    ///      simulate an un-activated metric.
    function setRegistered(bytes32 metricId, bool registered) external {
        _unregistered[metricId] = !registered;
    }

    /// @dev Mirrors `UMAAdapter.metricOf` shape: the factory only reads `.registered`. ABI-compatible
    ///      with the real `UMAAdapter.UMAMetric`. Registered unless explicitly un-set.
    function metricOf(bytes32 metricId) external view returns (UMAAdapter.UMAMetric memory m) {
        m.registered = !_unregistered[metricId];
    }

    function proposeAssertion(bytes32, uint256 claimedValue, bytes calldata) external returns (bytes32) {
        // Simulate an immediately-settled truthful assertion for test convenience.
        _value = claimedValue;
        _ts = uint64(block.timestamp);
        return keccak256(abi.encode(claimedValue, block.timestamp));
    }

    function latestValue(bytes32) external view returns (uint256 value, uint64 valueTimestamp) {
        return (_value, _ts);
    }
}

/// @notice Minimal EventMarket-shaped implementation used to prove `createMarket` clones whichever
///         template is currently installed. It exposes the exact `initialize(IERC20,UMAAdapter,
///         MarketParams)` selector the factory calls on a fresh clone (so creation succeeds) plus a
///         constant `implTag()` marker that differs from the real EventMarket, letting a test assert
///         the clone's behaviour switches to the newly activated template. It is deliberately inert
///         beyond recording the eventId so the clone can be identified.
contract MockEventMarketImpl {
    bytes32 public eventId;
    bool private _initialized;

    /// @notice Marker distinguishing this template from the real EventMarket clones in tests.
    function implTag() external pure returns (bytes32) {
        return keccak256("MockEventMarketImpl.v1");
    }

    /// @dev Selector-compatible with EventMarket.initializeV2 so `createMarket`/`_create` can clone
    ///      + init this. (The factory now always calls `initializeV2`.)
    function initializeV2(
        IERC20,
        UMAAdapter,
        IEventMarket.MarketParams memory params_,
        IEventMarket.ResolutionConfig memory
    )
        external
    {
        require(!_initialized, "already init");
        _initialized = true;
        eventId = params_.eventId;
    }
}

/// @notice Malicious ERC20-callback reentrancy probe. On receiving a transfer it re-enters the
///         market's buyOutcome; the market's nonReentrant guard must revert. Used only to prove the
///         reentrancy guard — real USDC has no transfer hooks.
contract ReentrantToken is IERC20 {
    string public name = "Reentrant";
    string public symbol = "RE";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public attackTarget;
    bool public attackArmed;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function arm(address target) external {
        attackTarget = target;
        attackArmed = true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        // Re-enter on the way in (during the market's safeTransferFrom).
        if (attackArmed && attackTarget != address(0)) {
            attackArmed = false;
            (bool ok,) =
                attackTarget.call(abi.encodeWithSignature("buyOutcome(bool,uint256,uint256)", true, amount, uint256(0)));
            require(ok, "reentry blocked");
        }
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice OracleRouter stand-in for the objective (ORACLE_ROUTER) resolution path. Reproduces the
///         exact read-time guards the real router enforces — `MetricNotRegistered`, `StaleReading`,
///         `DegradedAndNoFallback` — and the `configOf().sourceType` surface the factory's Fix D
///         readiness gate reads. Only the surface EventMarket + EventMarketFactory touch is modelled.
contract MockOracleRouter is IOracleRouter {
    struct Feed {
        bool registered;
        uint256 value;
        uint64 updatedAt;
        uint32 staleAfter;
        bool degraded;
        bool hasFallback;
        SourceType sourceType;
    }

    mapping(bytes32 => Feed) internal _feeds;

    /// @dev Register a metric with an initial reading. `sourceType` != UNSET is what the factory
    ///      readiness gate checks; SIGNED is the natural objective-feed type.
    function registerMetric(bytes32 metricId, uint256 value, uint64 updatedAt, uint32 staleAfter) external {
        _feeds[metricId] = Feed({
            registered: true,
            value: value,
            updatedAt: updatedAt,
            staleAfter: staleAfter,
            degraded: false,
            hasFallback: false,
            sourceType: SourceType.SIGNED
        });
    }

    function setValue(bytes32 metricId, uint256 value, uint64 updatedAt) external {
        _feeds[metricId].value = value;
        _feeds[metricId].updatedAt = updatedAt;
    }

    /// @dev Flip degraded; `hasFallback` decides whether `read` reverts (no fallback) or returns a
    ///      degraded reading (fallback present) — the market fails closed on degraded either way.
    function setDegraded(bytes32 metricId, bool degraded, bool hasFallback) external {
        _feeds[metricId].degraded = degraded;
        _feeds[metricId].hasFallback = hasFallback;
    }

    // -- Reads (the only surface EventMarket + factory use) --

    function read(bytes32 metricId) external view returns (OracleReading memory reading) {
        Feed memory f = _feeds[metricId];
        if (f.sourceType == SourceType.UNSET) revert MetricNotRegistered(metricId);
        if (f.degraded && !f.hasFallback) revert DegradedAndNoFallback(metricId);
        if (uint64(block.timestamp) > f.updatedAt + uint64(f.staleAfter)) {
            revert StaleReading(metricId, f.updatedAt, f.staleAfter);
        }
        reading = OracleReading({value: f.value, updatedAt: f.updatedAt, degraded: f.degraded});
    }

    function configOf(bytes32 metricId) external view returns (MetricConfig memory c) {
        Feed memory f = _feeds[metricId];
        c.sourceType = f.sourceType;
        c.staleAfter = f.staleAfter;
        c.degraded = f.degraded;
    }

    // -- Unused interface surface (revert if ever hit so a test misuse is loud). --
    function cadenceOf(bytes32) external pure returns (uint32) {
        return 0;
    }

    function proposeRegister(bytes32, MetricConfig calldata) external pure {
        revert("unused");
    }

    function activateRegister(bytes32) external pure {
        revert("unused");
    }

    function cancelProposal(bytes32) external pure {
        revert("unused");
    }

    function setDegraded(bytes32, bool, bytes32) external pure {
        revert("unused");
    }

    function proposeSetFallback(bytes32, address) external pure {
        revert("unused");
    }

    function activateSetFallback(bytes32) external pure {
        revert("unused");
    }

    function markIfStale(bytes32) external pure {
        revert("unused");
    }

    function proposeGovernanceTransfer(address) external pure {
        revert("unused");
    }

    function activateGovernanceTransfer() external pure {
        revert("unused");
    }

    function cancelGovernanceTransfer() external pure {
        revert("unused");
    }

    function setOperator(address) external pure {
        revert("unused");
    }

    function pendingGovernance() external pure returns (address, uint64) {
        return (address(0), 0);
    }
}
