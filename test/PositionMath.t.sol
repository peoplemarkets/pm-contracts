// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {PositionMath} from "../src/libraries/PositionMath.sol";

/// @dev External harness around the pure library so vm.expectRevert can observe reverts at a
///      deeper call depth than the cheatcode itself. Library calls are inlined into the test
///      contract, which is the same call depth as the cheatcode and confuses expectRevert.
contract PositionMathHarness {
    function notional(int256 size, uint256 mark) external pure returns (uint256) {
        return PositionMath.notional(size, mark);
    }

    function unrealizedPnl(int256 size, uint256 entryPrice, uint256 mark) external pure returns (int256) {
        return PositionMath.unrealizedPnl(size, entryPrice, mark);
    }

    function leverageBps(uint256 notional_, uint256 collateral) external pure returns (uint256) {
        return PositionMath.leverageBps(notional_, collateral);
    }
}

contract PositionMathTest is Test {
    PositionMathHarness internal harness = new PositionMathHarness();

    /// @dev Practical upper bound for fuzz inputs. 1e36 corresponds to 1e18 base units at a 1e18
    ///      fixed-point price — comfortably beyond any plausible Person Stock notional, but
    ///      ensures `size * priceDelta` and `|size| * mark` stay inside int256 / uint256 bounds.
    int256 internal constant MAX_SIZE = int256(1e36);
    uint256 internal constant MAX_PRICE = 1e36;
    uint256 internal constant MAX_COLLATERAL = 1e36;

    // ------------------------------------------------------------------------------------------
    // notional
    // ------------------------------------------------------------------------------------------

    function test_Notional_ZeroSizeReturnsZero() public pure {
        assertEq(PositionMath.notional(0, 100e18), 0);
    }

    function test_Notional_RevertOnZeroMark() public {
        vm.expectRevert(PositionMath.MarkNotPositive.selector);
        harness.notional(int256(1e18), 0);
    }

    function test_Notional_LongAndShortAreSymmetric() public pure {
        uint256 mark = 187.42e18;
        int256 size = int256(266e18);
        uint256 longN = PositionMath.notional(size, mark);
        uint256 shortN = PositionMath.notional(-size, mark);
        assertEq(longN, shortN);
    }

    function test_Notional_KnownValue() public pure {
        // 266 units × $187.42 = $49,853.72
        assertEq(PositionMath.notional(int256(266e18), 187.42e18), 49_853.72e18);
    }

    function testFuzz_Notional_Symmetric(int256 size, uint256 mark) public pure {
        size = bound(size, -MAX_SIZE, MAX_SIZE);
        mark = bound(mark, 1, MAX_PRICE);
        if (size == type(int256).min) size = -MAX_SIZE; // guard: -type(int256).min overflows
        assertEq(PositionMath.notional(size, mark), PositionMath.notional(-size, mark));
    }

    function testFuzz_Notional_NeverReverts(int256 size, uint256 mark) public pure {
        size = bound(size, -MAX_SIZE, MAX_SIZE);
        mark = bound(mark, 1, MAX_PRICE);
        PositionMath.notional(size, mark); // should not revert in valid range
    }

    // ------------------------------------------------------------------------------------------
    // unrealizedPnl
    // ------------------------------------------------------------------------------------------

    function test_Pnl_ZeroSizeReturnsZero() public pure {
        assertEq(PositionMath.unrealizedPnl(0, 100e18, 110e18), 0);
    }

    function test_Pnl_RevertOnZeroEntry() public {
        vm.expectRevert(PositionMath.EntryPriceNotPositive.selector);
        harness.unrealizedPnl(int256(1e18), 0, 100e18);
    }

    function test_Pnl_RevertOnZeroMark() public {
        vm.expectRevert(PositionMath.MarkNotPositive.selector);
        harness.unrealizedPnl(int256(1e18), 100e18, 0);
    }

    function test_Pnl_FlatPriceIsZero() public pure {
        assertEq(PositionMath.unrealizedPnl(int256(1e18), 100e18, 100e18), 0);
        assertEq(PositionMath.unrealizedPnl(-int256(1e18), 100e18, 100e18), 0);
    }

    function test_Pnl_LongProfitsWhenMarkAboveEntry() public pure {
        // 1 unit, entry $100, mark $110 → +$10
        assertEq(PositionMath.unrealizedPnl(int256(1e18), 100e18, 110e18), int256(10e18));
    }

    function test_Pnl_LongLosesWhenMarkBelowEntry() public pure {
        assertEq(PositionMath.unrealizedPnl(int256(1e18), 100e18, 90e18), -int256(10e18));
    }

    function test_Pnl_ShortProfitsWhenMarkBelowEntry() public pure {
        assertEq(PositionMath.unrealizedPnl(-int256(1e18), 100e18, 90e18), int256(10e18));
    }

    function test_Pnl_ShortLosesWhenMarkAboveEntry() public pure {
        assertEq(PositionMath.unrealizedPnl(-int256(1e18), 100e18, 110e18), -int256(10e18));
    }

    function testFuzz_Pnl_SignFollowsLong(int256 size, uint256 entry, uint256 mark) public pure {
        size = bound(size, 1, MAX_SIZE); // strictly long
        entry = bound(entry, 1, MAX_PRICE);
        mark = bound(mark, 1, MAX_PRICE);
        int256 pnl = PositionMath.unrealizedPnl(size, entry, mark);
        if (mark > entry) assertGe(pnl, 0);
        else if (mark < entry) assertLe(pnl, 0);
        else assertEq(pnl, 0);
    }

    function testFuzz_Pnl_SignFollowsShort(int256 size, uint256 entry, uint256 mark) public pure {
        size = bound(size, -MAX_SIZE, -1); // strictly short
        entry = bound(entry, 1, MAX_PRICE);
        mark = bound(mark, 1, MAX_PRICE);
        int256 pnl = PositionMath.unrealizedPnl(size, entry, mark);
        if (mark < entry) assertGe(pnl, 0);
        else if (mark > entry) assertLe(pnl, 0);
        else assertEq(pnl, 0);
    }

    function testFuzz_Pnl_SymmetricInSize(int256 size, uint256 entry, uint256 mark) public pure {
        size = bound(size, -MAX_SIZE, MAX_SIZE);
        entry = bound(entry, 1, MAX_PRICE);
        mark = bound(mark, 1, MAX_PRICE);
        // Flipping size flips sign of PnL.
        int256 pnlA = PositionMath.unrealizedPnl(size, entry, mark);
        int256 pnlB = PositionMath.unrealizedPnl(-size, entry, mark);
        assertEq(pnlA, -pnlB);
    }

    // ------------------------------------------------------------------------------------------
    // equity
    // ------------------------------------------------------------------------------------------

    function test_Equity_PositivePnl() public pure {
        assertEq(PositionMath.equity(100e18, int256(50e18)), int256(150e18));
    }

    function test_Equity_NegativePnlGoesNegative() public pure {
        assertEq(PositionMath.equity(50e18, -int256(75e18)), -int256(25e18));
    }

    function testFuzz_Equity_MonotonicInCollateral(uint256 c1, uint256 c2, int256 pnl) public pure {
        c1 = bound(c1, 0, MAX_COLLATERAL);
        c2 = bound(c2, c1, MAX_COLLATERAL);
        pnl = bound(pnl, -int256(MAX_COLLATERAL), int256(MAX_COLLATERAL));
        assertGe(PositionMath.equity(c2, pnl), PositionMath.equity(c1, pnl));
    }

    // ------------------------------------------------------------------------------------------
    // marginRatioBps
    // ------------------------------------------------------------------------------------------

    function test_MarginRatio_NegativeEquityReturnsZero() public pure {
        assertEq(PositionMath.marginRatioBps(-int256(1), 100e18), 0);
    }

    function test_MarginRatio_ZeroEquityReturnsZero() public pure {
        assertEq(PositionMath.marginRatioBps(0, 100e18), 0);
    }

    function test_MarginRatio_ZeroNotionalReturnsZero() public pure {
        assertEq(PositionMath.marginRatioBps(int256(1e18), 0), 0);
    }

    function test_MarginRatio_KnownValue() public pure {
        // equity $20, notional $100 → 20% = 2000 bps
        assertEq(PositionMath.marginRatioBps(int256(20e18), 100e18), 2000);
    }

    function testFuzz_MarginRatio_NeverExceedsImpliedCap(int256 eq, uint256 notional_) public pure {
        eq = bound(eq, 0, int256(MAX_COLLATERAL));
        notional_ = bound(notional_, 1, MAX_PRICE);
        // ratio × notional / 10_000 ≤ equity (modulo rounding by 1)
        uint256 ratio = PositionMath.marginRatioBps(eq, notional_);
        assertLe((ratio * notional_) / PositionMath.BPS_DENOMINATOR, uint256(eq));
    }

    // ------------------------------------------------------------------------------------------
    // leverageBps
    // ------------------------------------------------------------------------------------------

    function test_Leverage_RevertOnZeroCollateral() public {
        vm.expectRevert(PositionMath.CollateralNotPositive.selector);
        harness.leverageBps(100e18, 0);
    }

    function test_Leverage_KnownValue() public pure {
        // notional $100, collateral $20 → 5× = 50_000 bps
        assertEq(PositionMath.leverageBps(100e18, 20e18), 50_000);
    }

    function test_Leverage_OneXOnEqualValues() public pure {
        assertEq(PositionMath.leverageBps(50e18, 50e18), 10_000);
    }

    function testFuzz_Leverage_RoundtripsAgainstNotional(uint256 notional_, uint256 collat) public pure {
        notional_ = bound(notional_, 1, MAX_COLLATERAL);
        collat = bound(collat, 1, MAX_COLLATERAL);
        uint256 lev = PositionMath.leverageBps(notional_, collat);
        // (lev × collateral) / 10_000 ≤ notional, with at most a 1-wei loss to integer rounding
        uint256 reconstructed = (lev * collat) / PositionMath.BPS_DENOMINATOR;
        assertLe(reconstructed, notional_);
        // and the rounding gap is bounded — the lost part is at most (collateral - 1) wei
        if (notional_ >= collat) {
            assertGe(reconstructed + collat, notional_);
        }
    }

    // ------------------------------------------------------------------------------------------
    // composite scenarios — open/close/mark-move flows the way PerpEngine will use the lib
    // ------------------------------------------------------------------------------------------

    function test_Scenario_DrakeWeek() public pure {
        // Spec §2 worked example: open at $187.42 with $50K notional. Mark moves to $203.96. Compute uPnL.
        uint256 entry = 187.42e18;
        uint256 mark = 203.96e18;
        // size = 50_000e18 / 187.42e18 (in 1e18 fixed) = ~266.78e18
        int256 size = int256((50_000e18 * 1e18) / entry);
        int256 pnl = PositionMath.unrealizedPnl(size, entry, mark);
        // expected ≈ 266.78 × ($203.96 - $187.42) = 266.78 × $16.54 ≈ $4,412.34
        assertApproxEqAbs(pnl, int256(4_412e18), 5e18);
    }
}
