// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ILPVault} from "../core/ILPVault.sol";
import {IMarginEngine} from "../core/IMarginEngine.sol";
import {IPerpEngine} from "../core/IPerpEngine.sol";
import {ISubjectRegistry} from "../registry/ISubjectRegistry.sol";

import {FundingMath} from "./FundingMath.sol";
import {PositionMath} from "./PositionMath.sol";
import {PerpStorage, QuoteFundingStorage} from "./StorageLib.sol";

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

    // ------------------------------------------------------------------------------------------
    // Errors (signatures must match IPerpEngine)
    // ------------------------------------------------------------------------------------------

    error InvalidConfig();
    error PositionNotOpen(bytes32 subjectId);
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
    error GlobalHaltedError();
    error SubjectIsForceSettled(bytes32 subjectId);
    error MaintenanceMarginShort(uint256 mmBps, uint256 ratioBps);
    error MarginEngineUnset();

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

        uint256 openingNotionalDelta = (absClose * pos.entryPrice) / ONE;
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
        uint256 openingNotional = (absSize * orig.entryPrice) / ONE;

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
