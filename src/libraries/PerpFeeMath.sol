// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title PerpFeeMath
/// @notice Canonical maker/taker fee and vault-split calculation for every perp entry path.
library PerpFeeMath {
    uint256 internal constant FEE_RATE_DENOMINATOR = 1_000_000;
    uint16 internal constant TAKER_FEE_RATE = 750; // 0.075%
    uint16 internal constant MAKER_FEE_RATE = 250; // 0.025%
    uint8 internal constant INSURANCE_PERCENT = 50;

    function compute(
        uint256 notional,
        bool isMaker,
        uint8 lpRebatePercent
    )
        internal
        pure
        returns (uint256 fee, uint256 lpRebate, uint256 insuranceShare)
    {
        uint256 rate = isMaker ? MAKER_FEE_RATE : TAKER_FEE_RATE;
        fee = (notional * rate) / FEE_RATE_DENOMINATOR;
        lpRebate = (fee * uint256(lpRebatePercent)) / 100;
        insuranceShare = (fee * INSURANCE_PERCENT) / 100;
    }
}
