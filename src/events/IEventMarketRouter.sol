// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

interface IEventMarketRouter {
    // --- Events ---
    event Initialized(address governance, address factory, address usdc);
    event OperatorProposed(address indexed operator, uint64 activatesAt);
    event OperatorActivated(address indexed operator);
    event OperatorCancelled(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event GovernanceTransferProposed(address indexed newGovernance, uint64 activatesAt);
    event GovernanceTransferActivated(address indexed oldGovernance, address indexed newGovernance);
    event GovernanceTransferCancelled(address indexed pendingGovernance);

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

    // --- Trader entrypoints (operator-gated) ---

    /// @notice Relay a buy on behalf of `trader`. Only an allowlisted operator (the engine KMS key)
    ///         may call. Pulls `usdcAmount` from `trader` (single approval to this router), routes
    ///         it into `market`, and credits the minted shares to `trader`.
    function buyOutcomeFor(
        address trader,
        address market,
        bool isYes,
        uint256 usdcAmount,
        uint256 minSharesOut
    )
        external
        returns (uint256 shares);

    /// @notice Relay a sell on behalf of `trader`. Only an allowlisted operator may call. Burns
    ///         `sharesAmount` of `trader`'s shares in `market`; proceeds are sent directly to
    ///         `trader` by the market.
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
}
