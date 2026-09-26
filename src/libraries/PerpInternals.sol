// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILPVault} from "../core/ILPVault.sol";
import {IMarginEngine} from "../core/IMarginEngine.sol";
import {IPerpEngine} from "../core/IPerpEngine.sol";
import {ISubjectRegistry} from "../registry/ISubjectRegistry.sol";

import {FundingMath} from "./FundingMath.sol";
import {PerpFeeMath} from "./PerpFeeMath.sol";
import {PositionMath} from "./PositionMath.sol";
import {FundingStorage, PerpStorage, QuoteFundingStorage} from "./StorageLib.sol";

/// @title  PerpInternals — bytecode-extraction library for PerpEngine.
/// @notice Hosts the heavy-weight close paths (`liquidateClose`) as a `public` library function so
///         the engine's runtime size stays under the 24,576-byte EIP-170 cap. Library is linked
///         once at deployment; consumers `DELEGATECALL` into it, so namespaced storage (`PerpStorage`)
///         resolves against the engine's storage root unchanged.
///
/// @dev    Events declared here are emitted under the calling contract's address (delegatecall
///         semantics for public library functions). Event signatures must match the
///         engine-facing interface so indexers remain selector-compatible.
library PerpInternals {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant MIN_MARK = 1;
    uint256 internal constant MAX_MARK = 1e36;

    // ------------------------------------------------------------------------------------------
    // Mirrored events (signatures must match IPerpEngine)
    // ------------------------------------------------------------------------------------------

    event PositionLiquidated(
        bytes32 indexed positionId,
        address indexed trader,
        address indexed liquidator,
        int256 sizeClosed,
        uint256 collateralReturned,
        uint256 bountyPaid,
        int256 signedPnl,
        uint8 tierCode
    );

    event PositionOpened(
        bytes32 indexed positionId,
        address indexed trader,
        bytes32 indexed subjectId,
        IPerpEngine.Side side,
        int256 size,
        uint256 entryPrice,
        uint256 collateral,
        uint256 fee
    );

    event PositionIncreased(
        bytes32 indexed positionId,
        address indexed trader,
        bytes32 indexed subjectId,
        IPerpEngine.Side side,
        int256 sizeDelta,
        int256 newSize,
        uint256 executionPrice,
        uint256 newEntryPrice,
        uint256 collateralDelta,
        uint256 newCollateral,
        uint256 fee
    );

    event PositionClosed(
        bytes32 indexed positionId,
        address indexed trader,
        bytes32 indexed subjectId,
        int256 realizedPnl,
        uint256 fee,
        uint256 returnedToTrader,
        bool isFullClose,
        int256 size,
        bool isLong
    );

    // BREAKING: `size` + `isLong` appended (see IPerpEngine) — signature MUST match the interface
    // so delegatecall-emitted logs stay selector-compatible. Forced settlement is always a full
    // close, so `size` is the full signed position size.
    event PositionClosedAtForcedSettlement(
        bytes32 indexed positionId,
        address indexed trader,
        bytes32 indexed subjectId,
        int256 realizedPnl,
        uint256 returnedToTrader,
        int256 size,
        bool isLong
    );

    event FundingSettled(bytes32 indexed positionId, address indexed trader, int256 fundingDelta1e6);
    event FundingQuotePushed(
        bytes32 indexed subjectId,
        int256 oldQuoteIndex1e18,
        int256 newQuoteIndex1e18,
        int256 fundingRate1e18,
        uint256 markPrice1e18,
        uint64 timestamp
    );
    event QuoteFundingActivated(uint64 timestamp);
    event CollateralRemoved(bytes32 indexed positionId, uint256 amount, uint256 newCollateral);
    event MarkImpulsed(
        bytes32 indexed subjectId, uint256 oldMark, uint256 newMark, int256 impulseBps, uint64 timestamp
    );

    // ------------------------------------------------------------------------------------------
    // Errors (signatures must match IPerpEngine)
    // ------------------------------------------------------------------------------------------

    error InvalidConfig();
    error PositionAlreadyOpen(address trader, bytes32 subjectId);
    error PositionNotOpen(bytes32 subjectId);
    error PositionIdMismatch(bytes32 expected, bytes32 actual);
    error PositionSideMismatch(IPerpEngine.Side requestedSide, int256 currentSize);
    error ReduceOnlySideMismatch(IPerpEngine.Side orderSide, int256 positionSize);
    error ReduceOnlySizeExceeded(uint256 quantity, uint256 positionQuantity);
    error KycTierMissing(address trader);
    error DeadlineExpired(uint64 deadline);
    error SlippageExceeded(uint256 expected, uint256 actual, uint256 maxBps);
    error MarkDivergenceBpsOutOfRange(uint256 bps);
    error FeeLimitExceeded(uint256 fee, uint256 maxFee);
    error MarkValueOutOfRange(uint256 value);
    error LiquidationSizeMismatch(int256 positionSize, int256 sizeToClose);
    error LiquidationSizeZero();
    error SubjectNotForceSettled(bytes32 subjectId);
    error MarkNotSet(bytes32 subjectId);
    error MarkStale(bytes32 subjectId, uint64 updatedAt);
    error QuoteFundingMustSeedAtZero(int256 attemptedIndex);
    error QuoteFundingSeedRateNotZero(int256 attemptedRate);
    error FundingMarkMismatch(uint256 expectedMark, uint256 providedMark);
    error InvalidFundingQuoteIndex(int256 expectedIndex, int256 providedIndex);
    error AmountZero();
    error UnderwaterClose(int256 equity);
    error GlobalHaltedError();
    error SubjectIsForceSettled(bytes32 subjectId);
    error MaintenanceMarginShort(uint256 mmBps, uint256 ratioBps);
    error MarginEngineUnset();
    error MarkNotInitialized(bytes32 subjectId);
    error ImpulseUnderflow();

    /// @dev PerpEngine checks the FeedbackController role before delegating here.
    function applyImpulse(bytes32 subjectId, int256 impulseBps) public {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        ISubjectRegistry(perpS.subjectRegistry).requireTradeable(subjectId);

        uint256 oldMark = perpS.markPrice[subjectId];
        if (oldMark == 0) revert MarkNotInitialized(subjectId);

        int256 multiplier = int256(BPS_DENOMINATOR) + impulseBps;
        int256 newMarkSigned = (int256(oldMark) * multiplier) / int256(BPS_DENOMINATOR);
        if (newMarkSigned <= 0) revert ImpulseUnderflow();
        uint256 newMark = uint256(newMarkSigned);

        perpS.markPrice[subjectId] = newMark;
        perpS.markUpdatedAt[subjectId] = uint64(block.timestamp);

        emit MarkImpulsed(subjectId, oldMark, newMark, impulseBps, uint64(block.timestamp));
    }

    /// @notice Apply one side of an EIP-712-authorized matched open at its execution price.
    /// @dev The PerpEngine wrapper enforces the trusted-router role and reentrancy guard. The
    ///      matched-fill router invokes this twice in one EVM transaction; a failure on either
    ///      side unwinds both position and vault transitions. Full-order compatibility,
    ///      signatures, nonces, maker/taker derivation, and price limits live in that router.
    function openPositionForMatched(
        address trader,
        IPerpEngine.MatchedOpenParams memory p
    )
        public
        returns (bytes32 positionId)
    {
        PerpStorage.Layout storage perpS = PerpStorage.load();

        if (trader == address(0)) revert InvalidConfig();
        positionId = perpS.openPositionId[trader][p.subjectId];
        if (positionId != bytes32(0)) {
            if (!p.isMaker) revert PositionAlreadyOpen(trader, p.subjectId);
            _increasePositionForMatched(trader, positionId, p);
            return positionId;
        }
        if (perpS.globalHalt) revert GlobalHaltedError();
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        if (p.collateralAmount == 0 || p.quantity == 0) revert AmountZero();
        if (p.quantity > uint256(type(int256).max)) revert InvalidConfig();
        if (p.executionPrice < MIN_MARK || p.executionPrice > MAX_MARK) {
            revert MarkValueOutOfRange(p.executionPrice);
        }
        if (p.maxMarkDivergenceBps > BPS_DENOMINATOR) {
            revert MarkDivergenceBpsOutOfRange(p.maxMarkDivergenceBps);
        }

        ISubjectRegistry(perpS.subjectRegistry).requireTradeable(p.subjectId);
        uint8 tier = ISubjectRegistry(perpS.subjectRegistry).kycTierOf(trader);
        if (tier == 0) revert KycTierMissing(trader);

        uint256 markNow = _readFreshMark(perpS, p.subjectId);
        _checkSlippage(markNow, p.executionPrice, p.maxMarkDivergenceBps);

        uint256 sizeNotional = (p.quantity * p.executionPrice) / ONE;
        if (sizeNotional == 0) revert AmountZero();

        IMarginEngine me = IMarginEngine(perpS.marginEngine);
        if (address(me) == address(0)) revert MarginEngineUnset();
        me.checkInitialMargin(sizeNotional, p.collateralAmount);
        bytes32 categoryId = _categoryOf(perpS, p.subjectId);
        _enforceOpenCaps(me, perpS, trader, p, sizeNotional, categoryId, tier);

        (uint256 fee, uint256 lpRebate, uint256 insuranceShare) =
            PerpFeeMath.compute(sizeNotional, p.isMaker, perpS.lpRebatePct);
        if (fee > p.maxFee) revert FeeLimitExceeded(fee, p.maxFee);

        int256 absSize = int256(p.quantity);
        int256 signedSize = p.side == IPerpEngine.Side.LONG ? absSize : -absSize;

        unchecked {
            positionId = keccak256(abi.encode(trader, p.subjectId, perpS.nextPositionNonce++));
        }

        int256 entryFundingIndex = FundingStorage.load().cumulativeFundingIndex[p.subjectId];
        QuoteFundingStorage.Layout storage quoteS = QuoteFundingStorage.load();
        perpS.positions[positionId] = IPerpEngine.Position({
            size: signedSize,
            collateral: p.collateralAmount,
            entryPrice: p.executionPrice,
            entryFundingIndex: entryFundingIndex,
            openedAt: uint64(block.timestamp),
            lastInteractionAt: uint64(block.timestamp),
            owner: trader,
            subjectId: p.subjectId
        });
        quoteS.entryQuoteIndex[positionId] = quoteS.cumulativeQuoteIndex[p.subjectId];
        perpS.openPositionId[trader][p.subjectId] = positionId;
        perpS.positionOpeningNotional[positionId] = sizeNotional;

        if (p.side == IPerpEngine.Side.LONG) {
            perpS.totalLongOI[p.subjectId] += sizeNotional;
        } else {
            perpS.totalShortOI[p.subjectId] += sizeNotional;
        }
        me.recordOpenDelta(trader, categoryId, IMarginEngine.Side(uint8(p.side)), sizeNotional, tier);

        ILPVault(perpS.lpVault).openPositionFlow(trader, p.collateralAmount, fee, lpRebate, insuranceShare);
        emit PositionOpened(
            positionId, trader, p.subjectId, p.side, signedSize, p.executionPrice, p.collateralAmount, fee
        );
    }

    /// @notice Increase the live same-side position created by an earlier slice of one signed
    ///         resting maker. Weighted entry values preserve the pre-increase trading PnL and
    ///         quote-funding debt while the new slice starts at the current execution/index state.
    function _increasePositionForMatched(
        address trader,
        bytes32 positionId,
        IPerpEngine.MatchedOpenParams memory p
    )
        private
    {
        PerpStorage.Layout storage perpS = PerpStorage.load();

        if (trader == address(0)) revert InvalidConfig();
        if (perpS.globalHalt) revert GlobalHaltedError();
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        if (p.collateralAmount == 0 || p.quantity == 0) revert AmountZero();
        if (p.quantity > uint256(type(int256).max)) revert InvalidConfig();
        if (p.executionPrice < MIN_MARK || p.executionPrice > MAX_MARK) {
            revert MarkValueOutOfRange(p.executionPrice);
        }
        if (p.maxMarkDivergenceBps > BPS_DENOMINATOR) {
            revert MarkDivergenceBpsOutOfRange(p.maxMarkDivergenceBps);
        }

        ISubjectRegistry(perpS.subjectRegistry).requireTradeable(p.subjectId);
        uint8 tier = ISubjectRegistry(perpS.subjectRegistry).kycTierOf(trader);
        if (tier == 0) revert KycTierMissing(trader);

        bytes32 currentPositionId = perpS.openPositionId[trader][p.subjectId];
        if (currentPositionId != positionId) revert PositionIdMismatch(positionId, currentPositionId);
        IPerpEngine.Position storage position = perpS.positions[positionId];
        if (position.size == 0 || position.owner != trader || position.subjectId != p.subjectId) {
            revert PositionIdMismatch(positionId, currentPositionId);
        }
        bool isLong = position.size > 0;
        if ((p.side == IPerpEngine.Side.LONG) != isLong) {
            revert PositionSideMismatch(p.side, position.size);
        }

        uint256 oldQuantity = isLong ? uint256(position.size) : uint256(-position.size);
        if (p.quantity > uint256(type(int256).max) - oldQuantity) revert InvalidConfig();
        uint256 newQuantity = oldQuantity + p.quantity;
        int256 sizeDelta = p.side == IPerpEngine.Side.LONG ? int256(p.quantity) : -int256(p.quantity);
        int256 newSize = position.size + sizeDelta;

        uint256 markNow = _readFreshMark(perpS, p.subjectId);
        _checkSlippage(markNow, p.executionPrice, p.maxMarkDivergenceBps);
        uint256 sizeNotional = (p.quantity * p.executionPrice) / ONE;
        if (sizeNotional == 0) revert AmountZero();

        IMarginEngine me = IMarginEngine(perpS.marginEngine);
        if (address(me) == address(0)) revert MarginEngineUnset();
        bytes32 categoryId = _categoryOf(perpS, p.subjectId);
        _enforceOpenCaps(me, perpS, trader, p, sizeNotional, categoryId, tier);

        (uint256 fee, uint256 lpRebate, uint256 insuranceShare) =
            PerpFeeMath.compute(sizeNotional, p.isMaker, perpS.lpRebatePct);
        if (fee > p.maxFee) revert FeeLimitExceeded(fee, p.maxFee);

        uint256 newEntryPrice = _weightedUint(position.entryPrice, p.executionPrice, p.quantity, newQuantity);
        int256 currentLegacyIndex = FundingStorage.load().cumulativeFundingIndex[p.subjectId];
        int256 newLegacyEntry = _weightedInt(position.entryFundingIndex, currentLegacyIndex, p.quantity, newQuantity);
        QuoteFundingStorage.Layout storage quoteS = QuoteFundingStorage.load();
        int256 currentQuoteIndex = quoteS.cumulativeQuoteIndex[p.subjectId];
        int256 newQuoteEntry =
            _weightedInt(quoteS.entryQuoteIndex[positionId], currentQuoteIndex, p.quantity, newQuantity);
        uint256 newCollateral = position.collateral + p.collateralAmount;
        uint256 currentNotional = (newQuantity * markNow) / ONE;
        if (currentNotional == 0) revert AmountZero();
        int256 unrealizedPnl = PositionMath.unrealizedPnl(newSize, newEntryPrice, markNow);
        int256 fundingDebt = FundingMath.computeFundingDebt(newSize, currentQuoteIndex, newQuoteEntry);
        me.checkInitialMarginResidual(newCollateral, currentNotional, unrealizedPnl - fundingDebt);

        if (perpS.positionOpeningNotional[positionId] == 0) {
            // Seed positions opened before this accounting field was added.
            perpS.positionOpeningNotional[positionId] = (oldQuantity * position.entryPrice) / ONE;
        }
        perpS.positionOpeningNotional[positionId] += sizeNotional;

        position.size = newSize;
        position.collateral = newCollateral;
        position.entryPrice = newEntryPrice;
        position.entryFundingIndex = newLegacyEntry;
        position.lastInteractionAt = uint64(block.timestamp);
        quoteS.entryQuoteIndex[positionId] = newQuoteEntry;

        if (isLong) {
            perpS.totalLongOI[p.subjectId] += sizeNotional;
        } else {
            perpS.totalShortOI[p.subjectId] += sizeNotional;
        }
        me.recordOpenDelta(trader, categoryId, IMarginEngine.Side(uint8(p.side)), sizeNotional, tier);
        ILPVault(perpS.lpVault).openPositionFlow(trader, p.collateralAmount, fee, lpRebate, insuranceShare);

        emit PositionIncreased(
            positionId,
            trader,
            p.subjectId,
            p.side,
            sizeDelta,
            newSize,
            p.executionPrice,
            newEntryPrice,
            p.collateralAmount,
            newCollateral,
            fee
        );
    }

    struct MatchedCloseValues {
        int256 closeSize;
        uint256 closeCollateral;
        uint256 openingNotionalDelta;
        int256 realizedPnl;
        int256 fundingDebt6;
        int256 settlePnl;
        uint256 fee;
        uint256 lpRebate;
        uint256 insuranceShare;
        uint256 returned;
        bool isLong;
        bool fullClose;
    }

    /// @notice Apply an exact EIP-712-authorized reduce-only slice at its matched price.
    /// @dev The position id, side, and quantity are revalidated against live storage so a stale
    ///      signature cannot close a replacement position or cross through zero. Unlike OPEN,
    ///      this path deliberately does not call `requireTradeable`: a risk-reducing close remains
    ///      valid during a subject pause, although the paired OPEN leg will still fail atomically.
    function closePositionForMatched(
        address trader,
        IPerpEngine.MatchedCloseParams memory p
    )
        public
        returns (int256 realizedPnl)
    {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (trader == address(0)) revert InvalidConfig();
        if (perpS.globalHalt) revert GlobalHaltedError();
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        if (p.quantity == 0) revert AmountZero();
        if (p.quantity > uint256(type(int256).max)) revert InvalidConfig();
        if (p.executionPrice < MIN_MARK || p.executionPrice > MAX_MARK) {
            revert MarkValueOutOfRange(p.executionPrice);
        }
        if (p.maxMarkDivergenceBps > BPS_DENOMINATOR) {
            revert MarkDivergenceBpsOutOfRange(p.maxMarkDivergenceBps);
        }
        if (perpS.subjectForceSettled[p.subjectId]) revert SubjectIsForceSettled(p.subjectId);

        bytes32 currentPositionId = perpS.openPositionId[trader][p.subjectId];
        if (currentPositionId != p.positionId) revert PositionIdMismatch(p.positionId, currentPositionId);
        IPerpEngine.Position memory orig = perpS.positions[p.positionId];
        if (orig.size == 0 || orig.owner != trader || orig.subjectId != p.subjectId) {
            revert PositionIdMismatch(p.positionId, currentPositionId);
        }

        bool isLong = orig.size > 0;
        IPerpEngine.Side requiredOrderSide = isLong ? IPerpEngine.Side.SHORT : IPerpEngine.Side.LONG;
        if (p.side != requiredOrderSide) revert ReduceOnlySideMismatch(p.side, orig.size);

        uint256 positionQuantity = isLong ? uint256(orig.size) : uint256(-orig.size);
        if (p.quantity > positionQuantity) revert ReduceOnlySizeExceeded(p.quantity, positionQuantity);

        uint256 markNow = _readFreshMark(perpS, p.subjectId);
        _checkSlippage(markNow, p.executionPrice, p.maxMarkDivergenceBps);

        QuoteFundingStorage.Layout storage quoteS = QuoteFundingStorage.load();
        MatchedCloseValues memory v = _computeMatchedCloseValues(
            orig,
            p.quantity,
            p.executionPrice,
            p.isMaker,
            quoteS.cumulativeQuoteIndex[p.subjectId],
            quoteS.entryQuoteIndex[p.positionId]
        );
        if (v.fee > p.maxFee) revert FeeLimitExceeded(v.fee, p.maxFee);
        v.openingNotionalDelta =
            PerpStorage.consumeOpeningNotional(perpS, p.positionId, p.quantity, positionQuantity, orig.entryPrice);

        if (v.fullClose) {
            delete perpS.positions[p.positionId];
            delete perpS.openPositionId[trader][p.subjectId];
            delete quoteS.entryQuoteIndex[p.positionId];
        } else {
            IPerpEngine.Position storage position = perpS.positions[p.positionId];
            position.size = orig.size - v.closeSize;
            position.collateral = orig.collateral - v.closeCollateral;
            position.lastInteractionAt = uint64(block.timestamp);
        }

        if (v.isLong) {
            perpS.totalLongOI[p.subjectId] -= v.openingNotionalDelta;
        } else {
            perpS.totalShortOI[p.subjectId] -= v.openingNotionalDelta;
        }
        if (perpS.marginEngine != address(0)) {
            IMarginEngine(perpS.marginEngine)
                .recordCloseDelta(trader, _categoryOf(perpS, p.subjectId), v.openingNotionalDelta, v.isLong);
        }

        ILPVault(perpS.lpVault)
            .settlePosition(trader, v.closeCollateral, v.settlePnl, v.fee, v.lpRebate, v.insuranceShare);

        emit FundingSettled(p.positionId, trader, v.fundingDebt6);
        emit PositionClosed(
            p.positionId, trader, p.subjectId, v.realizedPnl, v.fee, v.returned, v.fullClose, v.closeSize, v.isLong
        );
        return v.realizedPnl;
    }

    function _computeMatchedCloseValues(
        IPerpEngine.Position memory orig,
        uint256 quantity,
        uint256 executionPrice,
        bool isMaker,
        int256 currentQuoteIndex,
        int256 entryQuoteIndex
    )
        private
        view
        returns (MatchedCloseValues memory v)
    {
        v.isLong = orig.size > 0;
        uint256 positionQuantity = v.isLong ? uint256(orig.size) : uint256(-orig.size);
        v.fullClose = quantity == positionQuantity;
        v.closeSize = v.isLong ? int256(quantity) : -int256(quantity);
        v.closeCollateral = v.fullClose ? orig.collateral : (orig.collateral * quantity) / positionQuantity;

        uint256 executionNotional = (quantity * executionPrice) / ONE;
        if (executionNotional == 0) revert AmountZero();
        v.realizedPnl = PositionMath.unrealizedPnl(v.closeSize, orig.entryPrice, executionPrice);
        (v.fee, v.lpRebate, v.insuranceShare) =
            PerpFeeMath.compute(executionNotional, isMaker, PerpStorage.load().lpRebatePct);
        v.fundingDebt6 = FundingMath.computeFundingDebt(v.closeSize, currentQuoteIndex, entryQuoteIndex);
        v.settlePnl = v.realizedPnl - v.fundingDebt6;

        int256 returnedSigned = int256(v.closeCollateral) + v.settlePnl - int256(v.fee);
        if (returnedSigned < 0) revert UnderwaterClose(returnedSigned);
        v.returned = uint256(returnedSigned);
    }

    /// @notice Validate and store one cumulative quote-funding update for PerpEngine.
    /// @dev    Extracted as a public library function so PerpEngine remains deployable under
    ///         EIP-170. The caller wrapper enforces the FundingEngine role; delegatecall keeps all
    ///         namespaced storage and emitted event addresses anchored to PerpEngine.
    function pushFundingQuoteIndex(
        bytes32 subjectId,
        int256 newQuoteIndex1e18,
        int256 fundingRate1e18,
        uint256 markPrice1e18
    )
        public
    {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        ISubjectRegistry(perpS.subjectRegistry).requireTradeable(subjectId);

        uint256 markNow = _readFreshMark(perpS, subjectId);
        if (markPrice1e18 != markNow) revert FundingMarkMismatch(markNow, markPrice1e18);

        QuoteFundingStorage.Layout storage quoteS = QuoteFundingStorage.load();
        int256 oldQuoteIndex = quoteS.cumulativeQuoteIndex[subjectId];
        uint64 last = quoteS.lastQuoteFundingAt[subjectId];

        // Every subject seeds its own clock at zero. The global flag is the version handshake;
        // `last == 0` is the per-subject handshake.
        if (last == 0) {
            if (newQuoteIndex1e18 != 0) revert QuoteFundingMustSeedAtZero(newQuoteIndex1e18);
            if (fundingRate1e18 != 0) revert QuoteFundingSeedRateNotZero(fundingRate1e18);
        }
        if (!quoteS.enabled) {
            quoteS.enabled = true;
            quoteS.activatedAt = uint64(block.timestamp);
            emit QuoteFundingActivated(uint64(block.timestamp));
        }

        int256 expectedIndex = oldQuoteIndex;
        if (last != 0) {
            uint64 elapsed = uint64(block.timestamp) - last;
            expectedIndex += FundingMath.computeQuoteIndexDelta(fundingRate1e18, markNow, elapsed);
        }
        if (newQuoteIndex1e18 != expectedIndex) {
            revert InvalidFundingQuoteIndex(expectedIndex, newQuoteIndex1e18);
        }

        quoteS.cumulativeQuoteIndex[subjectId] = newQuoteIndex1e18;
        quoteS.lastQuoteFundingAt[subjectId] = uint64(block.timestamp);
        emit FundingQuotePushed(
            subjectId, oldQuoteIndex, newQuoteIndex1e18, fundingRate1e18, markNow, uint64(block.timestamp)
        );
    }

    /// @notice Funding-aware collateral withdrawal implementation for PerpEngine.
    /// @dev    The external wrappers retain reentrancy and router authorization; delegatecall keeps
    ///         storage, vault calls, errors, and events identical while reducing engine bytecode.
    function removeCollateralFor(address trader, bytes32 subjectId, uint256 amount) public {
        if (amount == 0) revert AmountZero();
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (perpS.globalHalt) revert GlobalHaltedError();
        if (perpS.subjectForceSettled[subjectId]) revert SubjectIsForceSettled(subjectId);

        bytes32 positionId = perpS.openPositionId[trader][subjectId];
        if (positionId == bytes32(0)) revert PositionNotOpen(subjectId);

        IPerpEngine.Position storage pos = perpS.positions[positionId];
        if (amount >= pos.collateral) revert AmountZero();

        uint256 markNow = _readFreshMark(perpS, subjectId);
        uint256 newCollateral = pos.collateral - amount;
        uint256 absSize = pos.size > 0 ? uint256(pos.size) : uint256(-pos.size);
        uint256 currentNotional = (absSize * markNow) / ONE;

        int256 uPnl = PositionMath.unrealizedPnl(pos.size, pos.entryPrice, markNow);
        QuoteFundingStorage.Layout storage quoteS = QuoteFundingStorage.load();
        int256 fundingDebt6 = FundingMath.computeFundingDebt(
            pos.size, quoteS.cumulativeQuoteIndex[subjectId], quoteS.entryQuoteIndex[positionId]
        );
        int256 fundingAdjustedPnl = uPnl - fundingDebt6;
        if (int256(newCollateral) + fundingAdjustedPnl <= 0) revert MaintenanceMarginShort(0, 0);

        address me = perpS.marginEngine;
        if (me == address(0)) revert MarginEngineUnset();
        IMarginEngine(me).checkInitialMarginResidual(newCollateral, currentNotional, fundingAdjustedPnl);

        pos.collateral = newCollateral;
        pos.lastInteractionAt = uint64(block.timestamp);
        ILPVault(perpS.lpVault).releaseCollateral(trader, amount);
        emit CollateralRemoved(positionId, amount, newCollateral);
    }

    function fundingDebtOf(bytes32 positionId) public view returns (int256) {
        IPerpEngine.Position storage pos = PerpStorage.load().positions[positionId];
        if (pos.size == 0) return 0;
        QuoteFundingStorage.Layout storage quoteS = QuoteFundingStorage.load();
        return FundingMath.computeFundingDebt(
            pos.size, quoteS.cumulativeQuoteIndex[pos.subjectId], quoteS.entryQuoteIndex[positionId]
        );
    }

    function equityOf(bytes32 positionId) public view returns (int256) {
        IPerpEngine.Position storage pos = PerpStorage.load().positions[positionId];
        if (pos.size == 0) return 0;
        uint256 markNow = PerpStorage.load().markPrice[pos.subjectId];
        if (markNow == 0) return int256(pos.collateral);
        int256 uPnl = PositionMath.unrealizedPnl(pos.size, pos.entryPrice, markNow);
        return PositionMath.equity(pos.collateral, uPnl - fundingDebtOf(positionId));
    }

    function marginRatioBpsOf(bytes32 positionId) public view returns (uint256) {
        IPerpEngine.Position storage pos = PerpStorage.load().positions[positionId];
        if (pos.size == 0) return 0;
        uint256 markNow = PerpStorage.load().markPrice[pos.subjectId];
        if (markNow == 0) return 0;
        uint256 notional = PositionMath.notional(pos.size, markNow);
        return PositionMath.marginRatioBps(equityOf(positionId), notional);
    }

    function leverageBpsOf(bytes32 positionId) public view returns (uint256) {
        IPerpEngine.Position memory pos = PerpStorage.load().positions[positionId];
        if (pos.size == 0 || pos.collateral == 0) return 0;
        uint256 markNow = PerpStorage.load().markPrice[pos.subjectId];
        if (markNow == 0) return 0;
        uint256 notional = PositionMath.notional(pos.size, markNow);
        return PositionMath.leverageBps(notional, pos.collateral);
    }

    /// @notice Liquidation-engine 3-way close. See PerpEngine.liquidateClose for full semantics.
    /// @dev    Public so the engine links it as an external library and DELEGATECALLs in. This
    ///         keeps the engine bytecode below EIP-170 without splitting state.
    function liquidateClose(
        bytes32 positionId,
        int256 sizeToClose,
        uint256 collateralToReturn,
        uint256 bountyToPay,
        int256 signedPnl,
        address liquidator,
        uint8 tierCode
    )
        public
    {
        if (sizeToClose == 0) revert LiquidationSizeZero();
        PerpStorage.Layout storage perpS = PerpStorage.load();
        QuoteFundingStorage.Layout storage quoteS = QuoteFundingStorage.load();
        IPerpEngine.Position memory pos = perpS.positions[positionId];
        if (pos.size == 0) revert PositionNotOpen(pos.subjectId);

        // Sign-match + magnitude bound.
        bool isLong = pos.size > 0;
        if ((isLong && sizeToClose <= 0) || (!isLong && sizeToClose >= 0)) {
            revert LiquidationSizeMismatch(pos.size, sizeToClose);
        }
        uint256 absClose = sizeToClose > 0 ? uint256(sizeToClose) : uint256(-sizeToClose);
        uint256 absPos = isLong ? uint256(pos.size) : uint256(-pos.size);
        if (absClose > absPos) revert LiquidationSizeMismatch(pos.size, sizeToClose);
        bool fullClose = absClose == absPos;

        uint256 maxCollateralReleased = fullClose ? pos.collateral : (pos.collateral * absClose) / absPos;
        uint256 collateralReleased = maxCollateralReleased;
        if (!fullClose) {
            // `signedPnl` is the real price PnL minus funding on this slice. Deriving the released
            // collateral from payout conservation lets Tier 1 retain any MM-restoration top-up on
            // the residual position instead of silently releasing the full pro-rata share.
            int256 derivedRelease = int256(collateralToReturn) + int256(bountyToPay) - signedPnl;
            if (derivedRelease <= 0 || uint256(derivedRelease) > maxCollateralReleased) revert InvalidConfig();
            collateralReleased = uint256(derivedRelease);
        }
        // For Tiers 1-4 (liquidations) the trader is never returned more than the released
        // collateral — they are underwater. Tier 5 (ADL, tierCode == 5) is the exception: an ADL'd
        // counterparty is PROFITABLE, so its payout (collateral + PnL realised at the bankruptcy
        // price) legitimately exceeds the released collateral. The vault's payout-conservation +
        // freeAssets-solvency guards (settleLiquidation) remain the authoritative checks in all cases.
        if (tierCode != 5 && collateralToReturn > collateralReleased) revert InvalidConfig();

        uint256 openingNotionalDelta =
            PerpStorage.consumeOpeningNotional(perpS, positionId, absClose, absPos, pos.entryPrice);
        int256 fundingDebt6 = FundingMath.computeFundingDebt(
            sizeToClose, quoteS.cumulativeQuoteIndex[pos.subjectId], quoteS.entryQuoteIndex[positionId]
        );

        // State mutations BEFORE the external call (CEI).
        if (fullClose) {
            delete perpS.positions[positionId];
            delete perpS.openPositionId[pos.owner][pos.subjectId];
            delete quoteS.entryQuoteIndex[positionId];
        } else {
            IPerpEngine.Position storage stored = perpS.positions[positionId];
            stored.size = pos.size - sizeToClose;
            stored.collateral = pos.collateral - collateralReleased;
            stored.lastInteractionAt = uint64(block.timestamp);
        }

        if (isLong) {
            perpS.totalLongOI[pos.subjectId] -= openingNotionalDelta;
        } else {
            perpS.totalShortOI[pos.subjectId] -= openingNotionalDelta;
        }
        address me = perpS.marginEngine;
        if (me != address(0)) {
            bytes32 categoryId = ISubjectRegistry(perpS.subjectRegistry).subjectOf(pos.subjectId).categoryId;
            IMarginEngine(me).recordCloseDelta(pos.owner, categoryId, openingNotionalDelta, isLong);
        }

        ILPVault(perpS.lpVault)
            .settleLiquidation(pos.owner, liquidator, collateralReleased, collateralToReturn, bountyToPay, signedPnl);

        emit FundingSettled(positionId, pos.owner, fundingDebt6);
        emit PositionLiquidated(
            positionId, pos.owner, liquidator, sizeToClose, collateralToReturn, bountyToPay, signedPnl, tierCode
        );
    }

    /// @notice Forced-settlement claim. See `IPerpEngine.closeAtForcedSettlement` for full
    ///         semantics. Public so PerpEngine links it as an external library and DELEGATECALLs in
    ///         (keeps the engine under EIP-170). Settles funding accrued up to the freeze and caps
    ///         the trader's loss at posted collateral.
    /// @param  subjectId   Force-settled subject.
    /// @param  claimant    Position owner claiming the unwind (the engine's `msg.sender`).
    /// @return cappedPnl   Signed PnL (funding-adjusted, loss-capped at collateral) booked to the vault.
    function forceSettlementClose(bytes32 subjectId, address claimant) public returns (int256 cappedPnl) {
        PerpStorage.Layout storage perpS = PerpStorage.load();
        if (!perpS.subjectForceSettled[subjectId]) revert SubjectNotForceSettled(subjectId);

        bytes32 positionId = perpS.openPositionId[claimant][subjectId];
        if (positionId == bytes32(0)) revert PositionNotOpen(subjectId);

        IPerpEngine.Position memory orig = perpS.positions[positionId];
        uint256 markCaptured = perpS.subjectSettlementMark[subjectId];

        // Trading PnL at the captured mark + funding accrued up to the freeze. The quote index
        // stops advancing once the subject is paused/delisted (quote pushes are pause-aware), so
        // the index read here is frozen at (or before) the force-settlement timestamp.
        int256 pnl = PositionMath.unrealizedPnl(orig.size, orig.entryPrice, markCaptured);
        QuoteFundingStorage.Layout storage quoteS = QuoteFundingStorage.load();
        int256 fundingDebt6 = FundingMath.computeFundingDebt(
            orig.size, quoteS.cumulativeQuoteIndex[subjectId], quoteS.entryQuoteIndex[positionId]
        );

        // Fold funding into the vault pnl leg, then cap the trader's loss at posted collateral
        // (v2-audit Fix #1): a position underwater past its collateral pays out 0 and the vault
        // keeps the full collateral; the uncovered remainder is an unfunded LP loss in v0.
        int256 effectivePnl = pnl - fundingDebt6;
        cappedPnl = effectivePnl;
        int256 returnedSigned = int256(orig.collateral) + effectivePnl;
        uint256 returned;
        if (returnedSigned < 0) {
            cappedPnl = -int256(orig.collateral);
            returned = 0;
        } else {
            returned = uint256(returnedSigned);
        }

        uint256 absSize = orig.size > 0 ? uint256(orig.size) : uint256(-orig.size);
        uint256 openingNotional =
            PerpStorage.consumeOpeningNotional(perpS, positionId, absSize, absSize, orig.entryPrice);

        // CEI: state mutations before the external settle.
        delete perpS.positions[positionId];
        delete perpS.openPositionId[claimant][subjectId];
        delete quoteS.entryQuoteIndex[positionId];
        bool isLong = orig.size > 0;
        if (isLong) {
            perpS.totalLongOI[subjectId] -= openingNotional;
        } else {
            perpS.totalShortOI[subjectId] -= openingNotional;
        }
        address me = perpS.marginEngine;
        if (me != address(0)) {
            bytes32 categoryId = ISubjectRegistry(perpS.subjectRegistry).subjectOf(subjectId).categoryId;
            IMarginEngine(me).recordCloseDelta(claimant, categoryId, openingNotional, isLong);
        }

        ILPVault(perpS.lpVault).settlePosition(claimant, orig.collateral, cappedPnl, 0, 0, 0);

        emit FundingSettled(positionId, claimant, fundingDebt6);
        // Forced settlement always fully closes the position, so the closed size is the full signed
        // `orig.size` and `isLong` its side. BREAKING event-signature change — see IPerpEngine.
        emit PositionClosedAtForcedSettlement(positionId, claimant, subjectId, cappedPnl, returned, orig.size, isLong);
    }

    function _checkSlippage(uint256 markNow, uint256 executionPrice, uint256 maxBps) private pure {
        uint256 diff = markNow > executionPrice ? markNow - executionPrice : executionPrice - markNow;
        if (diff * BPS_DENOMINATOR > maxBps * executionPrice) {
            revert SlippageExceeded(executionPrice, markNow, maxBps);
        }
    }

    function _weightedUint(
        uint256 oldValue,
        uint256 addedValue,
        uint256 addedWeight,
        uint256 totalWeight
    )
        private
        pure
        returns (uint256)
    {
        if (addedValue >= oldValue) {
            return oldValue + Math.mulDiv(addedValue - oldValue, addedWeight, totalWeight);
        }
        return oldValue - Math.mulDiv(oldValue - addedValue, addedWeight, totalWeight);
    }

    function _weightedInt(
        int256 oldValue,
        int256 addedValue,
        uint256 addedWeight,
        uint256 totalWeight
    )
        private
        pure
        returns (int256)
    {
        if (addedValue >= oldValue) {
            uint256 upAdjustment = Math.mulDiv(uint256(addedValue - oldValue), addedWeight, totalWeight);
            return oldValue + int256(upAdjustment);
        }
        uint256 downAdjustment = Math.mulDiv(uint256(oldValue - addedValue), addedWeight, totalWeight);
        return oldValue - int256(downAdjustment);
    }

    function _categoryOf(PerpStorage.Layout storage perpS, bytes32 subjectId) private view returns (bytes32) {
        return ISubjectRegistry(perpS.subjectRegistry).subjectOf(subjectId).categoryId;
    }

    function _enforceOpenCaps(
        IMarginEngine me,
        PerpStorage.Layout storage perpS,
        address trader,
        IPerpEngine.MatchedOpenParams memory p,
        uint256 sizeNotional,
        bytes32 categoryId,
        uint8 tier
    )
        private
        view
    {
        uint256 liveTvl = ILPVault(perpS.lpVault).capTvl();
        uint256 vaultTvl = perpS.cappedTvl < liveTvl ? perpS.cappedTvl : liveTvl;
        me.enforceOpenCaps(
            trader,
            p.subjectId,
            categoryId,
            IMarginEngine.Side(uint8(p.side)),
            sizeNotional,
            tier,
            perpS.totalLongOI[p.subjectId],
            perpS.totalShortOI[p.subjectId],
            vaultTvl
        );
    }

    function _readFreshMark(PerpStorage.Layout storage perpS, bytes32 subjectId)
        private
        view
        returns (uint256 markNow)
    {
        markNow = perpS.markPrice[subjectId];
        if (markNow == 0) revert MarkNotSet(subjectId);
        uint64 ts = perpS.markUpdatedAt[subjectId];
        if (block.timestamp > uint256(ts) + uint256(perpS.markStaleAfter)) {
            revert MarkStale(subjectId, ts);
        }
    }
}
