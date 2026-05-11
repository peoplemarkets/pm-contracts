// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {LiquidationMath} from "../src/libraries/LiquidationMath.sol";

/// @dev External harness exposing each internal pure on the library at external-pure visibility so
///      `vm.expectRevert` can observe the revert at a call depth strictly deeper than the cheatcode.
///      Without the harness the library calls inline into the test contract and expectRevert no
///      longer catches them.
contract Harness {
    function partialInc(
        int256 currentSize,
        uint256 currentCollateral,
        uint256 markPrice,
        uint256 entryPrice,
        uint16 partialIncrementBps,
        uint16 liquidatorBountyBps,
        uint16 maintenanceMarginBps,
        uint16 mmRestoreBufferBps
    )
        external
        pure
        returns (LiquidationMath.PartialResult memory)
    {
        return LiquidationMath.computePartialIncrement(
            currentSize,
            currentCollateral,
            markPrice,
            entryPrice,
            partialIncrementBps,
            liquidatorBountyBps,
            maintenanceMarginBps,
            mmRestoreBufferBps
        );
    }

    function full(
        int256 currentSize,
        uint256 currentCollateral,
        uint256 markPrice,
        uint256 entryPrice,
        uint16 fullLiquidationBountyBps
    )
        external
        pure
        returns (LiquidationMath.FullResult memory)
    {
        return LiquidationMath.computeFullLiquidation(
            currentSize, currentCollateral, markPrice, entryPrice, fullLiquidationBountyBps
        );
    }

    function adl(
        int256 size,
        uint256 entryPrice,
        uint256 markPrice,
        uint256 currentCollateral
    )
        external
        pure
        returns (uint256)
    {
        return LiquidationMath.adlPriority(size, entryPrice, markPrice, currentCollateral);
    }

    function underMM(
        int256 size,
        uint256 collateral,
        uint256 markPrice,
        uint256 entryPrice,
        uint16 mmBps
    )
        external
        pure
        returns (bool)
    {
        return LiquidationMath.isUnderMaintenance(size, collateral, markPrice, entryPrice, mmBps);
    }

    function underBuf(
        int256 size,
        uint256 collateral,
        uint256 markPrice,
        uint256 entryPrice,
        uint16 mmBps,
        uint16 bufBps
    )
        external
        pure
        returns (bool)
    {
        return LiquidationMath.isUnderLiquidationBuffer(size, collateral, markPrice, entryPrice, mmBps, bufBps);
    }
}

