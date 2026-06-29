// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IEventMarket} from "./IEventMarket.sol";
import {IEventMarketFactory} from "./IEventMarketFactory.sol";
import {IEventMarketRouter} from "./IEventMarketRouter.sol";

/// @title  EventMarketRouter — engine-relayed entrypoint for LMSR event-market trading.
///
/// @notice The single USDC-approval target for users: a trader approves USDC to this router once,
///         and the off-chain engine operator relays their buy/sell orders across every market.
///         The router holds no funds at rest — it transiently custodies USDC only within a single
///         `buyOutcomeFor` call, immediately forwarding it into the target market.
///
/// @dev    Two-layer trust model (DOCUMENTED, intentional, audit-required):
///
///         (i)  The *market* trusts the *router*. The router is registered as an allowlisted
///              operator on the EventMarketFactory (`factory.isOperator(router) == true`) via the
///              timelocked `proposeAddOperator` / `activateAddOperator` flow; removal is immediate.
///              On that basis each market's `*For` entrypoints accept the router as a caller and
///              honour the `trader` it supplies (crediting shares to / pulling proceeds for that
///              trader).
///
///         (ii) The *router* authenticates *its* caller. The router maintains its own operator
///              allowlist holding the engine's KMS operator key. `buyOutcomeFor` / `sellOutcomeFor`
///              are gated `onlyOperator`, so only that key can move an approving trader's USDC.
///
///         The net authority: the engine operator key can spend the USDC any user has approved to
///         this router, on that user's behalf, into genuine factory markets. This is CEX-operator-
///         style trust (acknowledged in the design doc). Mitigations: KMS custody, the user's
///         allowance is the hard spend cap, governance kill switch (immediate `removeOperator` on
///         both this router AND the factory), and per-operator spend monitoring off-chain.
///
/// @dev    Stateless w.r.t. positions: all share/position state lives in the markets, keyed by the
///         real trader address. The router only stores governance + allowlist config.
contract EventMarketRouter is Initializable, UUPSUpgradeable, IEventMarketRouter {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------------------------------
    // Storage namespace (erc7201), mirroring BatchRouter.
    // ------------------------------------------------------------------------------------------

    /// @dev Namespaced storage at `keccak256("people.markets.eventmarketrouter.v1")`.
    bytes32 internal constant EVENT_MARKET_ROUTER_SLOT = keccak256("people.markets.eventmarketrouter.v1");

    /// @custom:storage-location erc7201:people.markets.eventmarketrouter.v1
    struct Layout {
        address governance;
        uint32 timelockDelay;
        address pendingGovernance;
        uint64 pendingGovernanceActivatesAt;
        address factory;
        address usdc;
        mapping(address => bool) operators;
        mapping(address => uint64) pendingOperatorActivatesAt;
    }

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = EVENT_MARKET_ROUTER_SLOT;
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

    /// @notice Initialize the router (one-time, via proxy).
    /// @param  governance_    Multi-sig managing operator allowlist + upgrades; timelocked transfer.
    /// @param  factory_       EventMarketFactory used to validate market addresses.
    /// @param  usdc_          USDC token pulled from traders.
    /// @param  timelockDelay_ Operator-add + governance-transfer timelock, seconds. [1h, 30d].
    function initialize(
        address governance_,
        address factory_,
        address usdc_,
        uint32 timelockDelay_
    )
        external
        initializer
    {
        if (governance_ == address(0) || factory_ == address(0) || usdc_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();

        Layout storage s = _s();
        s.governance = governance_;
        s.factory = factory_;
        s.usdc = usdc_;
        s.timelockDelay = timelockDelay_;

        emit Initialized(governance_, factory_, usdc_);
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != _s().governance) revert Unauthorized(msg.sender);
        _;
    }

    /// @dev Layer (ii): authenticate the caller as the allowlisted engine operator key.
    modifier onlyOperator() {
        if (!_s().operators[msg.sender]) revert NotOperator(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // Trader entrypoints (operator-gated)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IEventMarketRouter
    function buyOutcomeFor(
        address trader,
        address market,
        bool isYes,
        uint256 usdcAmount,
        uint256 minSharesOut
    )
        external
        onlyOperator
        returns (uint256 shares)
    {
        if (trader == address(0)) revert ZeroTrader();
        Layout storage s = _s();
        // Only ever route trader funds into a genuine factory-created market.
        if (!IEventMarketFactory(s.factory).isMarket(market)) revert NotAMarket(market);

        IERC20 token = IERC20(s.usdc);
        // Pull USDC from the trader (single approval to this router) into the router transiently.
        // slither-disable-next-line arbitrary-send-erc20 -- onlyOperator; `trader` approved this router and is credited the shares.
        token.safeTransferFrom(trader, address(this), usdcAmount);
        // Approve exactly this spend to the market, which pulls it inside buyOutcomeFor.
        token.forceApprove(market, usdcAmount);

        shares = IEventMarket(market).buyOutcomeFor(trader, isYes, usdcAmount, minSharesOut);

        // Hygiene: clear any residual allowance (market pulled exactly usdcAmount).
        token.forceApprove(market, 0);
    }

    /// @inheritdoc IEventMarketRouter
    function sellOutcomeFor(
        address trader,
        address market,
        bool isYes,
        uint256 sharesAmount,
        uint256 minUsdcOut
    )
        external
        onlyOperator
        returns (uint256 usdcOut)
    {
        if (trader == address(0)) revert ZeroTrader();
        Layout storage s = _s();
        if (!IEventMarketFactory(s.factory).isMarket(market)) revert NotAMarket(market);

        // No USDC flows through the router on sells: the market pays proceeds directly to `trader`.
        usdcOut = IEventMarket(market).sellOutcomeFor(trader, isYes, sharesAmount, minUsdcOut);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: operator allowlist (timelocked add / immediate remove)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IEventMarketRouter
    function proposeAddOperator(address operator) external onlyGovernance {
        if (operator == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        if (s.operators[operator]) revert OperatorAlreadySet(operator);
        if (s.pendingOperatorActivatesAt[operator] != 0) revert PendingOperatorExists(operator);
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingOperatorActivatesAt[operator] = activatesAt;
        emit OperatorProposed(operator, activatesAt);
    }

    /// @inheritdoc IEventMarketRouter
    function activateAddOperator(address operator) external {
        Layout storage s = _s();
        uint64 readyAt = s.pendingOperatorActivatesAt[operator];
        if (readyAt == 0) revert NoPendingOperator(operator);
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        delete s.pendingOperatorActivatesAt[operator];
        s.operators[operator] = true;
        emit OperatorActivated(operator);
    }

    /// @inheritdoc IEventMarketRouter
    function cancelAddOperator(address operator) external onlyGovernance {
        Layout storage s = _s();
        if (s.pendingOperatorActivatesAt[operator] == 0) revert NoPendingOperator(operator);
        delete s.pendingOperatorActivatesAt[operator];
        emit OperatorCancelled(operator);
    }

    /// @inheritdoc IEventMarketRouter
    function removeOperator(address operator) external onlyGovernance {
        Layout storage s = _s();
        if (!s.operators[operator]) revert OperatorNotSet(operator);
        delete s.operators[operator];
        emit OperatorRemoved(operator);
    }

    // ------------------------------------------------------------------------------------------
    // Governance transfer (timelocked) — mirrors BatchRouter.
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IEventMarketRouter
    function proposeGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidConfig();
        Layout storage s = _s();
        if (s.pendingGovernanceActivatesAt != 0) revert PendingProposalExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingGovernance = newGovernance;
        s.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGovernance, activatesAt);
    }

    /// @inheritdoc IEventMarketRouter
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

    /// @inheritdoc IEventMarketRouter
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

    /// @inheritdoc IEventMarketRouter
    function governance() external view returns (address) {
        return _s().governance;
    }

    /// @inheritdoc IEventMarketRouter
    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        Layout storage s = _s();
        return (s.pendingGovernance, s.pendingGovernanceActivatesAt);
    }

    /// @inheritdoc IEventMarketRouter
    function timelockDelay() external view returns (uint32) {
        return _s().timelockDelay;
    }

    /// @inheritdoc IEventMarketRouter
    function factory() external view returns (address) {
        return _s().factory;
    }

    /// @inheritdoc IEventMarketRouter
    function usdc() external view returns (address) {
        return _s().usdc;
    }

    /// @inheritdoc IEventMarketRouter
    function isOperator(address account) external view returns (bool) {
        return _s().operators[account];
    }

    /// @inheritdoc IEventMarketRouter
    function pendingOperatorActivatesAt(address operator) external view returns (uint64) {
        return _s().pendingOperatorActivatesAt[operator];
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
