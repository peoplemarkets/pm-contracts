// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

interface IEventMarketRouter {
    enum OrderIntent {
        UNSET,
        BUY,
        SELL
    }

    /// @notice One immediate LMSR trade authorized by the wallet that owns the funds or shares.
    /// @dev `amountIn` is USDC for BUY and outcome shares for SELL. `minAmountOut` is the
    ///      corresponding minimum shares or USDC. The EIP-712 domain binds chain and router;
    ///      `executor` binds the signature to one allowlisted engine operator.
    struct EventOrder {
        address trader;
        address executor;
        address market;
        bool isYes;
        OrderIntent intent;
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 nonce;
        uint64 deadline;
    }

    // --- Events ---
    event Initialized(address governance, address factory, address usdc);
    event OperatorProposed(address indexed operator, uint64 activatesAt);
    event OperatorActivated(address indexed operator);
    event OperatorCancelled(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event GovernanceTransferProposed(address indexed newGovernance, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceTransferCancelled(address indexed pendingGovernance);
    event EventOrderExecuted(
        bytes32 indexed orderHash,
        address indexed trader,
        address indexed market,
        address executor,
        bool isYes,
        OrderIntent intent,
        uint256 amountIn,
        uint256 amountOut,
        uint256 nonce
    );
    event EventOrderCancelled(address indexed trader, bytes32 indexed orderHash, uint256 nonce);
    event MinimumValidNonceSet(address indexed trader, uint256 oldMinimum, uint256 newMinimum);

    // --- Errors ---
    error InvalidConfig();
    error Unauthorized(address caller);
    error NotOperator(address caller);
    error NotAMarket(address market);
    error ZeroTrader();
    error OperatorAlreadySet(address operator);
    error PendingOperatorExists(address operator);
    error NoPendingOperator(address operator);
    error OperatorNotSet(address operator);
    error TimelockNotElapsed(uint64 readyAt);
    error PendingProposalExists();
    error NoPendingProposal();
    error SignedOrderRequired();
    error InvalidOrderIntent(OrderIntent intent);
    error AmountZero();
    error DeadlineExpired(uint64 deadline);
    error UnauthorizedExecutor(address expected, address actual);
    error NonceInvalid(address trader, uint256 nonce, uint256 minimum);
    error NonceAlreadyUsed(address trader, uint256 nonce);
    error NonceFloorNotIncreasing(uint256 currentMinimum, uint256 attemptedMinimum);
    error InvalidSignature(address trader, bytes32 orderHash);

    // --- Trader-authorized entrypoint ---

    /// @notice Execute one wallet-signed BUY or SELL. Only the signed, allowlisted executor may
    ///         relay it, and a `(trader, nonce)` can be consumed at most once.
    function executeOrder(EventOrder calldata order, bytes calldata signature) external returns (uint256 amountOut);

    /// @notice Cancel one signed order before execution. Only the trader may cancel it.
    function cancelOrder(EventOrder calldata order) external;

    /// @notice Invalidate every order nonce below `newMinimum` for the caller.
    function invalidateNoncesBelow(uint256 newMinimum) external;

    // --- Deprecated unsigned operator entrypoints ---

    /// @notice Deprecated selector retained for upgrade compatibility. Always reverts because an
    ///         operator-supplied trader address is not wallet authorization.
    function buyOutcomeFor(
        address trader,
        address market,
        bool isYes,
        uint256 usdcAmount,
        uint256 minSharesOut
    )
        external
        returns (uint256 shares);

    /// @notice Deprecated selector retained for upgrade compatibility. Always reverts.
    function sellOutcomeFor(
        address trader,
        address market,
        bool isYes,
        uint256 sharesAmount,
        uint256 minUsdcOut
    )
        external
        returns (uint256 usdcOut);

    // --- Governance: operator allowlist ---
    function proposeAddOperator(address operator) external;
    function activateAddOperator(address operator) external;
    function cancelAddOperator(address operator) external;
    function removeOperator(address operator) external;

    // --- Governance transfer ---
    function proposeGovernanceTransfer(address newGovernance) external;
    function activateGovernanceTransfer() external;
    function cancelGovernanceTransfer() external;

    // --- Views ---
    function governance() external view returns (address);
    function pendingGovernance() external view returns (address account, uint64 activatesAt);
    function timelockDelay() external view returns (uint32);
    function factory() external view returns (address);
    function usdc() external view returns (address);
    function isOperator(address account) external view returns (bool);
    function pendingOperatorActivatesAt(address operator) external view returns (uint64);
    function hashOrder(EventOrder calldata order) external view returns (bytes32 digest);
    function isNonceUsed(address trader, uint256 nonce) external view returns (bool);
    function minimumValidNonce(address trader) external view returns (uint256);
    function domainSeparator() external view returns (bytes32);
}