/// @dev Tests target 100% line/branch coverage on src/libraries/LiquidationMath.sol.
///
///      Unit recap (matches the library's NatSpec):
///        - size: signed 1e6-fixed contracts. 10 contracts = 10_000_000.
///        - mark / entry: 1e18 fixed. $100 = 100e18.
///        - collateral / notional / bounty: 6-decimal USDC. $1_000 = 1_000e6 = 1_000_000_000.
///        - PnL: signed 6-decimal USDC.
///        - bps: /10_000. 5% MM = 500.
contract LiquidationMathTest is Test {
    Harness internal h = new Harness();

    /// @dev Practical fuzz upper bounds. 1e18 contracts × 1e24 mark = 1e42, divided by 1e18 gives
    ///      1e24 USDC — well inside uint256 and large enough to stress real-world ranges.
    int256 internal constant MAX_SIZE = int256(1e18);
    uint256 internal constant MAX_PRICE = 1e24;
    uint256 internal constant MAX_COLLATERAL = 1e24;

    // ===========================================================================================
    // computePartialIncrement
    // ===========================================================================================

    // ----- guard reverts ------------------------------------------------------------------------

    function test_Partial_RevertOnZeroMark() public {
        vm.expectRevert(LiquidationMath.MarkNotPositive.selector);
        h.partialInc(int256(10_000_000), 1_000e6, 0, 100e18, 2_500, 100, 500, 100);
    }

    function test_Partial_RevertOnZeroEntry() public {
        vm.expectRevert(LiquidationMath.EntryPriceNotPositive.selector);
        h.partialInc(int256(10_000_000), 1_000e6, 100e18, 0, 2_500, 100, 500, 100);
    }

    function test_Partial_RevertOnZeroSize() public {
        vm.expectRevert(LiquidationMath.ZeroSize.selector);
        h.partialInc(int256(0), 1_000e6, 100e18, 100e18, 2_500, 100, 500, 100);
    }

    function test_Partial_RevertOnZeroIncrement() public {
        vm.expectRevert(LiquidationMath.BpsOutOfRange.selector);
        h.partialInc(int256(10_000_000), 1_000e6, 100e18, 100e18, 0, 100, 500, 100);
    }

    function test_Partial_RevertOnIncrementAbove10000() public {
        vm.expectRevert(LiquidationMath.BpsOutOfRange.selector);
        h.partialInc(int256(10_000_000), 1_000e6, 100e18, 100e18, 10_001, 100, 500, 100);
    }

    function test_Partial_RevertOnBountyAbove10000() public {
        vm.expectRevert(LiquidationMath.BpsOutOfRange.selector);
        h.partialInc(int256(10_000_000), 1_000e6, 100e18, 100e18, 2_500, 10_001, 500, 100);
    }

    function test_Partial_RevertOnMmAbove10000() public {
        vm.expectRevert(LiquidationMath.BpsOutOfRange.selector);
        h.partialInc(int256(10_000_000), 1_000e6, 100e18, 100e18, 2_500, 100, 10_001, 100);
    }

    function test_Partial_RevertOnBufferAbove10000() public {
        vm.expectRevert(LiquidationMath.BpsOutOfRange.selector);
        h.partialInc(int256(10_000_000), 1_000e6, 100e18, 100e18, 2_500, 100, 500, 10_001);
    }

    // ----- profitable long partial -------------------------------------------------------------
    // 10 contracts long, entry $100 → notional $1_000, collateral $200 (5× leverage approximate).
    // Mark moves to $110 (+10% mark). Slice 25%.

    function test_Partial_LongProfitable_25pct() public view {
        LiquidationMath.PartialResult memory r =
            h.partialInc(int256(10_000_000), 200e6, 110e18, 100e18, 2_500, 100, 500, 100);

        // reducedSizeAbs = 10_000_000 × 0.25 = 2_500_000, signed +
        assertEq(r.reducedSize, int256(2_500_000));
        // reducedNotional6 = 2_500_000 × 110e18 / 1e18 = 275_000_000 (6-dec USDC = $275)
        // bounty = $275 × 0.01 = $2.75 ⇒ 2_750_000
        assertEq(r.bountyToLiquidator, 2_750_000);
        // pnlOnSlice6 = +2_500_000 × (110−100)e18 / 1e18 = 25_000_000 ($25 profit)
        // sliceCollateral = $200 × 0.25 = $50 ⇒ 50_000_000
        // freedPool = 50 + 25 − 2.75 = 72.25 ⇒ 72_250_000
        // Then MM-restore check: remainingSizeAbs = 7_500_000, remNotional = $825, remReq = $825×(5%+1%) = $49.5,
        // remAvail = $200 − $50 = $150 ⇒ no top-up needed.
        assertEq(r.collateralFreed, 72_250_000);
        assertEq(r.markPrice, 110e18);
    }

    // ----- losing long partial -----------------------------------------------------------------
    // Same 10 contracts at entry $100, mark drops to $96. Slice 25%, collateral $50 (tight).

    function test_Partial_LongLosing_25pct() public view {
        LiquidationMath.PartialResult memory r =
            h.partialInc(int256(10_000_000), 50e6, 96e18, 100e18, 2_500, 100, 500, 100);

        // reducedSize = +2_500_000
        // reducedNotional6 = 2_500_000 × 96 = 240_000_000 ⇒ $240
        // bounty = $240 × 0.01 = $2.4 ⇒ 2_400_000
        // pnlOnSlice6 = +2_500_000 × (96−100)e18 / 1e18 = −10_000_000 ($10 loss)
        // sliceCollateral = $50 × 0.25 = $12.5 ⇒ 12_500_000
        // freedPool = 12.5 − 10 − 2.4 = +0.1 ⇒ 100_000
        assertEq(r.reducedSize, int256(2_500_000));
        assertEq(r.bountyToLiquidator, 2_400_000);
        // Remaining: 7_500_000 × 96 = $720 notional, req = $720 × 6% = $43.2, avail = $50 − $12.5 = $37.5
        // shortfall = $43.2 − $37.5 = $5.7. freedPool ($0.1) < topUp ⇒ collateralFreed = 0.
        assertEq(r.collateralFreed, 0);
    }

    // ----- profitable short partial ------------------------------------------------------------
    // Short 10 contracts entry $100 → mark $90 = +$10 per contract profit.

    function test_Partial_ShortProfitable_25pct() public view {
        LiquidationMath.PartialResult memory r =
            h.partialInc(-int256(10_000_000), 200e6, 90e18, 100e18, 2_500, 100, 500, 100);

        assertEq(r.reducedSize, -int256(2_500_000));
        // reducedNotional6 = 2_500_000 × 90 = 225_000_000 ⇒ $225, bounty = $2.25 ⇒ 2_250_000
        assertEq(r.bountyToLiquidator, 2_250_000);
        // pnlOnSlice6 = −2_500_000 × (90−100)e18 / 1e18 = −2_500_000 × −10 = +25_000_000 ($25)
        // sliceColl = $200×0.25 = $50. freedPool = 50 + 25 − 2.25 = $72.75 ⇒ 72_750_000
        assertEq(r.collateralFreed, 72_750_000);
    }

    // ----- losing short partial ----------------------------------------------------------------
    // Short 10 contracts entry $100, mark $110 = −$10 per contract loss.

    function test_Partial_ShortLosing_25pct() public view {
        LiquidationMath.PartialResult memory r =
            h.partialInc(-int256(10_000_000), 200e6, 110e18, 100e18, 2_500, 100, 500, 100);

        assertEq(r.reducedSize, -int256(2_500_000));
        // reducedNotional6 = 2_500_000 × 110 = $275, bounty = $2.75
        assertEq(r.bountyToLiquidator, 2_750_000);
        // pnlOnSlice = −2_500_000 × (110−100) / 1e18 = −25_000_000 ($25 loss)
        // sliceColl = $50. freedPool = 50 − 25 − 2.75 = $22.25 ⇒ 22_250_000
        // Remaining: 7_500_000 × 110 = $825 notional, req = $825 × 6% = $49.5, avail = $150 ⇒ ok.
        assertEq(r.collateralFreed, 22_250_000);
    }

    // ----- full close via partialIncrementBps == 10_000 ----------------------------------------

    function test_Partial_FullCloseViaTenThousandBps() public view {
        // 10 contracts long, entry $100, mark $110, collateral $200, 1% bounty.
        LiquidationMath.PartialResult memory partial_ =
            h.partialInc(int256(10_000_000), 200e6, 110e18, 100e18, 10_000, 100, 500, 100);
        LiquidationMath.FullResult memory full_ = h.full(int256(10_000_000), 200e6, 110e18, 100e18, 100);

        assertEq(partial_.reducedSize, full_.closedSize);
        assertEq(partial_.bountyToLiquidator, full_.bountyToLiquidator);
        assertEq(partial_.collateralFreed, full_.collateralReturned);
    }

    // ----- MM-restore insufficient -------------------------------------------------------------
    // Long 10 contracts entry $100, mark $100 (zero PnL), collateral $40, slice 10%, MM 25%, buffer 0.
    // Slice: notional = 1_000_000 × 100 / 1e18 = $100 ⇒ bounty 1% = $1.00 ⇒ 1_000_000.
    // sliceColl = $40 × 0.10 = $4. pnl = 0. freedPoolInt = $4 − $1 = $3 ⇒ collateralFreed = 3_000_000.
    // Remaining: 9_000_000 × $100 = $900 notional. Required @ 25% = $225. Avail = $40 − $4 = $36.
    // topUp = $189 ≫ freedPool ⇒ MM-restore insufficient ⇒ collateralFreed = 0; bounty still paid.

    function test_Partial_MmRestoreInsufficient() public view {
        LiquidationMath.PartialResult memory r =
            h.partialInc(int256(10_000_000), 40e6, 100e18, 100e18, 1_000, 100, 2_500, 0);

        assertEq(r.collateralFreed, 0);
        assertEq(r.bountyToLiquidator, 1_000_000);
    }

    // ----- MM-restore: partial top-up succeeds (covers the `>= topUp` branch) ------------------
    // Long 10c entry $100, mark $100, collateral $100, slice 25%, MM 10%, buffer 0.
    // slice notional = $250, bounty 1% = $2.50. sliceColl = $25, pnl = 0. freedPool = $25 − $2.50 = $22.50.
    // Remaining notional = 7.5 × $100 = $750, req = 10% = $75, avail = $100 − $25 = $75 ⇒ no top-up.

    function test_Partial_MmRestore_NoTopUpNeeded() public view {
        LiquidationMath.PartialResult memory r =
            h.partialInc(int256(10_000_000), 100e6, 100e18, 100e18, 2_500, 100, 1_000, 0);
        assertEq(r.collateralFreed, 22_500_000);
        assertEq(r.bountyToLiquidator, 2_500_000);
    }

    // ----- MM-restore: partial top-up partially absorbs freed --------------------------------
    // Long 10c entry $100, mark $100, collateral $100, slice 25%, MM 10%, buffer 200 (2%) ⇒ totalReqBps 12%.
    // Required = 7.5 × 100 × 0.12 = $90, avail = $75 ⇒ topUp $15. freedPool = $22.5 − $15 = $7.5.

    function test_Partial_MmRestore_TopUpAbsorbsSomeFreed() public view {
        LiquidationMath.PartialResult memory r =
            h.partialInc(int256(10_000_000), 100e6, 100e18, 100e18, 2_500, 100, 1_000, 200);
        assertEq(r.collateralFreed, 7_500_000);
        assertEq(r.bountyToLiquidator, 2_500_000);
    }

    // ----- zero realized PnL slice -------------------------------------------------------------

    function test_Partial_ZeroRealizedPnl() public view {
        // mark == entry ⇒ no PnL. slice 25%, bounty 1%. collat $100. slice notional $250 ⇒ bounty $2.50.
        // sliceColl $25, freedPool $25 − $2.50 = $22.50.
        LiquidationMath.PartialResult memory r =
            h.partialInc(int256(10_000_000), 100e6, 100e18, 100e18, 2_500, 100, 500, 0);
        assertEq(r.bountyToLiquidator, 2_500_000);
        assertEq(r.collateralFreed, 22_500_000);
    }

    // ----- zero bounty bps ---------------------------------------------------------------------

    function test_Partial_ZeroBountyBps() public view {
        // bountyBps = 0 ⇒ freed = sliceCollateral + pnl. mark $110 entry $100 collat $200 slice 25%
        // pnl = $25. sliceColl = $50. freed = $75 ⇒ 75_000_000.
        LiquidationMath.PartialResult memory r =
            h.partialInc(int256(10_000_000), 200e6, 110e18, 100e18, 2_500, 0, 500, 100);
        assertEq(r.bountyToLiquidator, 0);
        assertEq(r.collateralFreed, 75_000_000);
    }

    // ----- freedPool exactly zero (lands in `<= 0` branch with fundable > 0) ------------------
    // Construct slice where sliceColl + pnl − bounty == 0.
    // long 10c entry $100 mark $100 collat $200 slice 25% bountyBps 2500 (25%).
    // slice notional $250, bounty = $250×25% = $62.5. sliceColl = $50. pnl = 0. freedPool = 50 − 62.5 = −12.5.
    // fundable = sliceColl + pnl = $50. So bounty becomes $50, freed=0.

    function test_Partial_FreedPoolNegative_FundableCapsBounty() public view {
        LiquidationMath.PartialResult memory r =
            h.partialInc(int256(10_000_000), 200e6, 100e18, 100e18, 2_500, 2_500, 500, 100);
        assertEq(r.collateralFreed, 0);
        assertEq(r.bountyToLiquidator, 50_000_000);
    }

    // ----- freedPool negative AND fundable negative (e.g. big loss) ----------------------------
    // long 10c entry $100, mark $50 (−50%), collat $20 (tiny), slice 25%, bounty 1%.
    // slice notional = $125 ⇒ bounty target $1.25.
    // pnl = +2_500_000 × (50−100) / 1e18 = −125_000_000 = −$125.
    // sliceColl = $5. fundable = $5 + (−$125) = −$120 ⇒ bounty = 0, freed = 0.

    function test_Partial_FundableNegative_BountyZero() public view {
        LiquidationMath.PartialResult memory r =
            h.partialInc(int256(10_000_000), 20e6, 50e18, 100e18, 2_500, 100, 500, 100);
        assertEq(r.collateralFreed, 0);
        assertEq(r.bountyToLiquidator, 0);
    }

    // ===========================================================================================
    // computeFullLiquidation
    // ===========================================================================================

    function test_Full_RevertOnZeroMark() public {
        vm.expectRevert(LiquidationMath.MarkNotPositive.selector);
        h.full(int256(10_000_000), 200e6, 0, 100e18, 100);
    }

    function test_Full_RevertOnZeroEntry() public {
        vm.expectRevert(LiquidationMath.EntryPriceNotPositive.selector);
        h.full(int256(10_000_000), 200e6, 100e18, 0, 100);
    }

    function test_Full_RevertOnZeroSize() public {
        vm.expectRevert(LiquidationMath.ZeroSize.selector);
        h.full(int256(0), 200e6, 100e18, 100e18, 100);
    }

    function test_Full_RevertOnBountyAbove10000() public {
        vm.expectRevert(LiquidationMath.BpsOutOfRange.selector);
        h.full(int256(10_000_000), 200e6, 100e18, 100e18, 10_001);
    }

    // ----- Case A — solvent close -------------------------------------------------------------
    // long 10c entry $100 mark $110, collat $200, bounty 1%.
    // notional6 = $1_100. bountyTarget = $11. pnl = +$100. equity = $200 + $100 = $300.
    // bounty paid = $11, returned = $300 − $11 = $289.

    function test_Full_CaseA_Solvent() public view {
        LiquidationMath.FullResult memory r = h.full(int256(10_000_000), 200e6, 110e18, 100e18, 100);
        assertEq(r.bountyToLiquidator, 11_000_000);
        assertEq(r.collateralReturned, 289_000_000);
        assertEq(r.shortfall, 0);
        assertEq(r.closedSize, int256(10_000_000));
        assertEq(r.markPrice, 110e18);
    }

    // ----- Case B — equity exactly equals bounty target ----------------------------------------
    // We need int256(collateral) + pnl == int256(bountyTarget).
    // long 10c entry $100 mark $90 ⇒ notional6 = $900, pnl = −$100.
    // pick bountyBps such that bountyTarget = collateral + pnl. Try collateral = $110 ⇒ equity = $10.
    // need bountyTarget = $10 ⇒ bountyBps × $900 / 10_000 = $10 ⇒ bountyBps = 111.11... not exact.
    // Try collateral $100, equity = $0 — case C (equity == 0 hits the `else`). We want B with equity == target.
    // Use mark $99 entry $100, 10c. notional = $990, pnl = −$10. equity = collat − $10.
    // bountyBps 100 ⇒ bountyTarget = $9.9. Pick collat = $19.9 ⇒ equity = $9.9 == target.

    function test_Full_CaseB_EquityEqualsBounty() public view {
        // 19.9e6 collat, mark 99, entry 100, 10c, 1% bounty.
        LiquidationMath.FullResult memory r = h.full(int256(10_000_000), 19_900_000, 99e18, 100e18, 100);
        // notional6 = 10_000_000 × 99e18 / 1e18 = 990_000_000 = $990.
        // bountyTarget = 9_900_000.
        // pnl = +10_000_000 × (−1) = −10_000_000.
        // equity = 19_900_000 + (−10_000_000) = 9_900_000.
        assertEq(r.bountyToLiquidator, 9_900_000);
        assertEq(r.collateralReturned, 0);
        assertEq(r.shortfall, 0);
    }

    // ----- Case B — equity > 0 but less than bounty target --------------------------------------
    // long 10c entry $100, mark $95 ⇒ notional $950, pnl = −$50. collat $55 ⇒ equity $5.
    // bountyBps 100 ⇒ target = $9.5. shortfall = $4.5.

    function test_Full_CaseB_EquityBelowBountyTarget() public view {
        LiquidationMath.FullResult memory r = h.full(int256(10_000_000), 55e6, 95e18, 100e18, 100);
        assertEq(r.bountyToLiquidator, 5_000_000);
        assertEq(r.collateralReturned, 0);
        assertEq(r.shortfall, int256(4_500_000));
    }

    // ----- Case C — equity exactly 0 -----------------------------------------------------------
    // collat == |pnl|. long 10c entry $100 mark $90 ⇒ pnl = −$100. collat $100 ⇒ equity 0.
    // bountyBps 100 ⇒ target = $9. shortfall = $9.

    function test_Full_CaseC_EquityZero() public view {
        LiquidationMath.FullResult memory r = h.full(int256(10_000_000), 100e6, 90e18, 100e18, 100);
        assertEq(r.bountyToLiquidator, 0);
        assertEq(r.collateralReturned, 0);
        assertEq(r.shortfall, int256(9_000_000));
    }

    // ----- Case C — equity strictly negative (wipeout) -----------------------------------------
    // long 10c entry $100 mark $50 (−50%) collat $20.
    // notional = $500, pnl = −$500, equity = $20 + (−$500) = −$480.
    // bountyBps 100 ⇒ target $5. shortfall = $5 − (−$480) = $485.

    function test_Full_CaseC_Wipeout() public view {
        LiquidationMath.FullResult memory r = h.full(int256(10_000_000), 20e6, 50e18, 100e18, 100);
        assertEq(r.bountyToLiquidator, 0);
        assertEq(r.collateralReturned, 0);
        assertEq(r.shortfall, int256(485_000_000));
    }

    // ----- short, case A ----------------------------------------------------------------------

    function test_Full_Short_CaseA() public view {
        // short 10c entry $100 mark $90 ⇒ notional $900, pnl +$100, collat $200, bounty 1% = $9.
        // equity = $300. returned = $291.
        LiquidationMath.FullResult memory r = h.full(-int256(10_000_000), 200e6, 90e18, 100e18, 100);
        assertEq(r.bountyToLiquidator, 9_000_000);
        assertEq(r.collateralReturned, 291_000_000);
        assertEq(r.shortfall, 0);
    }

    // ===========================================================================================
    // adlPriority
    // ===========================================================================================

    function test_Adl_RevertOnZeroMark() public {
        vm.expectRevert(LiquidationMath.MarkNotPositive.selector);
        h.adl(int256(10_000_000), 100e18, 0, 100e6);
    }

    function test_Adl_RevertOnZeroEntry() public {
        vm.expectRevert(LiquidationMath.EntryPriceNotPositive.selector);
        h.adl(int256(10_000_000), 0, 100e18, 100e6);
    }

    function test_Adl_ZeroSizeReturnsZero() public view {
        assertEq(h.adl(0, 100e18, 110e18, 100e6), 0);
    }

    function test_Adl_ZeroCollateralReturnsMax() public view {
        assertEq(h.adl(int256(10_000_000), 100e18, 110e18, 0), type(uint256).max);
    }

    function test_Adl_PositionsOrderedByPriority() public view {
        // p1: 10c long entry $100 mark $110, collat $50 ⇒ upnl=$100, notional=$1_100, lev=22 ⇒ key=$2_200
        // p2: 10c long entry $100 mark $110, collat $100 ⇒ upnl=$100, lev=11 ⇒ key=$1_100
        // p3: 10c long entry $100 mark $105, collat $100 ⇒ upnl=$50, lev=10.5 ⇒ key=$525
        uint256 p1 = h.adl(int256(10_000_000), 100e18, 110e18, 50e6);
        uint256 p2 = h.adl(int256(10_000_000), 100e18, 110e18, 100e6);
        uint256 p3 = h.adl(int256(10_000_000), 100e18, 105e18, 100e6);
        assertGt(p1, p2);
        assertGt(p2, p3);
    }

    function test_Adl_IdenticalPositionsIdenticalPriority() public view {
        uint256 a = h.adl(int256(10_000_000), 100e18, 120e18, 200e6);
        uint256 b = h.adl(int256(10_000_000), 100e18, 120e18, 200e6);
        assertEq(a, b);
    }

    function test_Adl_LossPositionStillRanksByAbsPnl() public view {
        // |pnl| × leverage — losses count too.
        // long 10c entry $100 mark $90 collat $50: upnl = −$100 ⇒ |upnl|=$100. notional=$900. lev=18. key=$1_800.
        // long 10c entry $100 mark $110 collat $50: as above ⇒ $2_200.
        uint256 loss = h.adl(int256(10_000_000), 100e18, 90e18, 50e6);
        uint256 gain = h.adl(int256(10_000_000), 100e18, 110e18, 50e6);
        assertGt(gain, loss);
    }

    // ===========================================================================================
    // isUnderMaintenance
    // ===========================================================================================

    function test_UnderMM_RevertOnZeroMark() public {
        vm.expectRevert(LiquidationMath.MarkNotPositive.selector);
        h.underMM(int256(10_000_000), 100e6, 0, 100e18, 500);
    }

    function test_UnderMM_RevertOnZeroEntry() public {
        vm.expectRevert(LiquidationMath.EntryPriceNotPositive.selector);
        h.underMM(int256(10_000_000), 100e6, 100e18, 0, 500);
    }

    function test_UnderMM_RevertOnBpsTooHigh() public {
        vm.expectRevert(LiquidationMath.BpsOutOfRange.selector);
        h.underMM(int256(10_000_000), 100e6, 100e18, 100e18, 10_001);
    }

    function test_UnderMM_ZeroSizeFalse() public view {
        assertEq(h.underMM(0, 100e6, 100e18, 100e18, 500), false);
    }

    function test_UnderMM_AboveThresholdFalse() public view {
        // 10c entry $100 mark $100 collat $200 ⇒ equity $200, notional $1_000, MM 5% = $50. equity > $50 ⇒ false.
        assertEq(h.underMM(int256(10_000_000), 200e6, 100e18, 100e18, 500), false);
    }

    function test_UnderMM_AtThresholdFalseStrict() public view {
        // equity == mm. notional $1_000, MM 5% = $50. mark==entry ⇒ pnl 0. collat $50 ⇒ equity $50 == mm. Strict <.
        assertEq(h.underMM(int256(10_000_000), 50e6, 100e18, 100e18, 500), false);
    }

    function test_UnderMM_BelowThresholdTrue() public view {
        // collat $49.99 ⇒ equity < $50 ⇒ true.
        assertEq(h.underMM(int256(10_000_000), 49_999_999, 100e18, 100e18, 500), true);
    }

    function test_UnderMM_ShortAboveEntryIsUnderwater() public view {
        // short 10c entry $100 mark $110, collat $50.
        // notional = $1_100. pnl = −10_000_000 × 10 / 1e18 = … signed = (−10_000_000) × (110−100) e18 / 1e18 = −100_000_000 = −$100.
        // equity = $50 − $100 = −$50. mm = $55. Strict less than ⇒ true.
        assertEq(h.underMM(-int256(10_000_000), 50e6, 110e18, 100e18, 500), true);
    }

    function test_UnderMM_ZeroMmBps() public view {
        // mmBps = 0 ⇒ threshold = 0. equity must be strictly negative to trip.
        // 10c long entry $100 mark $100 collat 0 ⇒ equity 0. equity < 0 ? no ⇒ false.
        assertEq(h.underMM(int256(10_000_000), 0, 100e18, 100e18, 0), false);
        // equity strictly negative ⇒ true
        assertEq(h.underMM(int256(10_000_000), 0, 90e18, 100e18, 0), true);
    }

    function test_UnderMM_BpsTenThousand() public view {
        // mmBps = 10_000 ⇒ threshold = notional. equity < notional almost always at low leverage.
        // 10c entry $100 mark $100 collat $200 ⇒ equity $200, notional $1_000. $200 < $1_000 ⇒ true.
        assertEq(h.underMM(int256(10_000_000), 200e6, 100e18, 100e18, 10_000), true);
    }

    // ===========================================================================================
    // isUnderLiquidationBuffer
    // ===========================================================================================

    function test_UnderBuf_RevertOnZeroMark() public {
        vm.expectRevert(LiquidationMath.MarkNotPositive.selector);
        h.underBuf(int256(10_000_000), 100e6, 0, 100e18, 500, 100);
    }

    function test_UnderBuf_RevertOnZeroEntry() public {
        vm.expectRevert(LiquidationMath.EntryPriceNotPositive.selector);
        h.underBuf(int256(10_000_000), 100e6, 100e18, 0, 500, 100);
    }

    function test_UnderBuf_RevertOnMmTooHigh() public {
        vm.expectRevert(LiquidationMath.BpsOutOfRange.selector);
        h.underBuf(int256(10_000_000), 100e6, 100e18, 100e18, 10_001, 100);
    }

    function test_UnderBuf_RevertOnBufTooHigh() public {
        vm.expectRevert(LiquidationMath.BpsOutOfRange.selector);
        h.underBuf(int256(10_000_000), 100e6, 100e18, 100e18, 500, 10_001);
    }

    function test_UnderBuf_RevertOnSumOver10000() public {
        vm.expectRevert(LiquidationMath.BpsOutOfRange.selector);
        h.underBuf(int256(10_000_000), 100e6, 100e18, 100e18, 6_000, 5_000);
    }

    function test_UnderBuf_ZeroSizeFalse() public view {
        assertEq(h.underBuf(0, 100e6, 100e18, 100e18, 500, 100), false);
    }

    function test_UnderBuf_AboveTrue() public view {
        // 10c entry $100 mark $100 collat $50. notional $1_000. mm+buf = 5%+1% = 6%. threshold $60.
        // equity $50 < $60 ⇒ true.
        assertEq(h.underBuf(int256(10_000_000), 50e6, 100e18, 100e18, 500, 100), true);
    }

    function test_UnderBuf_AtThresholdFalse() public view {
        // collat $60 ⇒ equity $60 == threshold ⇒ strict < ⇒ false.
        assertEq(h.underBuf(int256(10_000_000), 60e6, 100e18, 100e18, 500, 100), false);
    }

    function test_UnderBuf_AboveThresholdFalse() public view {
        // collat $100 ⇒ equity $100 > $60 ⇒ false.
        assertEq(h.underBuf(int256(10_000_000), 100e6, 100e18, 100e18, 500, 100), false);
    }

    function test_UnderBuf_ZeroBpsBoundary() public view {
        // mm=0 buf=0 ⇒ threshold 0. equity strictly < 0 to trip.
        assertEq(h.underBuf(int256(10_000_000), 0, 100e18, 100e18, 0, 0), false);
        assertEq(h.underBuf(int256(10_000_000), 0, 90e18, 100e18, 0, 0), true);
    }

    // ===========================================================================================
    // Fuzz cross-checks
    // ===========================================================================================

    /// @dev Partial bounty never exceeds the slice's notional × bountyBps target.
    function testFuzz_Partial_BountyUpperBound(
        int256 size,
        uint256 collateral,
        uint256 mark,
        uint256 entry,
        uint16 incBps,
        uint16 bountyBps
    )
        public
        view
    {
        size = bound(size, 1, MAX_SIZE);
        collateral = bound(collateral, 0, MAX_COLLATERAL);
        mark = bound(mark, 1, MAX_PRICE);
        entry = bound(entry, 1, MAX_PRICE);
        incBps = uint16(bound(uint256(incBps), 1, 10_000));
        bountyBps = uint16(bound(uint256(bountyBps), 0, 10_000));

        LiquidationMath.PartialResult memory r = h.partialInc(size, collateral, mark, entry, incBps, bountyBps, 100, 0);

        uint256 reducedSizeAbs = (uint256(size) * uint256(incBps)) / 10_000;
        uint256 sliceNotional = (reducedSizeAbs * mark) / 1e18;
        uint256 bountyTarget = (sliceNotional * uint256(bountyBps)) / 10_000;
        assertLe(r.bountyToLiquidator, bountyTarget);
    }

    /// @dev Full liquidation: when collateral is huge and PnL non-negative, returned ≥ 0 and shortfall = 0.
    function testFuzz_Full_SolventReturnsNonNegative(int256 size, uint256 mark) public view {
        // long position, mark >= entry so pnl >= 0; pour in enough collateral to outrun bounty
        size = bound(size, 1, MAX_SIZE);
        mark = bound(mark, 100e18, MAX_PRICE);
        // entry $100 fixed → never above mark
        LiquidationMath.FullResult memory r = h.full(size, MAX_COLLATERAL, mark, 100e18, 100);
        assertEq(r.shortfall, 0);
    }
}
