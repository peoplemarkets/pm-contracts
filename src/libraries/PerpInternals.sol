// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ILPVault} from "../core/ILPVault.sol";
import {IMarginEngine} from "../core/IMarginEngine.sol";
import {IPerpEngine} from "../core/IPerpEngine.sol";
import {ISubjectRegistry} from "../registry/ISubjectRegistry.sol";

import {FundingMath} from "./FundingMath.sol";
import {PositionMath} from "./PositionMath.sol";
import {FundingStorage, PerpStorage} from "./StorageLib.sol";

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

    event PositionClosedAtForcedSettlement(
        bytes32 indexed positionId,
        address indexed trader,
        bytes32 indexed subjectId,
        int256 realizedPnl,
        uint256 returnedToTrader
    );

    event FundingSettled(bytes32 indexed positionId, address indexed trader, int256 fundingDelta1e6);

    // ------------------------------------------------------------------------------------------
    // Errors (signatures must match IPerpEngine)
    // ------------------------------------------------------------------------------------------

    error InvalidConfig();
    error PositionNotOpen(bytes32 subjectId);
    error LiquidationSizeMismatch(int256 positionSize, int256 sizeToClose);
    error LiquidationSizeZero();
    error SubjectNotForceSettled(bytes32 subjectId);

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

        uint256 collateralReleased = fullClose ? pos.collateral : (pos.collateral * absClose) / absPos;
        // For Tiers 1-4 (liquidations) the trader is never returned more than the released
        // collateral — they are underwater. Tier 5 (ADL, tierCode == 5) is the exception: an ADL'd
        // counterparty is PROFITABLE, so its payout (collateral + PnL realised at the bankruptcy
        // price) legitimately exceeds the released collateral. The vault's payout-conservation +
        // freeAssets-solvency guards (settleLiquidation) remain the authoritative checks in all cases.
        if (tierCode != 5 && collateralToReturn > collateralReleased) revert InvalidConfig();

        uint256 openingNotionalDelta = (absClose * pos.entryPrice) / ONE;

        // State mutations BEFORE the external call (CEI).
        if (fullClose) {
            delete perpS.positions[positionId];
            delete perpS.openPositionId[pos.owner][pos.subjectId];
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

        ILPVault(perpS.lpVault).settleLiquidation(
            pos.owner, liquidator, collateralReleased, collateralToReturn, bountyToPay, signedPnl
        );

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

        // Trading PnL at the captured mark + funding accrued up to the freeze. The cumulative index
        // stops advancing once the subject is paused/delisted (pushFundingIndex is pause-aware), so
        // the index read here is frozen at (or before) the force-settlement timestamp.
        int256 pnl = PositionMath.unrealizedPnl(orig.size, orig.entryPrice, markCaptured);
        int256 fundingDebt6 = FundingMath.computeFundingDebt(
            orig.size, FundingStorage.load().cumulativeFundingIndex[subjectId], orig.entryFundingIndex
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
        emit PositionClosedAtForcedSettlement(positionId, claimant, subjectId, cappedPnl, returned);
    }
}
