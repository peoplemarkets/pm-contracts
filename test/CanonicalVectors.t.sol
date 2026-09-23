// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {LMSRMath} from "../src/events/LMSRMath.sol";
import {FundingMath} from "../src/libraries/FundingMath.sol";
import {PerpFeeMath} from "../src/libraries/PerpFeeMath.sol";
import {PositionMath} from "../src/libraries/PositionMath.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Integer-only output for API/engine/indexer parity; no broadcast or paper runtime.
contract CanonicalVectorsTest is Test {
    function test_lmsrVectors() public view {
        string memory fixture = vm.readFile("docs/assurance/canonical-vectors-v1.json");
        for (uint256 i; i < 4; ++i) {
            string memory key = string.concat(".lmsr[", vm.toString(i), "]");
            uint256 q1 = vm.parseUint(vm.parseJsonString(fixture, string.concat(key, ".q1")));
            uint256 q2 = vm.parseUint(vm.parseJsonString(fixture, string.concat(key, ".q2")));
            uint256 b = vm.parseUint(vm.parseJsonString(fixture, string.concat(key, ".b")));
            uint256 amount = vm.parseUint(vm.parseJsonString(fixture, string.concat(key, ".usdcIn6")));
            uint256 shares = LMSRMath.sharesForUsdc(q1, q2, b, amount);
            assertEq(LMSRMath.cost(q1, q2, b), vm.parseUint(vm.parseJsonString(fixture, string.concat(key, ".cost6"))));
            assertEq(shares, vm.parseUint(vm.parseJsonString(fixture, string.concat(key, ".buyShares6"))));
            assertEq(
                LMSRMath.usdcForShares(q1 + shares, q2, b, shares),
                vm.parseUint(vm.parseJsonString(fixture, string.concat(key, ".sellReturn6")))
            );
        }
    }

    function test_financeParity() public view {
        string memory fixture = vm.readFile("docs/assurance/canonical-vectors-v1.json");
        assertEq(
            int256(PositionMath.notional(3e6, 2e18)), vm.parseInt(vm.parseJsonString(fixture, ".finance.notional6"))
        );
        (uint256 maker,,) = PerpFeeMath.compute(6e6, true, 50);
        (uint256 taker,,) = PerpFeeMath.compute(6e6, false, 50);
        assertEq(int256(maker), vm.parseInt(vm.parseJsonString(fixture, ".finance.makerFee6")));
        assertEq(int256(taker), vm.parseInt(vm.parseJsonString(fixture, ".finance.takerFee6")));
        (uint256 dust,,) = PerpFeeMath.compute(1, false, 50);
        assertEq(int256(dust), vm.parseInt(vm.parseJsonString(fixture, ".finance.dustFee6")));
        assertEq(
            int256(PositionMath.notional(3, 1.5e18)),
            vm.parseInt(vm.parseJsonString(fixture, ".finance.nonintegralNotional6"))
        );
        assertEq(
            int256(PositionMath.marginRatioBps(2e6, 10e6)),
            vm.parseInt(vm.parseJsonString(fixture, ".finance.marginRatioBps"))
        );
        assertEq(
            int256(FundingMath.computeFundingDebt(2e6, 0.02e18, 0)),
            vm.parseInt(vm.parseJsonString(fixture, ".finance.longDebt6"))
        );
        assertEq(
            int256(FundingMath.computeFundingDebt(-2e6, 0.02e18, 0)),
            vm.parseInt(vm.parseJsonString(fixture, ".finance.shortDebt6"))
        );
        assertEq(
            int256(FundingMath.computeFundingDebt(2e6, -0.02e18, 0)),
            vm.parseInt(vm.parseJsonString(fixture, ".finance.negativeRateLongDebt6"))
        );
        assertEq(
            int256(FundingMath.computeFundingDebt(-2e6, -0.02e18, 0)),
            vm.parseInt(vm.parseJsonString(fixture, ".finance.negativeRateShortDebt6"))
        );
        assertEq(
            int256(FundingMath.computeQuoteIndexDelta(1e15, 100e18, 3600)),
            vm.parseInt(vm.parseJsonString(fixture, ".finance.hourlyQuoteDelta18"))
        );
        assertEq(
            int256(FundingMath.computeFundingDebt(-1, 0.5e18, 0)),
            vm.parseInt(vm.parseJsonString(fixture, ".finance.negativeDustDebt6"))
        );
    }
}
