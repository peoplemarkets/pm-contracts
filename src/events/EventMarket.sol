// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {UMAAdapter} from "../oracle/UMAAdapter.sol";
import {IEventMarket} from "./IEventMarket.sol";
import {IEventMarketFactory} from "./IEventMarketFactory.sol";
import {LMSRMath} from "./LMSRMath.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title EventMarket — LMSR-based Binary Prediction Market
contract EventMarket is Initializable, IEventMarket, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    IEventMarketFactory public factory;
    UMAAdapter public umaAdapter;

    MarketParams private _params;
    Status private _status;
    Outcome private _outcome;

    uint256 public q1; // YES shares
    uint256 public q2; // NO shares

    // User balances
    mapping(address => uint256) public yesBalance;
    mapping(address => uint256) public noBalance;

    event SharesBought(address indexed buyer, bool isYes, uint256 usdcAmount, uint256 sharesMinted);
    event SharesSold(address indexed seller, bool isYes, uint256 sharesAmount, uint256 usdcReturned);
    event MarketResolved(Outcome finalOutcome);
    event WinningsRedeemed(address indexed user, uint256 usdcPayout);

    error AmountZero();
    error NotOperator(address caller);
    error ZeroTrader();
    error InsufficientBalance();
    error SlippageExceeded(uint256 got, uint256 minRequired);

    function initialize(IERC20 usdc_, UMAAdapter umaAdapter_, MarketParams memory params_) external initializer {
        usdc = usdc_;
        factory = IEventMarketFactory(msg.sender);
        umaAdapter = umaAdapter_;
        _params = params_;
        _status = Status.OPEN;
        _outcome = Outcome.UNRESOLVED;
    }

    modifier onlyOpen() {
        require(_status == Status.OPEN, "EventMarket: not open");
        require(block.timestamp < _params.resolutionDeadline, "EventMarket: past deadline");
        _;
    }

    modifier onlyResolved() {
        require(_status == Status.RESOLVED, "EventMarket: not resolved");
        _;
    }

    /// @dev Restricts to operators allowlisted on the factory (the engine-relayed `*For` path).
    ///      The EventMarketRouter is registered as such an operator; the market trusts it to supply
    ///      a faithful `trader`. This is the first of the two trust layers (see EventMarketRouter).
    modifier onlyOperator() {
        if (!factory.isOperator(msg.sender)) revert NotOperator(msg.sender);
        _;
    }

    /// @inheritdoc IEventMarket
    function buyOutcome(
        bool isYes,
        uint256 usdcAmount,
        uint256 minSharesOut
    )
        external
        nonReentrant
        onlyOpen
        returns (uint256 shares)
    {
        return _buyOutcomeFor(msg.sender, isYes, usdcAmount, minSharesOut);
    }

    /// @inheritdoc IEventMarket
    function buyOutcomeFor(
        address trader,
        bool isYes,
        uint256 usdcAmount,
        uint256 minSharesOut
    )
        external
        nonReentrant
        onlyOpen
        onlyOperator
        returns (uint256 shares)
    {
        if (trader == address(0)) revert ZeroTrader();
        return _buyOutcomeFor(trader, isYes, usdcAmount, minSharesOut);
    }

    /// @dev Shared buy-path implementation. Mirrors `PerpEngine._openPositionFor`: USDC is always
    ///      pulled from `msg.sender` (the trader directly on the self-custody path, or the operator
    ///      /router on the relayed path), while shares are credited to — and the `SharesBought`
    ///      event reports — `trader`. The relayed router has already collected the USDC from
    ///      `trader` and approved this market before calling.
    function _buyOutcomeFor(
        address trader,
        bool isYes,
        uint256 usdcAmount,
        uint256 minSharesOut
    )
        internal
        returns (uint256 shares)
    {
        if (usdcAmount == 0) revert AmountZero();

        // Pull USDC from the immediate caller (trader on the direct path; router on the relayed path).
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Calculate shares to mint and credit them to the trader.
        if (isYes) {
            shares = LMSRMath.sharesForUsdc(q1, q2, _params.lmsrB, usdcAmount);
            q1 += shares;
            yesBalance[trader] += shares;
        } else {
            shares = LMSRMath.sharesForUsdc(q2, q1, _params.lmsrB, usdcAmount);
            q2 += shares;
            noBalance[trader] += shares;
        }

        if (shares < minSharesOut) revert SlippageExceeded(shares, minSharesOut);

        emit SharesBought(trader, isYes, usdcAmount, shares);
    }

    /// @inheritdoc IEventMarket
    function sellOutcome(
        bool isYes,
        uint256 sharesAmount,
        uint256 minUsdcOut
    )
        external
        nonReentrant
        onlyOpen
        returns (uint256 usdcOut)
    {
        return _sellOutcomeFor(msg.sender, isYes, sharesAmount, minUsdcOut);
    }

    /// @inheritdoc IEventMarket
    function sellOutcomeFor(
        address trader,
        bool isYes,
        uint256 sharesAmount,
        uint256 minUsdcOut
    )
        external
        nonReentrant
        onlyOpen
        onlyOperator
        returns (uint256 usdcOut)
    {
        if (trader == address(0)) revert ZeroTrader();
        return _sellOutcomeFor(trader, isYes, sharesAmount, minUsdcOut);
    }

    /// @dev Shared sell-path implementation. Shares are burned from `trader`'s balance and the USDC
    ///      proceeds are sent directly to `trader` (the owner of the position) on both the direct
    ///      and relayed paths — the router never custodies sell proceeds. The `SharesSold` event
    ///      reports `trader` as the seller.
    function _sellOutcomeFor(
        address trader,
        bool isYes,
        uint256 sharesAmount,
        uint256 minUsdcOut
    )
        internal
        returns (uint256 usdcOut)
    {
        if (sharesAmount == 0) revert AmountZero();

        if (isYes) {
            if (yesBalance[trader] < sharesAmount) revert InsufficientBalance();
            usdcOut = LMSRMath.usdcForShares(q1, q2, _params.lmsrB, sharesAmount);
            q1 -= sharesAmount;
            yesBalance[trader] -= sharesAmount;
        } else {
            if (noBalance[trader] < sharesAmount) revert InsufficientBalance();
            usdcOut = LMSRMath.usdcForShares(q2, q1, _params.lmsrB, sharesAmount);
            q2 -= sharesAmount;
            noBalance[trader] -= sharesAmount;
        }

        if (usdcOut < minUsdcOut) revert SlippageExceeded(usdcOut, minUsdcOut);

        // Send proceeds to the position owner (trader), not the caller.
        usdc.safeTransfer(trader, usdcOut);

        emit SharesSold(trader, isYes, sharesAmount, usdcOut);
    }

    /// @inheritdoc IEventMarket
    function proposeResolution(Outcome proposedOutcome) external onlyOpen {
        // This acts as a wrapper around UMAAdapter's proposeAssertion to conveniently format the claim
        // The user must still have approved UMAAdapter to spend the bond.
        // We use the eventId as the metricId for the UMA metric.
        require(
            proposedOutcome == Outcome.YES || proposedOutcome == Outcome.NO || proposedOutcome == Outcome.VOID,
            "EventMarket: invalid outcome"
        );

        string memory claim = string(
            abi.encodePacked(
                "Assert that event ",
                _params.question,
                " resolved to ",
                proposedOutcome == Outcome.YES ? "YES" : proposedOutcome == Outcome.NO ? "NO" : "VOID"
            )
        );

        // The caller pays the bond directly to the adapter.
        umaAdapter.proposeAssertion(_params.eventId, uint256(proposedOutcome), bytes(claim));

        _status = Status.PENDING_RESOLUTION;
    }

    /// @inheritdoc IEventMarket
    function settleResolution() external nonReentrant {
        require(_status == Status.OPEN || _status == Status.PENDING_RESOLUTION, "EventMarket: already resolved");

        // Read the latest value from UMAAdapter
        (uint256 value,) = umaAdapter.latestValue(_params.eventId);
        require(
            value == uint256(Outcome.YES) || value == uint256(Outcome.NO) || value == uint256(Outcome.VOID),
            "EventMarket: unsupported or unresolved value"
        );

        _outcome = Outcome(value);
        _status = Status.RESOLVED;

        // Calculate AMM liability based on outcome
        uint256 liability;
        if (_outcome == Outcome.YES) {
            liability = q1;
        } else if (_outcome == Outcome.NO) {
            liability = q2;
        } else {
            // VOID
            liability = (q1 + q2) / 2; // 0.5 USDC per share
        }

        // Total USDC in the market is (up to exp/ln rounding) LMSRMath.cost(q1, q2). Profit returned
        // to the LPVault is (cost − liability); to be robust to that rounding we use the actual
        // in-market balance minus liability rather than the closed-form cost.
        uint256 actualBalance = usdc.balanceOf(address(this));
        require(actualBalance >= liability, "EventMarket: insolvency");
        uint256 toReturn = actualBalance - liability;

        // Escrow surplus = the amount `toReturn` exceeds the floor mark the vault carried in NAV
        // through resolution. Computed ROBUST-TO-ROUNDING off the floor mark itself:
        //   floorMark    = actualBalance − max(q1,q2)   (the exact figure NAV marked pre-settle)
        //   lockedSurplus = toReturn − floorMark        (== max(q1,q2) − liability when bal ≥ maxQ)
        // This is ALWAYS ≥ 0 because floorMark ≤ toReturn (liability ≤ max(q1,q2) for YES/NO/VOID),
        // so the saturating subtraction never underflows. The vault routes `lockedSurplus` into a
        // receive-only vesting bucket (no clawback, no pro-rata snap to current shareholders); only
        // the floor `toReturn − lockedSurplus == floorMark` lands in NAV at settle, matching the mark.
        uint256 maxQ = q1 > q2 ? q1 : q2;
        uint256 floorMark = actualBalance > maxQ ? actualBalance - maxQ : 0;
        uint256 lockedSurplus = toReturn > floorMark ? toReturn - floorMark : 0;

        // Send AMM remaining funds back to LPVault via factory
        usdc.safeTransfer(address(factory), toReturn);

        // Notify factory with signed outcome score and returned liquidity
        int256 outcomeScore_e18;
        if (_outcome == Outcome.YES) outcomeScore_e18 = 1e18;
        else if (_outcome == Outcome.NO) outcomeScore_e18 = -1e18;
        else outcomeScore_e18 = 0; // VOID

        factory.onMarketResolved(
            _params.subjectId, _params.eventId, _params.eventClass, outcomeScore_e18, toReturn, lockedSurplus
        );

        emit MarketResolved(_outcome);
    }

    /// @inheritdoc IEventMarket
    function redeemWinnings() external nonReentrant onlyResolved returns (uint256 payout) {
        uint256 yesShares = yesBalance[msg.sender];
        uint256 noShares = noBalance[msg.sender];

        yesBalance[msg.sender] = 0;
        noBalance[msg.sender] = 0;

        if (_outcome == Outcome.YES) {
            payout = yesShares;
        } else if (_outcome == Outcome.NO) {
            payout = noShares;
        } else if (_outcome == Outcome.VOID) {
            payout = (yesShares + noShares) / 2;
        }

        require(payout > 0, "EventMarket: no winnings");
        usdc.safeTransfer(msg.sender, payout);

        emit WinningsRedeemed(msg.sender, payout);
    }

    /// @inheritdoc IEventMarket
    /// @dev Returns the closed-form LMSR marginal (softmax) probability scaled to 1e18. The two
    ///      outcomes always sum to exactly 1e18: priceOf(false) is returned as 1e18 - p_yes.
    function priceOf(bool isYes) external view returns (uint256 price1e18) {
        uint256 pYes = _yesPrice();
        return isYes ? pYes : 1e18 - pYes;
    }

    /// @dev Closed-form LMSR YES probability, scaled to 1e18:
    ///        p_yes = e^(q1/b) / (e^(q1/b) + e^(q2/b))
    ///      q1 (YES shares), q2 (NO shares) and b (lmsrB) are all 1e6-scaled, so q/b is a pure ratio
    ///      that we lift to WAD (1e18) for `expWad`. To stay within `expWad`'s ~135e18 input bound for
    ///      large share counts, we subtract max(q1, q2)/b (in WAD) from both exponents; the softmax is
    ///      shift-invariant, so the probability is unchanged while the dominant exponent becomes 0.
    function _yesPrice() private view returns (uint256) {
        int256 b = int256(_params.lmsrB);
        uint256 maxQ = q1 > q2 ? q1 : q2;
        int256 shift = (int256(maxQ) * 1e18) / b;

        // Both exponents are <= 0 after the shift, so expWad cannot overflow; each e term is in (0, 1e18].
        uint256 eYes = uint256(FixedPointMathLib.expWad((int256(q1) * 1e18) / b - shift));
        uint256 eNo = uint256(FixedPointMathLib.expWad((int256(q2) * 1e18) / b - shift));

        // The dominant side contributes expWad(0) = 1e18, so the denominator is always >= 1e18 (no div-by-zero).
        return (eYes * 1e18) / (eYes + eNo);
    }

    function totalYesShares() external view returns (uint256) {
        return q1;
    }

    function totalNoShares() external view returns (uint256) {
        return q2;
    }

    function status() external view returns (Status) {
        return _status;
    }

    function outcome() external view returns (Outcome) {
        return _outcome;
    }

    /// @inheritdoc IEventMarket
    /// @dev Current value the LPVault marks for this live market, in USDC (1e6). This is the pure
    ///      LMSR worst-case-liability FLOOR `balance − max(q1, q2)`, held UNCHANGED from funding
    ///      straight through resolution — it deliberately does NOT read UMA. Because `max(q1, q2)`
    ///      dominates every realisable per-outcome liability (YES→q1, NO→q2, VOID→(q1+q2)/2 ≤
    ///      max(q1,q2)), the mark is a strict lower bound on `settleResolution`'s `actualBalance −
    ///      liability` in every state. Not reading UMA is the whole point of the fix: there is no
    ///      floor→exact snap at the (permissionless, front-runnable) resolution instant, so a
    ///      depositor cannot sandwich that instant for a windfall. The surplus above the floor
    ///      (`max(q1,q2) − liability`) is escrowed into the vault's receive-only vesting bucket at
    ///      settle time (see `LPVault.settleEventMarket`), never snapped into NAV. Returns 0 once
    ///      RESOLVED (the vault has already been settled / the market is being removed the same tx).
    ///      Uses saturating subtraction so the result is always ≥ 0.
    function currentRecoverable() external view returns (uint256) {
        if (_status == Status.RESOLVED) return 0; // already settled/removed same-tx
        uint256 bal = usdc.balanceOf(address(this));
        uint256 maxQ = q1 > q2 ? q1 : q2;
        return bal > maxQ ? bal - maxQ : 0; // pure LMSR floor, held through resolution
    }

    function params() external view returns (MarketParams memory) {
        return _params;
    }
}
