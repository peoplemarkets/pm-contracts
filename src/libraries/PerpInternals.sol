// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ILPVault} from "../core/ILPVault.sol";
import {IMarginEngine} from "../core/IMarginEngine.sol";
import {IPerpEngine} from "../core/IPerpEngine.sol";
import {ISubjectRegistry} from "../registry/ISubjectRegistry.sol";

import {PerpStorage} from "./StorageLib.sol";

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

    // ------------------------------------------------------------------------------------------
    // Errors (signatures must match IPerpEngine)
    // ------------------------------------------------------------------------------------------

    error InvalidConfig();
    error PositionNotOpen(bytes32 subjectId);
    error LiquidationSizeMismatch(int256 positionSize, int256 sizeToClose);
    error LiquidationSizeZero();

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
        if (collateralToReturn > collateralReleased) revert InvalidConfig();

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
}
