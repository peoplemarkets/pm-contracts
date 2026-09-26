// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

library LMSRMath {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    /// @notice Calculates the cost of the current AMM state.
    /// @dev Uses the Log-Sum-Exp trick to prevent overflow.
    ///      C = b * ln(e^(q1/b) + e^(q2/b))
    ///      C = max(q1, q2) + b * ln(1 + e^(-|q1-q2|/b))
    /// @param q1 Shares of outcome 1 (the v1 market uses 6-decimal units)
    /// @param q2 Shares of outcome 2 (the v1 market uses 6-decimal units)
    /// @param b Liquidity parameter B in the same unit as q1 and q2
    /// @return cost Cost in the same unit as q1, q2, and b (6-decimal USDC in v1)
    function cost(uint256 q1, uint256 q2, uint256 b) internal pure returns (uint256) {
        uint256 maxQ = Math.max(q1, q2);
        uint256 minQ = Math.min(q1, q2);

        // diff = (maxQ - minQ) / b
        uint256 diffWad = ((maxQ - minQ) * 1e18) / b;

        // We need exp(-diffWad). Since diffWad is positive, -diffWad is negative.
        // Solady expWad accepts int256.
        int256 expNegDiff = int256(diffWad) * -1;
        uint256 expTerm = uint256(expNegDiff.expWad());

        // ln(1 + expTerm)
        uint256 lnTerm = uint256(int256(1e18 + expTerm).lnWad());

        // cost = maxQ + b * lnTerm
        uint256 costWad = maxQ + (b.mulWad(lnTerm));
        return costWad;
    }

    /// @notice Calculates how many shares a user receives for a given USDC amount.
    /// @dev Formula: dq1 = q2 + b * ln(e^((C_new - q2)/b) - 1) - q1
    /// @param q1 Current shares of the outcome being bought
    /// @param q2 Current shares of the other outcome
    /// @param b Liquidity parameter
    /// @param usdcAmount Amount of USDC being spent
    /// @return dq The number of shares received
    function sharesForUsdc(uint256 q1, uint256 q2, uint256 b, uint256 usdcAmount) internal pure returns (uint256) {
        uint256 cOld = cost(q1, q2, b);
        uint256 cNew = cOld + usdcAmount;

        // (cNew - q2) / b
        require(cNew >= q2, "LMSRMath: cNew < q2");
        uint256 powerWad = ((cNew - q2) * 1e18) / b;

        // expTerm = e^powerWad
        uint256 expTerm = uint256(int256(powerWad).expWad());

        require(expTerm > 1e18, "LMSRMath: expTerm <= 1");
        // ln(exp(power) - 1) is negative whenever the purchase is not large
        // enough to move the bought outcome past the other outcome. Keep that
        // term signed: casting it to uint256 makes ordinary underdog buys
        // overflow in mulWad instead of returning shares.
        require(
            q1 <= uint256(type(int256).max) && q2 <= uint256(type(int256).max) && b <= uint256(type(int256).max),
            "LMSRMath: signed range"
        );
        int256 lnTerm = int256(expTerm - 1e18).lnWad();
        int256 term2 = int256(b).sMulWad(lnTerm);
        int256 newQ1 = int256(q2) + term2;

        require(newQ1 > int256(q1), "LMSRMath: no shares generated");
        return uint256(newQ1) - q1;
    }

    /// @notice Calculates how much USDC a user receives for selling shares.
    /// @param q1 Current shares of the outcome being sold
    /// @param q2 Current shares of the other outcome
    /// @param b Liquidity parameter
    /// @param sharesAmount Number of shares being sold
    /// @return usdcAmount Amount of USDC received
    function usdcForShares(uint256 q1, uint256 q2, uint256 b, uint256 sharesAmount) internal pure returns (uint256) {
        require(q1 >= sharesAmount, "LMSRMath: selling more than exists");
        uint256 cOld = cost(q1, q2, b);
        uint256 cNew = cost(q1 - sharesAmount, q2, b);
        require(cOld >= cNew, "LMSRMath: invalid cost decrease");
        return cOld - cNew;
    }
}
