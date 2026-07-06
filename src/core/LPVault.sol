// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {VaultStorage} from "../libraries/StorageLib.sol";
import {IEventMarket} from "../events/IEventMarket.sol";
import {IInsuranceFund} from "./IInsuranceFund.sol";
import {ILPVault} from "./ILPVault.sol";

/// @title LPVault — single global ERC-4626 USDC counterparty vault.
/// @notice Counterparty to every position across every Person Stock. Share token `pmUSDC`.
///         Locked collateral, insurance fund, and accrued fees are tracked alongside the free
///         LP capital so a depositor can never mint shares against funds they can't redeem.
///
/// @dev    Share-price denominator: this contract overrides `totalAssets()` to return
///         `freeAssets()` instead of `usdc.balanceOf(this)`. The same on-chain USDC backs four
///         distinct buckets (free LP capital, locked position collateral, insurance fund,
///         treasury fees) — only the first one backs LP shares. The override is the *only*
///         deviation from canonical OpenZeppelin ERC-4626 semantics. All `preview*` and `max*`
///         helpers fall through to the same denominator and behave standard-compliantly.
///
/// @dev    Inflation-attack defense: `_decimalsOffset() = 6` matches USDC's decimals and adds
///         the OZ virtual-shares mitigation. Deployment runbook also calls for governance to seed
///         a non-trivial first deposit before opening trading. Donation attacks (direct USDC
///         transfer) inflate `freeAssets`; existing LPs absorb the donation pro rata. No atomic
///         frontrun extraction is possible because share-price math uses the explicit
///         bookkeeper-difference, not `balanceOf`.
contract LPVault is Initializable, UUPSUpgradeable, ERC4626Upgradeable, ReentrancyGuard, ILPVault {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    uint32 public constant MIN_TIMELOCK_DELAY = 1 hours;
    uint32 public constant MAX_TIMELOCK_DELAY = 30 days;
    uint8 internal constant DECIMALS_OFFSET = 6;

    /// @dev Hard cap on the number of simultaneously-live event markets the vault will mark in the
    ///      `eventRecoverable()` loop. Bounds the O(n) NAV mark to a provably small, gas-safe n.
    ///      Markets are governance-created (one per EventMarketFactory.createMarket), so this is a
    ///      liberal ceiling; `fundEventMarket` reverts `TooManyLiveMarkets` past it.
    uint256 public constant MAX_LIVE_EVENT_MARKETS = 64;

    /// @dev Cumulative ceiling on `seedInsurance`. 10× the spec's $1M initial seed (§3 line 159)
    ///      gives generous headroom for the floor-mechanic top-up (§3 line 162) without making
    ///      this a daily lever. Lifting the cap requires a UUPS upgrade — high friction by design.
    uint256 public constant MAX_INSURANCE_SEED = 10_000_000 * 1e6;

    uint16 internal constant BPS_DENOM = 10_000;

    /// @dev Tier-1 insurance cap + floor (spec §3 lines 157–163).
    ///      Cap default 10%, bounds [1%, 50%]. Floor default 5%, bounds [0, 10%]. The upper bound
    ///      on the floor and the lower bound on the cap together preserve the invariant
    ///      `floor < cap` after any single setter call against the defaults.
    uint16 internal constant DEFAULT_INSURANCE_CAP_BPS = 1_000;
    uint16 internal constant MIN_INSURANCE_CAP_BPS = 100;
    uint16 internal constant MAX_INSURANCE_CAP_BPS = 5_000;
    uint16 internal constant DEFAULT_INSURANCE_FLOOR_BPS = 500;
    uint16 internal constant MAX_INSURANCE_FLOOR_BPS = 1_000;

    /// @dev Linear vesting window `T` for the receive-only event-surplus bucket (event-NAV v2
    ///      Design 2). Settle-time floor→exact surplus drips into `freeAssets` over this window so a
    ///      late depositor cannot skim the settle-time recovery. Default 7 days; governance may set
    ///      `T` anywhere in [1 day, 30 days] via `setEventSurplusVestWindow`. A stored 0 means the
    ///      default is in force (fresh proxies never had a window set).
    uint32 internal constant DEFAULT_EVENT_SURPLUS_VEST_WINDOW = 7 days;
    uint32 internal constant MIN_EVENT_SURPLUS_VEST_WINDOW = 1 days;
    uint32 internal constant MAX_EVENT_SURPLUS_VEST_WINDOW = 30 days;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the vault.
    /// @param  usdc_ Underlying ERC-20. On Base mainnet this is the canonical USDC contract.
    /// @param  governance_ Multi-sig that proposes operator + governance transfers (timelocked).
    /// @param  operator_ Multi-sig that toggles deposit / withdrawal pause flags (no timelock).
    /// @param  timelockDelay_ Seconds. Must lie in [MIN_TIMELOCK_DELAY, MAX_TIMELOCK_DELAY].
    /// @param  name_ ERC-20 share name (e.g. "People Markets LP USDC").
    /// @param  symbol_ ERC-20 share symbol (e.g. "pmUSDC").
    function initialize(
        IERC20 usdc_,
        address governance_,
        address operator_,
        uint32 timelockDelay_,
        string memory name_,
        string memory symbol_
    )
        external
        initializer
    {
        if (address(usdc_) == address(0)) revert InvalidConfig();
        if (governance_ == address(0) || operator_ == address(0)) revert InvalidConfig();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) revert InvalidConfig();

        __ERC20_init(name_, symbol_);
        __ERC4626_init(usdc_);

        VaultStorage.Layout storage s = VaultStorage.load();
        s.governance = governance_;
        s.operator = operator_;
        s.timelockDelay = timelockDelay_;
        // Tier-1 insurance cap + floor — spec §3 lines 157–163.
        s.insuranceCapBps = DEFAULT_INSURANCE_CAP_BPS;
        s.insuranceFloorBps = DEFAULT_INSURANCE_FLOOR_BPS;
        // perpEngine is intentionally unset at init — set later via the timelocked proposal flow.
        // This breaks the circular deploy dependency: PerpEngine needs the vault address at
        // construction; the vault sets the engine address afterwards.
    }

    // ------------------------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------------------------

    modifier onlyGovernance() {
        if (msg.sender != VaultStorage.load().governance) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != VaultStorage.load().operator) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyPerpEngine() {
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.perpEngine == address(0)) revert PerpEngineNotSet();
        if (msg.sender != s.perpEngine) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyLiquidationEngine() {
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.liquidationEngine == address(0)) revert LiquidationEngineNotSet();
        if (msg.sender != s.liquidationEngine) revert OnlyLiquidationEngine(msg.sender);
        _;
    }

    /// @dev Wave 8. Gates `fundEventMarket` and `settleEventMarket` to the configured EventMarketFactory.
    modifier onlyEventMarketFactory() {
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.eventMarketFactory == address(0)) revert EventMarketFactoryNotSet();
        if (msg.sender != s.eventMarketFactory) revert OnlyEventMarketFactory(msg.sender);
        _;
    }

    // ------------------------------------------------------------------------------------------
    // ERC-4626 overrides
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Share-price NAV denominator = strictly-liquid `freeAssets()` PLUS the current
    ///      recoverable value of every live event market (`eventRecoverable()`). Locked collateral,
    ///      insurance fund, treasury fees, and the not-yet-vested event surplus sit in the same USDC
    ///      contract balance but do not back immediately-redeemable shares, so they are excluded from
    ///      `freeAssets()`. Event-market seed that has left the vault is marked at the pure LMSR
    ///      FLOOR (`market.balance − max(q1,q2)`), held UNCHANGED from funding through resolution —
    ///      the mark does NOT read UMA, so there is no floor→exact snap at the (front-runnable)
    ///      resolution instant for a depositor to sandwich. The floor→exact surplus is realised only
    ///      at settle, into the receive-only vesting bucket, and drips into NAV linearly over the
    ///      vest window. Because `eventRecoverable() ≥ 0` and the vesting exclusion only lowers
    ///      `freeAssets`, both the redemption and deposit residuals are small and un-timeable; the
    ///      share price stays fair while withdrawals remain liquidity-capped (see `maxWithdraw`).
    function totalAssets() public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return freeAssets() + eventRecoverable();
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function maxDeposit(address) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (VaultStorage.load().depositsPaused) return 0;
        return type(uint256).max;
    }

    function maxMint(address) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (VaultStorage.load().depositsPaused) return 0;
        return type(uint256).max;
    }

    function maxWithdraw(address ownerAddr)
        public
        view
        virtual
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        if (VaultStorage.load().withdrawalsPaused) return 0;
        // Cap at freeAssets — locked collateral / fees / insurance are not redeemable.
        return Math.min(super.maxWithdraw(ownerAddr), freeAssets());
    }

    function maxRedeem(address ownerAddr) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (VaultStorage.load().withdrawalsPaused) return 0;
        uint256 byOwner = super.maxRedeem(ownerAddr);
        // Convert the freeAssets cap into shares using floor rounding so we don't grant more
        // share-redemptions than freeAssets can satisfy.
        uint256 freeAssetsAsShares = _convertToShares(freeAssets(), Math.Rounding.Floor);
        return Math.min(byOwner, freeAssetsAsShares);
    }

    /// @dev Pause state is enforced upstream: `maxWithdraw` and `maxRedeem` return 0 when
    ///      `withdrawalsPaused`, so the inherited `withdraw` / `redeem` revert with the standard
    ///      `ERC4626ExceededMaxWithdraw` / `ERC4626ExceededMaxRedeem` before reaching here. The
    ///      `freeAssets` cap is the load-bearing check: it prevents withdrawals from dipping into
    ///      locked collateral, fees, or insurance funds even on an unanticipated `max*` regression.
    function _withdraw(
        address caller,
        address receiver,
        address ownerAddr,
        uint256 assets,
        uint256 shares
    )
        internal
        virtual
        override
    {
        uint256 free = freeAssets();
        if (assets > free) revert InsufficientFreeAssets(assets, free);
        super._withdraw(caller, receiver, ownerAddr, assets, shares);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        // Pause-state is enforced via `maxDeposit == 0`. AmountZero stays here as a positive
        // guard against share-mint-of-zero, which would otherwise be a silent no-op for the LP.
        if (assets == 0) revert AmountZero();
        super._deposit(caller, receiver, assets, shares);
    }

    // ------------------------------------------------------------------------------------------
    // Slippage-protected wrappers
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILPVault
    function depositWithMinShares(
        uint256 assets,
        address receiver,
        uint256 minShares
    )
        external
        nonReentrant
        returns (uint256 shares)
    {
        shares = deposit(assets, receiver);
        if (shares < minShares) revert MinSharesNotMet(minShares, shares);
    }

    /// @inheritdoc ILPVault
    function redeemWithMinAssets(
        uint256 shares,
        address receiver,
        address owner_,
        uint256 minAssets
    )
        external
        nonReentrant
        returns (uint256 assets)
    {
        assets = redeem(shares, receiver, owner_);
        // Slippage floor: revert if the realized assets fall below the user's specified minimum.
        // The earlier `withdrawWithMaxAssets` checked the wrong direction (`assets > maxAssets`),
        // which only protected against a windfall — leaving redeemers fully exposed to share-price
        // declines. See IMPLEMENTATION_AUDIT.md v2-audit finding #4.
        if (assets < minAssets) revert MinAssetsNotMet(minAssets, assets);
    }

    // ------------------------------------------------------------------------------------------
    // Operator entrypoints (PerpEngine only)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILPVault
    function openPositionFlow(
        address trader,
        uint256 collateralToLock,
        uint256 fee,
        uint256 lpRebate,
        uint256 insuranceShare
    )
        external
        nonReentrant
        onlyPerpEngine
    {
        if (collateralToLock == 0) revert AmountZero();
        if (lpRebate + insuranceShare > fee) revert FeeSplitInvalid(fee, lpRebate, insuranceShare);

        VaultStorage.Layout storage s = VaultStorage.load();

        // Single transferFrom for collateral + fee; cheaper than two pulls.
        // slither-disable-next-line arbitrary-send-erc20 -- onlyPerpEngine; `trader` is the position owner who approved the vault.
        IERC20(asset()).safeTransferFrom(trader, address(this), collateralToLock + fee);

        s.positionCollateral += collateralToLock;
        // Tier-1 insurance cap: book up to the cap; redirect any excess to the share pool by
        // leaving it unbooked (freeAssets() absorbs the difference automatically).
        _accrueInsuranceCapped(s, insuranceShare);
        // Residual = fee − lpRebate − insuranceShare. Subtraction-based form ensures rounding
        // dust never disappears: the sum of (lpRebate stays in freeAssets, insuranceShare,
        // residual to accruedFees) exactly equals `fee`.
        s.accruedFees += fee - lpRebate - insuranceShare;

        emit PositionOpenedOnVault(trader, collateralToLock, fee, lpRebate, insuranceShare);
        emit CollateralLocked(trader, collateralToLock);
    }

    /// @inheritdoc ILPVault
    function settlePosition(
        address trader,
        uint256 collateralToRelease,
        int256 pnl,
        uint256 fee,
        uint256 lpRebate,
        uint256 insuranceShare
    )
        external
        nonReentrant
        onlyPerpEngine
    {
        if (collateralToRelease == 0) revert AmountZero();
        if (lpRebate + insuranceShare > fee) revert FeeSplitInvalid(fee, lpRebate, insuranceShare);

        VaultStorage.Layout storage s = VaultStorage.load();
        if (collateralToRelease > s.positionCollateral) {
            revert InsufficientPositionCollateral(collateralToRelease, s.positionCollateral);
        }

        // returnedSigned = collateralToRelease + pnl − fee. Reverts if negative — v0 rejects
        // voluntary close into negative equity; LiquidationEngine handles those (week 14+).
        int256 returnedSigned = int256(collateralToRelease) + pnl - int256(fee);
        if (returnedSigned < 0) revert UnderwaterClose(collateralToRelease, pnl, fee);
        uint256 returned = uint256(returnedSigned);

        // v2-audit Fix #2: solvency check on profitable closes. The PnL portion of `returned`
        // (above what `collateralToRelease` covers) must be backed by `freeAssets`, otherwise the
        // underlying `safeTransfer` would silently drain the USDC backing of the insurance and
        // accruedFees buckets — leaving those storage counters phantom (storage > actual USDC).
        // We check this BEFORE decrementing positionCollateral so freeAssets() is still computed
        // against pre-settle state.
        if (pnl > 0) {
            uint256 pnlNet = uint256(pnl) > fee ? uint256(pnl) - fee : 0;
            if (pnlNet > freeAssets()) revert InsufficientFreeAssets(pnlNet, freeAssets());
        }

        s.positionCollateral -= collateralToRelease;
        // Tier-1 insurance cap (same as open flow): excess above cap stays in the share pool.
        _accrueInsuranceCapped(s, insuranceShare);
        s.accruedFees += fee - lpRebate - insuranceShare;

        if (returned > 0) {
            IERC20(asset()).safeTransfer(trader, returned);
        }

        // Tier-1 insurance floor: emit an informational event if the bookkeeper is below the
        // configured floor after the settle. The treasury responds off-chain via `seedInsurance`.
        _emitFloorBreachIfBelow(s);

        emit PositionSettledOnVault(trader, collateralToRelease, pnl, fee, lpRebate, insuranceShare, returned);
        emit CollateralReleased(trader, collateralToRelease);
    }

    /// @dev Tier-1 insurance cap helper. Books at most `cap − currentBalance` into the bookkeeper;
    ///      the unbooked excess remains in `usdc.balanceOf(this)` un-allocated, so `freeAssets()`
    ///      (= balance − positionCollateral − insuranceFundBalance − accruedFees) absorbs it as
    ///      a per-share boost. No bookkeeper-decrement is performed when the cap is already over —
    ///      legacy over-cap balances stay where they are; only NEW accrual is redirected.
    ///
    /// @dev Post-migration (`s.insuranceFund != address(0)`), the bookkeeper view is the live
    ///      `IInsuranceFund.balance()`; the booked amount is `accrue()`'d through to the fund,
    ///      which `transferFrom`s the USDC out of this vault. The local `insuranceFundBalance`
    ///      field stays at zero post-migration (set by `migrateInsuranceFund`), so the freeAssets
    ///      identity continues to hold (the USDC has physically left the vault, and the bookkeeper
    ///      is zero — both deltas match).
    function _accrueInsuranceCapped(VaultStorage.Layout storage s, uint256 insuranceShare) internal {
        if (insuranceShare == 0) return;
        // Wave 7 audit Fix #5: cap denominator is full vault capital, NOT `freeAssets()`. The
        // `positionCollateral` bucket is real backing for real exposure — it should count toward
        // the insurance cap denominator. `accruedFees` is excluded (those USDC are earmarked for
        // treasury withdrawal, not LP yield). At high utilisation, the prior `totalAssets()`
        // denominator (= freeAssets) collapsed and let the cap effectively block insurance
        // accrual exactly when the insurance fund needs to grow the fastest.
        uint256 tvl = _capDenominatorTvl(s);
        uint256 cap = (tvl * uint256(s.insuranceCapBps)) / BPS_DENOM;
        uint256 current = _insuranceBalanceFor(s);
        if (current >= cap) {
            // Already at/above cap — none of the new accrual is booked. The full insuranceShare
            // flows to the share pool.
            emit InsuranceCapOverflow(insuranceShare, current, tvl);
            return;
        }
        uint256 room = cap - current;
        uint256 toBook = insuranceShare <= room ? insuranceShare : room;
        if (toBook < insuranceShare) {
            // Partial overflow: emit the excess.
            emit InsuranceCapOverflow(insuranceShare - room, cap, tvl);
        }
        if (s.insuranceFund != address(0)) {
            // Post-migration: route the booked portion to the standalone fund. The fund pulls the
            // USDC out of this vault via the pre-approved allowance. The legacy bookkeeper stays
            // at zero — `_insuranceBalanceFor` reads from the fund.
            IInsuranceFund(s.insuranceFund).accrue(toBook);
        } else {
            // Pre-migration: book into the local bookkeeper. USDC stays in the vault.
            s.insuranceFundBalance = current + toBook;
        }
    }

    /// @dev Tier-1 floor helper. Emits when the live insurance balance is strictly below the
    ///      configured floor; silent otherwise. No-op if either the floor is 0 or the bookkeeper
    ///      is empty. Reads from the InsuranceFund post-migration via `_insuranceBalanceFor`.
    function _emitFloorBreachIfBelow(VaultStorage.Layout storage s) internal {
        uint16 floorBps = s.insuranceFloorBps;
        if (floorBps == 0) return;
        // Wave 7 audit Fix #5: floor denominator mirrors the cap denominator.
        uint256 tvl = _capDenominatorTvl(s);
        uint256 floor = (tvl * uint256(floorBps)) / BPS_DENOM;
        uint256 current = _insuranceBalanceFor(s);
        if (current < floor) {
            emit InsuranceFloorBreached(current, floor, tvl);
        }
    }

    /// @dev Wave 7 audit Fix #5 cap/floor denominator. Full vault capital minus the residual
    ///      treasury bucket. Includes `eventFundedSeed` since that capital is deployed but still
    ///      belongs to the protocol.
    function _capDenominatorTvl(VaultStorage.Layout storage s) internal view returns (uint256) {
        uint256 totalBalance = IERC20(asset()).balanceOf(address(this)) + s.eventFundedSeed;
        return totalBalance > s.accruedFees ? totalBalance - s.accruedFees : 0;
    }

    /// @dev Returns the live insurance balance — pre-migration this is the in-vault bookkeeper,
    ///      post-migration it reads `IInsuranceFund.balance()` from the standalone fund.
    function _insuranceBalanceFor(VaultStorage.Layout storage s) internal view returns (uint256) {
        address fund = s.insuranceFund;
        if (fund == address(0)) return s.insuranceFundBalance;
        return IInsuranceFund(fund).balance();
    }

    /// @inheritdoc ILPVault
    /// @dev Wave 5B. The 3-way settle path for the LiquidationEngine. Decrements
    ///      `positionCollateral` by `collateralReleased`, books `signedPnl` to the LP side,
    ///      and transfers `traderPayout` + `liquidatorBounty` out of the vault.
    ///
    ///      Invariant enforced: `traderPayout + liquidatorBounty == collateralReleased +
    ///      signedPnl`. Anything else implies a LiquidationEngine accounting bug — we revert
    ///      `LiquidationPayoutMismatch` so the broken state never lands on-chain.
    ///
    ///      Solvency: when the slice is in deficit (`signedPnl < 0` and the deficit exceeds the
    ///      released collateral), the vault's `freeAssets` covers the deficit. The
    ///      LiquidationEngine pre-funds via `drawFromInsuranceForLiquidation` for any shortfall
    ///      before calling here. We rely on the inherited `freeAssets` arithmetic in
    ///      `_withdraw` to ensure that locked collateral / fees / insurance buckets are never
    ///      drained by the trader/bounty payouts — instead this function's `freeAssets()` check
    ///      after the state mutations catches any solvency violation.
    function settleLiquidation(
        address trader,
        address liquidator,
        uint256 collateralReleased,
        uint256 traderPayout,
        uint256 liquidatorBounty,
        int256 signedPnl
    )
        external
        nonReentrant
        onlyPerpEngine
    {
        if (collateralReleased == 0) revert AmountZero();
        if (trader == liquidator) revert LiquidatorIsTrader(trader);

        VaultStorage.Layout storage s = VaultStorage.load();
        if (collateralReleased > s.positionCollateral) {
            revert InsufficientPositionCollateral(collateralReleased, s.positionCollateral);
        }

        // ---- Payout-conservation invariant. ----
        int256 expectedTotal = int256(collateralReleased) + signedPnl;
        int256 actualTotal = int256(traderPayout) + int256(liquidatorBounty);
        if (expectedTotal != actualTotal) {
            revert LiquidationPayoutMismatch(expectedTotal, actualTotal);
        }

        // Solvency check: if total payout exceeds released collateral, the difference must be
        // backed by `freeAssets`. This protects locked collateral / insurance / accruedFees from
        // being silently drained.
        //
        // Wave 7 audit Fix #1: the check MUST run BEFORE we decrement `positionCollateral`. If we
        // decremented first, the just-freed collateral would inflate `freeAssets()` and let the
        // deficit pass even when the vault genuinely cannot cover it — leaving
        // `insuranceFundBalance` and `accruedFees` as phantom claims. Mirrors the v2-audit Fix #2
        // ordering already applied to `settlePosition`.
        uint256 totalPayout = traderPayout + liquidatorBounty;
        if (totalPayout > collateralReleased) {
            uint256 deficit = totalPayout - collateralReleased;
            uint256 free = freeAssets();
            if (deficit > free) revert InsufficientFreeAssetsForLiquidation(deficit, free);
        }

        // ---- State mutation BEFORE external calls (CEI). ----
        s.positionCollateral -= collateralReleased;

        if (traderPayout > 0) IERC20(asset()).safeTransfer(trader, traderPayout);
        if (liquidatorBounty > 0) IERC20(asset()).safeTransfer(liquidator, liquidatorBounty);

        // Floor breach check on the way out.
        _emitFloorBreachIfBelow(s);

        emit LiquidationSettledOnVault(
            trader, liquidator, collateralReleased, traderPayout, liquidatorBounty, signedPnl
        );
        emit CollateralReleased(trader, collateralReleased);
    }

    /// @inheritdoc ILPVault
    /// @dev Wave 5B. Draws `amount` USDC from the standalone InsuranceFund into this vault. The
    ///      LiquidationEngine calls this BEFORE `liquidateClose` so the vault has the USDC to
    ///      cover the trader payout when the slice is in deficit.
    ///
    ///      `recipient` of the draw is `address(this)` — the InsuranceFund transfers USDC to the
    ///      vault. The vault tracks the inbound flow via `_emitFloorBreachIfBelow` for the
    ///      informational floor event, but does NOT increment `positionCollateral` /
    ///      `insuranceFundBalance` / `accruedFees` (the InsuranceFund's `drawShortfall` already
    ///      decremented its own `trackedBalance`).
    function drawFromInsuranceForLiquidation(uint256 amount) external nonReentrant onlyLiquidationEngine {
        if (amount == 0) revert AmountZero();
        VaultStorage.Layout storage s = VaultStorage.load();
        address fund = s.insuranceFund;
        if (fund == address(0)) revert InsuranceFundNotSet();
        // Pull via the InsuranceFund's existing `drawShortfall` — gated `onlyLPVault` already, so
        // this is the canonical path. Recipient is the vault itself: the USDC lands here and
        // boosts `freeAssets` for the subsequent `settleLiquidation` payout.
        IInsuranceFund(fund).drawShortfall(address(this), amount);
        emit InsuranceDrawnForLiquidation(amount, IInsuranceFund(fund).balance());
    }

    /// @inheritdoc ILPVault
    function lockCollateral(address from, uint256 amount) external nonReentrant onlyPerpEngine {
        if (amount == 0) revert AmountZero();
        // slither-disable-next-line arbitrary-send-erc20 -- onlyPerpEngine; `from` is the position owner who approved the vault.
        IERC20(asset()).safeTransferFrom(from, address(this), amount);
        VaultStorage.load().positionCollateral += amount;
        emit CollateralLocked(from, amount);
    }

    /// @inheritdoc ILPVault
    function releaseCollateral(address to, uint256 amount) external nonReentrant onlyPerpEngine {
        if (amount == 0) revert AmountZero();
        VaultStorage.Layout storage s = VaultStorage.load();
        if (amount > s.positionCollateral) revert InsufficientPositionCollateral(amount, s.positionCollateral);
        s.positionCollateral -= amount;
        IERC20(asset()).safeTransfer(to, amount);
        emit CollateralReleased(to, amount);
    }

    // ------------------------------------------------------------------------------------------
    // Event Market Seeding (Wave 8)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILPVault
    /// @dev Solvency is checked against strictly-liquid `freeAssets()` (the seed can only leave the
    ///      vault if there is liquid USDC to cover it). The funded `market` is registered in the live
    ///      set so `totalAssets()` immediately begins marking it to its recoverable value — closing
    ///      the deposit arb (a depositor after this point sees NAV already crediting the market).
    function fundEventMarket(address market, uint256 amount) external nonReentrant onlyEventMarketFactory {
        if (amount == 0) revert AmountZero();
        // Solvency vs LIQUID freeAssets (the seed can only be paid out of in-vault USDC).
        uint256 free = freeAssets();
        if (amount > free) revert InsufficientFreeAssets(amount, free);

        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.liveEventMarketIndex[market] != 0) revert MarketAlreadyLive(market);
        if (s.liveEventMarkets.length >= MAX_LIVE_EVENT_MARKETS) revert TooManyLiveMarkets();

        s.eventFundedSeed += amount;
        s.liveEventMarkets.push(market);
        s.liveEventMarketIndex[market] = s.liveEventMarkets.length; // 1-based

        IERC20(asset()).safeTransfer(msg.sender, amount);
        emit EventMarketFunded(market, amount);
    }

    /// @inheritdoc ILPVault
    /// @dev Removes `market` from the live set (O(1) swap-pop) and pulls `returnedAmount` back. NAV
    ///      is continuous across settle to the wei: the market carried the FLOOR mark
    ///      (`returnedAmount − lockedSurplus`) in `eventRecoverable()` through resolution. Here the
    ///      recoverable mark drops to 0 (market leaves the set) while the balance rises by
    ///      `returnedAmount`; the `lockedSurplus` above the floor is added to the receive-only
    ///      vesting bucket (and thus removed from `freeAssets` until it vests). Net Δ(totalAssets):
    ///        + returnedAmount (into _liquidRaw)
    ///        − lockedSurplus  (into unvested, excluded from freeAssets)
    ///        − floorMark      (recoverable mark leaves)
    ///      = returnedAmount − lockedSurplus − (returnedAmount − lockedSurplus) = 0. No jump, so no
    ///      depositor/redeemer can straddle the settle instant for a windfall; the surplus drips in.
    function settleEventMarket(
        address market,
        uint256 originalSeed,
        uint256 returnedAmount,
        uint256 lockedSurplus
    )
        external
        nonReentrant
        onlyEventMarketFactory
    {
        if (originalSeed == 0) revert AmountZero();
        VaultStorage.Layout storage s = VaultStorage.load();

        uint256 idx = s.liveEventMarketIndex[market];
        if (idx == 0) revert MarketNotLive(market);

        // This is safe because eventFundedSeed only grows by exact funded amounts.
        s.eventFundedSeed -= originalSeed;

        // O(1) swap-pop removal from the live registry.
        uint256 last = s.liveEventMarkets.length;
        if (idx != last) {
            address moved = s.liveEventMarkets[last - 1];
            s.liveEventMarkets[idx - 1] = moved;
            s.liveEventMarketIndex[moved] = idx;
        }
        s.liveEventMarkets.pop();
        delete s.liveEventMarketIndex[market];

        if (returnedAmount > 0) {
            IERC20(asset()).safeTransferFrom(msg.sender, address(this), returnedAmount);
        }

        // Crank the receive-only vesting bucket with the floor→exact surplus.
        _accrueEventSurplus(s, lockedSurplus);

        int256 pnl = int256(returnedAmount) - int256(originalSeed);
        emit EventMarketSettled(market, originalSeed, returnedAmount, pnl);
    }

    /// @dev Synthetix-style crank of the receive-only event-surplus vesting bucket. FIRST realises
    ///      the amount vested since the last crank (moving it into `_liquidRaw`/`freeAssets`
    ///      implicitly — the USDC is already on-balance), THEN adds the new `lockedSurplus` to the
    ///      principal and resets the linear drip rate `r = P / T` and clock `t0 = now`. The bucket is
    ///      receive-only: `P` only grows here and drips down via `_unvestedEventSurplus`; there is no
    ///      clawback, so it can never go negative and an empty bucket is safe (`add == 0` no-ops the
    ///      accounting but still re-anchors the clock, which is harmless).
    function _accrueEventSurplus(VaultStorage.Layout storage s, uint256 add) internal {
        uint32 t = s.eventSurplusVestWindow == 0 ? DEFAULT_EVENT_SURPLUS_VEST_WINDOW : s.eventSurplusVestWindow;

        // Realise vested-so-far: collapse P to the still-unvested remainder at `now`.
        uint256 p = s.eventSurplusPrincipal;
        uint256 t0 = s.eventSurplusLastAccrual;
        if (p != 0 && block.timestamp > t0) {
            uint256 vested = s.eventSurplusRatePerSec * (block.timestamp - t0);
            p = p > vested ? p - vested : 0;
        }

        p += add;
        s.eventSurplusPrincipal = p;
        s.eventSurplusRatePerSec = p / t; // floor division; the sub-`T`-wei dust rolls forward harmlessly
        s.eventSurplusLastAccrual = uint64(block.timestamp);
        emit EventSurplusAccrued(add, p, s.eventSurplusRatePerSec, t);
    }

    // ------------------------------------------------------------------------------------------
    // Insurance fund seeding (Fix #6) — governance only, no timelock, capped cumulatively
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILPVault
    function seedInsurance(uint256 amount) external nonReentrant onlyGovernance {
        if (amount == 0) revert AmountZero();
        VaultStorage.Layout storage s = VaultStorage.load();
        // Post-migration the in-vault bookkeeper is sealed at zero; treasury must seed the
        // standalone fund directly via `IInsuranceFund.deposit()`. Reverting here makes the
        // migration-day handoff explicit for operators.
        if (s.insuranceFund != address(0)) revert InsuranceFundAlreadyMigrated();
        uint256 newCumulative = s.insuranceSeedDeposited + amount;
        if (newCumulative > MAX_INSURANCE_SEED) {
            revert InsuranceSeedCapExceeded(newCumulative, MAX_INSURANCE_SEED);
        }
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        s.insuranceFundBalance += amount;
        s.insuranceSeedDeposited = newCumulative;
        emit InsuranceSeeded(msg.sender, amount, newCumulative);
    }

    // ------------------------------------------------------------------------------------------
    // Wave 6A — InsuranceFund migration (spec §3 line 162)
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILPVault
    /// @dev    One-shot. Transfers the legacy `insuranceFundBalance` USDC into `newFund`, zeroes
    ///         the bookkeeper, and stores the fund address. After this call:
    ///           - Insurance accruals are pushed to the fund via `IInsuranceFund.accrue(amount)`.
    ///           - `insuranceFundBalance()` view reads `IInsuranceFund.balance()`.
    ///           - `seedInsurance` reverts; use `IInsuranceFund.deposit()`.
    ///
    /// @dev    Governance MUST call `approveInsuranceFund()` separately to grant the fund the
    ///         allowance it needs for `accrue`. The migration call itself does not approve, to
    ///         keep the storage write and the token approval visible as two distinct on-chain
    ///         actions in the deployment runbook.
    function migrateInsuranceFund(address newFund) external onlyGovernance {
        if (newFund == address(0)) revert InvalidConfig();
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.insuranceFund != address(0)) revert InsuranceFundAlreadySet();
        uint256 toMove = s.insuranceFundBalance;
        // Seal the legacy bookkeeper BEFORE the external call. The InsuranceFund pulls via
        // `safeTransferFrom(this, address(fund), amount)` if we routed through `accrue`, but here
        // we hand-off the legacy reserve through a direct `safeTransfer` and `deposit` is not
        // appropriate (the fund's `accrue` is gated to `onlyLPVault`, and `deposit` would need a
        // pre-approval). We use `safeTransfer` + a manual `trackedBalance` bump via `accrue`.
        s.insuranceFundBalance = 0;
        s.insuranceFund = newFund;
        if (toMove > 0) {
            // Grant a one-shot allowance for the InsuranceFund to pull `toMove` USDC via its
            // `accrue` entrypoint. This is the legacy reserve handoff; the permanent unlimited
            // allowance is set later via `approveInsuranceFund`. Two-call pattern keeps the
            // migration auditable: the on-chain trace shows (a) the legacy USDC moving via
            // `accrue`, and (b) the permanent allowance grant as a separate action.
            IERC20(asset()).forceApprove(newFund, toMove);
            IInsuranceFund(newFund).accrue(toMove);
            // forceApprove with `toMove` was consumed by `accrue`; clean any dust to zero before
            // the explicit `approveInsuranceFund` call sets the long-term unlimited allowance.
            IERC20(asset()).forceApprove(newFund, 0);
        }
        emit InsuranceFundMigrated(toMove, newFund);
    }

    /// @inheritdoc ILPVault
    /// @dev    Governance-only, no timelock. Grants the configured `InsuranceFund` an unlimited
    ///         USDC allowance so future `_accrueInsuranceCapped` calls can flow without a fresh
    ///         approval. The InsuranceFund's `accrue` entrypoint is `onlyLPVault` gated, so
    ///         unlimited approval cannot be drained by anyone else.
    function approveInsuranceFund() external onlyGovernance {
        VaultStorage.Layout storage s = VaultStorage.load();
        address fund = s.insuranceFund;
        if (fund == address(0)) revert InsuranceFundNotSet();
        IERC20(asset()).forceApprove(fund, type(uint256).max);
        emit InsuranceFundApproved(fund);
    }

    // ------------------------------------------------------------------------------------------
    // Treasury fee withdrawal (Fix #5) — governance, timelocked
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILPVault
    /// @dev Spec §3 fee structure leaves a 10% residual unallocated; we route it to `accruedFees`
    ///      and expose it via this timelocked withdrawal flow. Single in-flight per the
    ///      `pendingPerpEngine` pattern. Pause flags do NOT gate this — treasury operations are
    ///      independent of LP deposit/withdrawal halts.
    function proposeFeeWithdrawal(address recipient, uint256 amount) external onlyGovernance {
        if (recipient == address(0)) revert InvalidConfig();
        if (amount == 0) revert AmountZero();
        VaultStorage.Layout storage s = VaultStorage.load();
        if (amount > s.accruedFees) revert InsufficientAccruedFees(amount, s.accruedFees);
        if (s.pendingFeeWithdrawal.exists) revert PendingProposalExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingFeeWithdrawal = VaultStorage.PendingFeeWithdrawal({
            recipient: recipient, amount: amount, activatesAt: activatesAt, exists: true
        });
        emit FeeWithdrawalProposed(recipient, amount, activatesAt);
    }

    /// @inheritdoc ILPVault
    function activateFeeWithdrawal() external nonReentrant {
        VaultStorage.Layout storage s = VaultStorage.load();
        VaultStorage.PendingFeeWithdrawal memory p = s.pendingFeeWithdrawal;
        if (!p.exists) revert NoPendingProposal();
        if (block.timestamp < p.activatesAt) revert TimelockNotElapsed(p.activatesAt);
        // Defensive re-check: between propose and activate the residual could have moved (it
        // only ever grows in v0, but a future contract version could decrement it).
        if (p.amount > s.accruedFees) revert InsufficientAccruedFees(p.amount, s.accruedFees);
        s.accruedFees -= p.amount;
        delete s.pendingFeeWithdrawal;
        IERC20(asset()).safeTransfer(p.recipient, p.amount);
        emit FeeWithdrawalActivated(p.recipient, p.amount);
    }

    /// @inheritdoc ILPVault
    function cancelFeeWithdrawal() external onlyGovernance {
        VaultStorage.Layout storage s = VaultStorage.load();
        VaultStorage.PendingFeeWithdrawal memory p = s.pendingFeeWithdrawal;
        if (!p.exists) revert NoPendingProposal();
        delete s.pendingFeeWithdrawal;
        emit FeeWithdrawalCancelled(p.recipient, p.amount);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: setPerpEngine (timelocked)
    // ------------------------------------------------------------------------------------------

    function proposeSetPerpEngine(address newEngine) external onlyGovernance {
        if (newEngine == address(0)) revert InvalidConfig();
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.pendingPerpEngineActivatesAt != 0) revert PendingProposalExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingPerpEngine = newEngine;
        s.pendingPerpEngineActivatesAt = activatesAt;
        emit PerpEngineProposed(newEngine, activatesAt);
    }

    function activateSetPerpEngine() external {
        VaultStorage.Layout storage s = VaultStorage.load();
        uint64 readyAt = s.pendingPerpEngineActivatesAt;
        if (readyAt == 0) revert NoPendingProposal();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldEngine = s.perpEngine;
        address newEngine = s.pendingPerpEngine;
        s.perpEngine = newEngine;
        delete s.pendingPerpEngine;
        delete s.pendingPerpEngineActivatesAt;
        emit PerpEngineActivated(oldEngine, newEngine);
    }

    function cancelSetPerpEngine() external onlyGovernance {
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.pendingPerpEngineActivatesAt == 0) revert NoPendingProposal();
        address pending = s.pendingPerpEngine;
        delete s.pendingPerpEngine;
        delete s.pendingPerpEngineActivatesAt;
        emit PerpEngineCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: setLiquidationEngine (timelocked) — Wave 5B
    // ------------------------------------------------------------------------------------------

    function proposeSetLiquidationEngine(address newEngine) external onlyGovernance {
        if (newEngine == address(0)) revert InvalidConfig();
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.pendingLiquidationEngineActivatesAt != 0) revert PendingProposalExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingLiquidationEngine = newEngine;
        s.pendingLiquidationEngineActivatesAt = activatesAt;
        emit LiquidationEngineProposed(newEngine, activatesAt);
    }

    function activateSetLiquidationEngine() external {
        VaultStorage.Layout storage s = VaultStorage.load();
        uint64 readyAt = s.pendingLiquidationEngineActivatesAt;
        if (readyAt == 0) revert NoPendingProposal();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldEngine = s.liquidationEngine;
        address newEngine = s.pendingLiquidationEngine;
        s.liquidationEngine = newEngine;
        delete s.pendingLiquidationEngine;
        delete s.pendingLiquidationEngineActivatesAt;
        emit LiquidationEngineActivated(oldEngine, newEngine);
    }

    function cancelSetLiquidationEngine() external onlyGovernance {
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.pendingLiquidationEngineActivatesAt == 0) revert NoPendingProposal();
        address pending = s.pendingLiquidationEngine;
        delete s.pendingLiquidationEngine;
        delete s.pendingLiquidationEngineActivatesAt;
        emit LiquidationEngineCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: setEventMarketFactory (timelocked) — Wave 8
    // ------------------------------------------------------------------------------------------

    function proposeSetEventMarketFactory(address newFactory) external onlyGovernance {
        if (newFactory == address(0)) revert InvalidConfig();
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.pendingEventMarketFactoryActivatesAt != 0) revert PendingProposalExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingEventMarketFactory = newFactory;
        s.pendingEventMarketFactoryActivatesAt = activatesAt;
        emit EventMarketFactoryProposed(newFactory, activatesAt);
    }

    function activateSetEventMarketFactory() external {
        VaultStorage.Layout storage s = VaultStorage.load();
        uint64 readyAt = s.pendingEventMarketFactoryActivatesAt;
        if (readyAt == 0) revert NoPendingProposal();
        if (block.timestamp < readyAt) revert TimelockNotElapsed(readyAt);
        address oldFactory = s.eventMarketFactory;
        address newFactory = s.pendingEventMarketFactory;
        s.eventMarketFactory = newFactory;
        delete s.pendingEventMarketFactory;
        delete s.pendingEventMarketFactoryActivatesAt;
        emit EventMarketFactoryActivated(oldFactory, newFactory);
    }

    function cancelSetEventMarketFactory() external onlyGovernance {
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.pendingEventMarketFactoryActivatesAt == 0) revert NoPendingProposal();
        address pending = s.pendingEventMarketFactory;
        delete s.pendingEventMarketFactory;
        delete s.pendingEventMarketFactoryActivatesAt;
        emit EventMarketFactoryCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Governance: governance transfer (timelocked)
    // ------------------------------------------------------------------------------------------

    function proposeGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidConfig();
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.pendingGovernanceActivatesAt != 0) revert PendingProposalExists();
        uint64 activatesAt = uint64(block.timestamp + s.timelockDelay);
        s.pendingGovernance = newGovernance;
        s.pendingGovernanceActivatesAt = activatesAt;
        emit GovernanceTransferProposed(newGovernance, activatesAt);
    }

    function activateGovernanceTransfer() external {
        VaultStorage.Layout storage s = VaultStorage.load();
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

    function cancelGovernanceTransfer() external onlyGovernance {
        VaultStorage.Layout storage s = VaultStorage.load();
        if (s.pendingGovernanceActivatesAt == 0) revert NoPendingProposal();
        address pending = s.pendingGovernance;
        delete s.pendingGovernance;
        delete s.pendingGovernanceActivatesAt;
        emit GovernanceTransferCancelled(pending);
    }

    // ------------------------------------------------------------------------------------------
    // Operator: pause toggles. Governance: setOperator.
    // ------------------------------------------------------------------------------------------

    function setDepositsPaused(bool paused) external onlyOperator {
        VaultStorage.load().depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

    function setWithdrawalsPaused(bool paused) external onlyOperator {
        VaultStorage.load().withdrawalsPaused = paused;
        emit WithdrawalsPausedSet(paused);
    }

    /// @notice Rotate the operator address. Governance only, NO timelock — the operator's
    ///         power is narrowly scoped to pause toggles, so fast rotation is the right
    ///         emergency response if the operator multi-sig is compromised.
    function setOperator(address newOperator) external onlyGovernance {
        if (newOperator == address(0)) revert InvalidConfig();
        VaultStorage.Layout storage s = VaultStorage.load();
        address old = s.operator;
        s.operator = newOperator;
        emit OperatorSet(old, newOperator);
    }

    // ------------------------------------------------------------------------------------------
    // Tier-1 insurance cap + floor: governance setters + permissionless floor check
    // ------------------------------------------------------------------------------------------

    /// @inheritdoc ILPVault
    function setInsuranceCapBps(uint16 bps) external onlyGovernance {
        if (bps < MIN_INSURANCE_CAP_BPS || bps > MAX_INSURANCE_CAP_BPS) revert InsuranceCapBpsOutOfRange();
        VaultStorage.Layout storage s = VaultStorage.load();
        // Cap MUST stay strictly above the floor. We check against the on-storage floor so
        // governance cannot accidentally drop the cap below the live floor in one call.
        if (bps <= s.insuranceFloorBps) revert InsuranceFloorNotBelowCap();
        uint16 old = s.insuranceCapBps;
        s.insuranceCapBps = bps;
        emit InsuranceCapBpsSet(old, bps);
    }

    /// @inheritdoc ILPVault
    function setInsuranceFloorBps(uint16 bps) external onlyGovernance {
        if (bps > MAX_INSURANCE_FLOOR_BPS) revert InsuranceFloorBpsOutOfRange();
        VaultStorage.Layout storage s = VaultStorage.load();
        // Floor MUST stay strictly below the cap.
        if (bps >= s.insuranceCapBps) revert InsuranceFloorNotBelowCap();
        uint16 old = s.insuranceFloorBps;
        s.insuranceFloorBps = bps;
        emit InsuranceFloorBpsSet(old, bps);
    }

    /// @inheritdoc ILPVault
    function checkInsuranceFloor() external {
        _emitFloorBreachIfBelow(VaultStorage.load());
    }

    /// @inheritdoc ILPVault
    /// @dev Re-cranks the bucket with a zero add so the new window `T` takes effect on the currently
    ///      unvested remainder immediately (`r = P_remaining / T_new`), keeping the drip continuous
    ///      and NAV unchanged at the call instant (the crank realises vested-so-far but adds nothing).
    function setEventSurplusVestWindow(uint32 w) external onlyGovernance {
        if (w < MIN_EVENT_SURPLUS_VEST_WINDOW || w > MAX_EVENT_SURPLUS_VEST_WINDOW) revert InvalidConfig();
        VaultStorage.Layout storage s = VaultStorage.load();
        uint32 old = s.eventSurplusVestWindow;
        s.eventSurplusVestWindow = w;
        _accrueEventSurplus(s, 0); // re-anchor the drip to the new window on the unvested remainder
        emit EventSurplusVestWindowSet(old, w);
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    /// @dev Raw liquid balance BEFORE excluding the unvested event surplus:
    ///      `balance(USDC) − positionCollateral − insuranceFundBalance − accruedFees`. This is the
    ///      pre-Design-2 `freeAssets` body verbatim. Used by `capTvl` (so the perp OI cap is
    ///      byte-identical to before this refactor) and as the base for `freeAssets`. Saturates at 0.
    function _liquidRaw(VaultStorage.Layout storage s) internal view returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 booked = s.positionCollateral + s.insuranceFundBalance + s.accruedFees;
        return bal > booked ? bal - booked : 0;
    }

    /// @dev Unvested portion of the receive-only event-surplus bucket = `P − r·(now − t0)`,
    ///      saturating at 0 once fully vested. `T` (the window) only affects the rate `r` set at the
    ///      last crank, so a live view needs no `T` here. Monotonically non-increasing between
    ///      settles (r, t0, P are all fixed between cranks and `now` only advances).
    function _unvestedEventSurplus(VaultStorage.Layout storage s) internal view returns (uint256) {
        uint256 p = s.eventSurplusPrincipal;
        if (p == 0) return 0;
        uint256 t0 = s.eventSurplusLastAccrual;
        if (block.timestamp <= t0) return p;
        uint256 vested = s.eventSurplusRatePerSec * (block.timestamp - t0);
        return p > vested ? p - vested : 0;
    }

    /// @inheritdoc ILPVault
    function unvestedEventSurplus() public view returns (uint256) {
        return _unvestedEventSurplus(VaultStorage.load());
    }

    /// @inheritdoc ILPVault
    function eventSurplusVestWindow() external view returns (uint32) {
        uint32 w = VaultStorage.load().eventSurplusVestWindow;
        return w == 0 ? DEFAULT_EVENT_SURPLUS_VEST_WINDOW : w;
    }

    /// @inheritdoc ILPVault
    /// @dev STRICTLY LIQUID and immediately redeemable: `_liquidRaw − unvestedEventSurplus`, i.e.
    ///      `balance(USDC) − positionCollateral − insuranceFundBalance − accruedFees −
    ///      unvestedEventSurplus`. Event-market seed that has physically left the vault is NOT added
    ///      back (that was the redemption-arb bug). The not-yet-vested LP-owned event surplus is
    ///      ALSO excluded here — strictly MORE conservative than the raw liquid figure — so a
    ///      depositor entering just before/at settle cannot skim the settle-time floor→exact snap;
    ///      it drips in over the vest window instead. This keeps strict invariant I1 with a 5th
    ///      bucket (`balance == freeAssets + positionCollateral + insurance + fees +
    ///      unvestedEventSurplus`) and is the honest solvency cap for perp settle / liquidation /
    ///      withdrawal. Saturates at 0 so this view stays callable during incident response.
    function freeAssets() public view returns (uint256) {
        VaultStorage.Layout storage s = VaultStorage.load();
        uint256 liquid = _liquidRaw(s);
        uint256 unvested = _unvestedEventSurplus(s);
        return liquid > unvested ? liquid - unvested : 0;
    }

    /// @inheritdoc ILPVault
    /// @dev Sum of the current recoverable value of every live event market. Added to `freeAssets()`
    ///      to form the share-price NAV (`totalAssets`). Each market self-reports the pure LMSR
    ///      worst-case-liability FLOOR (`market.balance − max(q1,q2)`), held UNCHANGED through
    ///      resolution (no UMA read, no floor→exact snap), so this never over-marks system cash
    ///      (`Σ recoverable_i ≤ Σ market.balanceOf(USDC)`). The loop is bounded by
    ///      `MAX_LIVE_EVENT_MARKETS`; it is also cheaper now (no UMA staticcall per market). A market
    ///      that reverts (e.g. a malicious/gas-bombing clone) is skipped and left unmarked —
    ///      conservative (understates NAV, never over-marks) and keeps this view callable so perp
    ///      settle / liquidation / withdrawal never brick on it.
    function eventRecoverable() public view returns (uint256 total) {
        VaultStorage.Layout storage s = VaultStorage.load();
        address[] storage m = s.liveEventMarkets;
        uint256 len = m.length;
        for (uint256 i; i < len; ++i) {
            try IEventMarket(m[i]).currentRecoverable() returns (uint256 r) {
                total += r;
            } catch {
                // Leave that market unmarked (conservative — understates NAV, never over-marks).
            }
        }
    }

    /// @notice DISPLAY-ONLY, NON-LOAD-BEARING. Σ over live markets of `bal_i − E[liability_i]`, where
    ///         `E[liability] = (pYes·q1 + (1e18−pYes)·q2)/1e18` uses the market's own LMSR-implied
    ///         softmax price (`priceOf`). This is the unbiased mid-life "fair" recoverable an indexer
    ///         / admin UI can surface alongside the conservative `eventRecoverable()` floor. It is
    ///         NEVER used in `totalAssets`/`freeAssets`/the mark — the on-chain NAV uses only the
    ///         floor + the receive-only vesting bucket. try/catch per market like `eventRecoverable`.
    function fairRecoverable() external view returns (uint256 total) {
        VaultStorage.Layout storage s = VaultStorage.load();
        address[] storage m = s.liveEventMarkets;
        address usdc_ = asset();
        uint256 len = m.length;
        for (uint256 i; i < len; ++i) {
            IEventMarket mkt = IEventMarket(m[i]);
            try mkt.priceOf(true) returns (uint256 pYes) {
                uint256 q1 = mkt.totalYesShares();
                uint256 q2 = mkt.totalNoShares();
                uint256 eLiab = (pYes * q1 + (1e18 - pYes) * q2) / 1e18;
                uint256 bal = IERC20(usdc_).balanceOf(address(mkt));
                if (bal > eLiab) total += bal - eLiab;
            } catch {
                // Skip markets that revert (conservative — display value understates).
            }
        }
    }

    /// @inheritdoc ILPVault
    /// @dev O(1) perp OI-cap denominator, decoupled from the per-market NAV mark. Equals
    ///      `_liquidRaw + eventFundedSeed`: funding a market subtracts `S` from the balance (hence
    ///      from `_liquidRaw`) while adding `S` to `eventFundedSeed`, so this total is invariant to
    ///      fund/settle. NOTE: this uses `_liquidRaw`, NOT `freeAssets` — it deliberately does NOT
    ///      subtract the unvested event surplus, so it stays BYTE-IDENTICAL to the pre-Design-2
    ///      value (`old-freeAssets + eventFundedSeed`). That keeps perp OI capacity/liveness (the S1
    ///      concern) exactly as before, with no loop on the perp hot path; only LP share pricing
    ///      (via `freeAssets`) reflects the vesting exclusion.
    function capTvl() external view returns (uint256) {
        VaultStorage.Layout storage s = VaultStorage.load();
        return _liquidRaw(s) + s.eventFundedSeed;
    }

    /// @inheritdoc ILPVault
    function liveEventMarketCount() external view returns (uint256) {
        return VaultStorage.load().liveEventMarkets.length;
    }

    function positionCollateral() external view returns (uint256) {
        return VaultStorage.load().positionCollateral;
    }

    /// @inheritdoc ILPVault
    /// @dev Post-migration this returns `IInsuranceFund.balance()` — the standalone fund's
    ///      bookkeeper. Pre-migration it returns the in-vault `insuranceFundBalance`. The view
    ///      stays the source of truth for off-chain callers regardless of which side holds the
    ///      USDC.
    function insuranceFundBalance() external view returns (uint256) {
        return _insuranceBalanceFor(VaultStorage.load());
    }

    /// @inheritdoc ILPVault
    function insuranceFund() external view returns (address) {
        return VaultStorage.load().insuranceFund;
    }

    function accruedFees() external view returns (uint256) {
        return VaultStorage.load().accruedFees;
    }

    function depositsPaused() external view returns (bool) {
        return VaultStorage.load().depositsPaused;
    }

    function withdrawalsPaused() external view returns (bool) {
        return VaultStorage.load().withdrawalsPaused;
    }

    function perpEngine() external view returns (address) {
        return VaultStorage.load().perpEngine;
    }

    function operator() external view returns (address) {
        return VaultStorage.load().operator;
    }

    function governance() external view returns (address) {
        return VaultStorage.load().governance;
    }

    function timelockDelay() external view returns (uint32) {
        return VaultStorage.load().timelockDelay;
    }

    function pendingPerpEngine() external view returns (address account, uint64 activatesAt) {
        VaultStorage.Layout storage s = VaultStorage.load();
        return (s.pendingPerpEngine, s.pendingPerpEngineActivatesAt);
    }

    /// @inheritdoc ILPVault
    function liquidationEngine() external view returns (address) {
        return VaultStorage.load().liquidationEngine;
    }

    /// @inheritdoc ILPVault
    function pendingLiquidationEngine() external view returns (address account, uint64 activatesAt) {
        VaultStorage.Layout storage s = VaultStorage.load();
        return (s.pendingLiquidationEngine, s.pendingLiquidationEngineActivatesAt);
    }

    function pendingGovernance() external view returns (address account, uint64 activatesAt) {
        VaultStorage.Layout storage s = VaultStorage.load();
        return (s.pendingGovernance, s.pendingGovernanceActivatesAt);
    }

    /// @inheritdoc ILPVault
    function eventMarketFactory() external view returns (address) {
        return VaultStorage.load().eventMarketFactory;
    }

    /// @inheritdoc ILPVault
    function pendingEventMarketFactory() external view returns (address account, uint64 activatesAt) {
        VaultStorage.Layout storage s = VaultStorage.load();
        return (s.pendingEventMarketFactory, s.pendingEventMarketFactoryActivatesAt);
    }

    /// @inheritdoc ILPVault
    function eventFundedSeed() external view returns (uint256) {
        return VaultStorage.load().eventFundedSeed;
    }

    function insuranceSeedDeposited() external view returns (uint256) {
        return VaultStorage.load().insuranceSeedDeposited;
    }

    function pendingFeeWithdrawal()
        external
        view
        returns (address recipient, uint256 amount, uint64 activatesAt, bool exists)
    {
        VaultStorage.PendingFeeWithdrawal memory p = VaultStorage.load().pendingFeeWithdrawal;
        return (p.recipient, p.amount, p.activatesAt, p.exists);
    }

    /// @inheritdoc ILPVault
    function insuranceCapBps() external view returns (uint16) {
        return VaultStorage.load().insuranceCapBps;
    }

    /// @inheritdoc ILPVault
    function insuranceFloorBps() external view returns (uint16) {
        return VaultStorage.load().insuranceFloorBps;
    }

    // ------------------------------------------------------------------------------------------
    // UUPS
    // ------------------------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyGovernance {}
}
