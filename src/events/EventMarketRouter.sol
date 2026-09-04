// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {EIP712} from "solady/utils/EIP712.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";

import {IEventMarket} from "./IEventMarket.sol";
import {IEventMarketFactory} from "./IEventMarketFactory.sol";
import {IEventMarketRouter} from "./IEventMarketRouter.sol";

/// @title  EventMarketRouter — wallet-authorized entrypoint for LMSR event-market trading.
///
/// @notice The single USDC-approval target for users: a trader approves USDC to this router once,
///         signs the exact market/outcome/amount/slippage/deadline/nonce/executor payload, and the
///         off-chain engine operator relays that order across any genuine factory market.
///         The router holds no funds at rest — it transiently custodies USDC only within a single
///         signed BUY, immediately forwarding it into the target market.
///
/// @dev    Three-layer authority model (audit-required):
///
///         (i)  The *market* trusts the *router*. The router is registered as an allowlisted
///              operator on the EventMarketFactory (`factory.isOperator(router) == true`) via the
///              timelocked `proposeAddOperator` / `activateAddOperator` flow; removal is immediate.
///              On that basis each market's `*For` entrypoints accept the router as a caller and
///              honour the `trader` it supplies (crediting shares to / pulling proceeds for that
///              trader).
///
///         (ii) The *router* authenticates *its* caller. The router maintains its own operator
///              allowlist holding the engine's KMS operator key, and the signed `executor` must
///              equal that caller.
///
///         (iii) The *wallet* authorizes every execution-sensitive field using EIP-712. EOA and
///               ERC-1271 signatures are supported. A `(trader, nonce)` is one-use, deadlines are
///               enforced on chain, and wallets can cancel one nonce or invalidate a nonce range.
///
///         The engine cannot spend an allowance or burn shares using only its operator role. The
///         legacy unsigned selectors remain in the ABI for proxy compatibility but always revert.
///
/// @dev    Share/position state lives in the markets, keyed by the real trader address. The router
///         stores only governance, allowlist, and replay-protection state.
contract EventMarketRouter is Initializable, UUPSUpgradeable, EIP712, ReentrancyGuard, IEventMarketRouter {
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
        mapping(address trader => mapping(uint256 nonce => bool used)) nonceUsed;
        mapping(address trader => uint256 minimum) minimumValidNonce;
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
    bytes32 public constant EVENT_ORDER_TYPEHASH = keccak256(
        "EventOrder(address trader,address executor,address market,bool isYes,uint8 intent,uint256 amountIn,uint256 minAmountOut,uint256 nonce,uint64 deadline)"
    );

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
    // Trader-authorized entrypoint
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IEventMarketRouter
    function executeOrder(
        EventOrder calldata order,
        bytes calldata signature
    )
        external
        nonReentrant
        onlyOperator
        returns (uint256 amountOut)
    {
        if (order.trader == address(0)) revert ZeroTrader();
        if (order.executor != msg.sender) revert UnauthorizedExecutor(order.executor, msg.sender);
        if (order.intent == OrderIntent.UNSET) revert InvalidOrderIntent(order.intent);
        if (order.amountIn == 0) revert AmountZero();
        if (block.timestamp > order.deadline) revert DeadlineExpired(order.deadline);

        Layout storage s = _s();
        uint256 minimum = s.minimumValidNonce[order.trader];
        if (order.nonce < minimum) revert NonceInvalid(order.trader, order.nonce, minimum);
        if (s.nonceUsed[order.trader][order.nonce]) revert NonceAlreadyUsed(order.trader, order.nonce);

        bytes32 digest = _hashOrder(order);
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(order.trader, digest, signature)) {
            revert InvalidSignature(order.trader, digest);
        }
        if (!IEventMarketFactory(s.factory).isMarket(order.market)) revert NotAMarket(order.market);

        // CEI: reserve the nonce before touching the token/market. Any downstream revert unwinds
        // the marker, so a corrected retry remains possible without opening reentrancy or replay.
        s.nonceUsed[order.trader][order.nonce] = true;
        if (order.intent == OrderIntent.BUY) {
            amountOut = _buy(order, s.usdc);
        } else if (order.intent == OrderIntent.SELL) {
            amountOut = IEventMarket(order.market)
                .sellOutcomeFor(order.trader, order.isYes, order.amountIn, order.minAmountOut);
        } else {
            revert InvalidOrderIntent(order.intent);
        }

        emit EventOrderExecuted(
            digest,
            order.trader,
            order.market,
            order.executor,
            order.isYes,
            order.intent,
            order.amountIn,
            amountOut,
            order.nonce
        );
    }

    function _buy(EventOrder calldata order, address usdc_) private returns (uint256 shares) {
        IERC20 token = IERC20(usdc_);
        // The validated wallet signature binds this exact trader, token spend, market, executor,
        // nonce, and deadline. The router operator cannot choose an arbitrary allowance owner.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        token.safeTransferFrom(order.trader, address(this), order.amountIn);
        token.forceApprove(order.market, order.amountIn);
        shares = IEventMarket(order.market).buyOutcomeFor(order.trader, order.isYes, order.amountIn, order.minAmountOut);
        token.forceApprove(order.market, 0);
    }

    /// @inheritdoc IEventMarketRouter
    function cancelOrder(EventOrder calldata order) external {
        if (msg.sender != order.trader) revert Unauthorized(msg.sender);
        Layout storage s = _s();
        if (s.nonceUsed[order.trader][order.nonce]) revert NonceAlreadyUsed(order.trader, order.nonce);
        bytes32 digest = _hashOrder(order);
        s.nonceUsed[order.trader][order.nonce] = true;
        emit EventOrderCancelled(order.trader, digest, order.nonce);
    }

    /// @inheritdoc IEventMarketRouter
    function invalidateNoncesBelow(uint256 newMinimum) external {
        Layout storage s = _s();
        uint256 oldMinimum = s.minimumValidNonce[msg.sender];
        if (newMinimum <= oldMinimum) revert NonceFloorNotIncreasing(oldMinimum, newMinimum);
        s.minimumValidNonce[msg.sender] = newMinimum;
        emit MinimumValidNonceSet(msg.sender, oldMinimum, newMinimum);
    }

    // ------------------------------------------------------------------------------------------
    // Deprecated unsigned operator entrypoints
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc IEventMarketRouter
    function buyOutcomeFor(address, address, bool, uint256, uint256) external pure returns (uint256) {
        revert SignedOrderRequired();
    }

    /// @inheritdoc IEventMarketRouter
    function sellOutcomeFor(address, address, bool, uint256, uint256) external pure returns (uint256) {
        revert SignedOrderRequired();
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

    /// @inheritdoc IEventMarketRouter
    function hashOrder(EventOrder calldata order) external view returns (bytes32 digest) {
        return _hashOrder(order);
    }

    function _hashOrder(EventOrder calldata order) private view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(
                EVENT_ORDER_TYPEHASH,
                order.trader,
                order.executor,
                order.market,
                order.isYes,
                order.intent,
                order.amountIn,
                order.minAmountOut,
                order.nonce,
                order.deadline
            )
        );
        return _hashTypedData(structHash);
    }

    /// @inheritdoc IEventMarketRouter
    function isNonceUsed(address trader, uint256 nonce) external view returns (bool) {
        return _s().nonceUsed[trader][nonce];
    }

    /// @inheritdoc IEventMarketRouter
    function minimumValidNonce(address trader) external view returns (uint256) {
        return _s().minimumValidNonce[trader];
    }

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        return ("PeopleMarketsEventOrders", "1");
    }

    /// @inheritdoc IEventMarketRouter
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
