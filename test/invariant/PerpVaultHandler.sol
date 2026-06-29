// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {ILPVault} from "../../src/core/ILPVault.sol";
import {IPerpEngine} from "../../src/core/IPerpEngine.sol";
import {LPVault} from "../../src/core/LPVault.sol";
import {PerpEngine} from "../../src/core/PerpEngine.sol";

import {ISubjectRegistry} from "../../src/registry/ISubjectRegistry.sol";
import {SubjectRegistry} from "../../src/registry/SubjectRegistry.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @title PerpVaultHandler — fuzzer dispatch + ghost state for invariant tests.
/// @notice Each `h*` function is a target the Foundry fuzzer calls with bounded random inputs.
///         All contract calls are wrapped in try/catch — reverts are silently skipped (most are
///         legitimate: stale mark, capped OI, IM short, paused subject, etc.). Ghost state is
///         updated only on successful calls.
///
/// @dev    Ghost mirror posture: track per-bucket bookkeepers (positionCollateral, insurance,
///         accruedFees) explicitly; track OI both ways (running counter AND walk-recompute over a
///         per-subject position list). The bookkeeper-sum-identity invariant is the load-bearing
///         I1 check; ghost-equality on individual buckets catches bugs in either side independently.
contract PerpVaultHandler is Test {
    PerpEngine internal immutable engine;
    LPVault internal immutable vault;
    SubjectRegistry internal immutable registry;
    MockUSDC internal immutable usdc;

    address internal immutable markWriter;
    address internal immutable regGuardian;
    address internal immutable regAdmin;
    address internal immutable governance;

    address[] internal traders;
    address[] internal lps;
    bytes32[] internal subjects;

    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant ONE_18 = 1e18;
    uint256 internal constant FEE_RATE_DENOM = 1_000_000;
    uint16 internal constant TAKER_FEE_RATE = 750;
    uint8 internal constant INSURANCE_PCT = 50;
    uint16 internal constant MAX_MARK_DELTA_BPS = 2_000; // ±20% per push
    uint256 internal constant MIN_MARK = 1;
    uint256 internal constant MAX_MARK = 1e36;

    // ----- Ghost state -------------------------------------------------------------------------

    uint256 public ghostExpectedPositionCollateral;
    uint256 public ghostExpectedInsurance;
    uint256 public ghostExpectedAccruedFees;

    mapping(bytes32 => uint256) public ghostExpectedLongOI;
    mapping(bytes32 => uint256) public ghostExpectedShortOI;
    mapping(address => uint256) public ghostExpectedTraderExposure;

    bytes32[] public ghostAllPositionIds;
    mapping(bytes32 => uint256) internal _ghostPositionIndex; // 1-based; 0 means "not in list"
    mapping(bytes32 => bytes32[]) public ghostPositionsBySubject;
    mapping(bytes32 => mapping(bytes32 => uint256)) internal _ghostPositionIndexBySubject; // 1-based

    /// @dev Counters that MUST stay at 0 throughout fuzzing. Each is incremented inside a target
    ///      function only when the contract call succeeded AND a precondition that should have
    ///      blocked it was true at call time.
    uint256 public ghostStaleOpenSuccesses;
    uint256 public ghostNonActiveOpenSuccesses;

    /// @dev Diagnostic counters — useful in `afterInvariant` logs for run quality.
    uint256 public callsOpenLong;
    uint256 public callsOpenShort;
    uint256 public callsClose;
    uint256 public callsAddCollat;
    uint256 public callsRemoveCollat;
    uint256 public callsPushMark;
    uint256 public callsLpDeposit;
    uint256 public callsLpWithdraw;
    uint256 public callsAutoPause;
    uint256 public callsUnpauseAuto;
    uint256 public callsAdvanceTime;
    uint256 public callsRefreshMark;
    uint256 public callsPokeTvl;

    constructor(
        PerpEngine _engine,
        LPVault _vault,
        SubjectRegistry _registry,
        MockUSDC _usdc,
        address _markWriter,
        address _regGuardian,
        address _regAdmin,
        address _governance,
        address[] memory _traders,
        address[] memory _lps,
        bytes32[] memory _subjects
    ) {
        engine = _engine;
        vault = _vault;
        registry = _registry;
        usdc = _usdc;
        markWriter = _markWriter;
        regGuardian = _regGuardian;
        regAdmin = _regAdmin;
        governance = _governance;
        traders = _traders;
        lps = _lps;
        subjects = _subjects;
    }

    // ----- View helpers exposed for invariants -------------------------------------------------

    function ghostAllPositionIdsLength() external view returns (uint256) {
        return ghostAllPositionIds.length;
    }

    function ghostPositionsBySubjectLength(bytes32 subject) external view returns (uint256) {
        return ghostPositionsBySubject[subject].length;
    }

    function ghostPositionsBySubjectAt(bytes32 subject, uint256 i) external view returns (bytes32) {
        return ghostPositionsBySubject[subject][i];
    }

    function tradersLength() external view returns (uint256) {
        return traders.length;
    }

    function traderAt(uint256 i) external view returns (address) {
        return traders[i];
    }

    function subjectsLength() external view returns (uint256) {
        return subjects.length;
    }

    function subjectAt(uint256 i) external view returns (bytes32) {
        return subjects[i];
    }

    // ----- Internal pickers --------------------------------------------------------------------

    function _pickTrader(uint256 seed) internal view returns (address) {
        return traders[bound(seed, 0, traders.length - 1)];
    }

    function _pickLp(uint256 seed) internal view returns (address) {
        return lps[bound(seed, 0, lps.length - 1)];
    }

    function _pickSubject(uint256 seed) internal view returns (bytes32) {
        return subjects[bound(seed, 0, subjects.length - 1)];
    }

    // ----- Target functions ---------------------------------------------------------------------

    function hOpenLong(uint256 traderSeed, uint256 subjectSeed, uint256 collat, uint256 levBps) external {
        callsOpenLong++;
        _hOpen(traderSeed, subjectSeed, collat, levBps, IPerpEngine.Side.LONG);
    }

    function hOpenShort(uint256 traderSeed, uint256 subjectSeed, uint256 collat, uint256 levBps) external {
        callsOpenShort++;
        _hOpen(traderSeed, subjectSeed, collat, levBps, IPerpEngine.Side.SHORT);
    }

    function _hOpen(
        uint256 traderSeed,
        uint256 subjectSeed,
        uint256 collat,
        uint256 levBps,
        IPerpEngine.Side side
    )
        internal
    {
        address trader = _pickTrader(traderSeed);
        bytes32 subject = _pickSubject(subjectSeed);
        uint256 collateral = bound(collat, 10 * ONE_USDC, 1_000_000 * ONE_USDC);
        uint256 lev = bound(levBps, 10_000, 50_000);
        uint256 sizeNotional = (collateral * lev) / 10_000;

        (uint256 mark, uint64 markUpdatedAt) = engine.markOf(subject);
        if (mark == 0) return;

        // Pre-call snapshot for I7/I8 violation counters.
        bool wasStale = block.timestamp > uint256(markUpdatedAt) + uint256(engine.markStaleAfter());
        bool wasNonActive = registry.statusOf(subject) != ISubjectRegistry.SubjectStatus.ACTIVE
            || registry.subjectOf(subject).policyFlag != ISubjectRegistry.PolicyFlag.NONE;

        IPerpEngine.OpenParams memory p = IPerpEngine.OpenParams({
            subjectId: subject,
            side: side,
            collateralAmount: collateral,
            sizeNotional: sizeNotional,
            expectedMark: mark,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: (lev % 2 == 0)
        });

        vm.prank(trader);
        try engine.openPosition(p) returns (bytes32 newId) {
            if (wasStale) ghostStaleOpenSuccesses++;
            if (wasNonActive) ghostNonActiveOpenSuccesses++;
            _onOpenSuccess(trader, subject, side, sizeNotional, collateral, p.isMaker, newId);
        } catch {
            // skip
        }
    }

    function _onOpenSuccess(
        address trader,
        bytes32 subject,
        IPerpEngine.Side side,
        uint256 sizeNotional,
        uint256 collateral,
        bool isMaker,
        bytes32 newId
    )
        internal
    {
        // Mirror PerpEngine._computeFees and the vault's bucket math.
        uint256 rate = isMaker ? 250 : TAKER_FEE_RATE;
        uint256 fee = (sizeNotional * rate) / FEE_RATE_DENOM;
        uint256 lpRebate = (fee * uint256(engine.lpRebatePct())) / 100;
        uint256 insurance = (fee * INSURANCE_PCT) / 100;
        uint256 residual = fee - lpRebate - insurance;

        ghostExpectedPositionCollateral += collateral;
        ghostExpectedInsurance += insurance;
        ghostExpectedAccruedFees += residual;
        // lpRebate stays in freeAssets implicitly — no ghost counter for it (we use identity-only).

        if (side == IPerpEngine.Side.LONG) {
            ghostExpectedLongOI[subject] += sizeNotional;
        } else {
            ghostExpectedShortOI[subject] += sizeNotional;
        }
        ghostExpectedTraderExposure[trader] += sizeNotional;

        ghostAllPositionIds.push(newId);
        _ghostPositionIndex[newId] = ghostAllPositionIds.length; // 1-based
        ghostPositionsBySubject[subject].push(newId);
        _ghostPositionIndexBySubject[subject][newId] = ghostPositionsBySubject[subject].length; // 1-based
    }

    function hClose(uint256 traderSeed, uint256 subjectSeed, uint256 fractionBps) external {
        callsClose++;
        address trader = _pickTrader(traderSeed);
        bytes32 subject = _pickSubject(subjectSeed);
        bytes32 positionId = engine.positionIdOf(trader, subject);
        if (positionId == bytes32(0)) return; // skip — nothing to close

        IPerpEngine.Position memory orig = engine.positionOf(positionId);
        bool isLong = orig.size > 0;
        uint256 fraction = bound(fractionBps, 1, 10_000);
        bool fullClose = fraction == 10_000;

        (uint256 mark,) = engine.markOf(subject);
        if (mark == 0) return;

        IPerpEngine.CloseParams memory p = IPerpEngine.CloseParams({
            subjectId: subject,
            sizeFractionBps: fraction,
            expectedMark: mark,
            maxSlippageBps: 100,
            deadline: uint64(block.timestamp + 1 hours),
            isMaker: (fraction % 2 == 0)
        });

        vm.prank(trader);
        try engine.closePosition(p) returns (int256) {
            // Compute opening-notional delta so we can mirror OI updates.
            int256 closeSize = fullClose ? orig.size : (orig.size * int256(fraction)) / int256(uint256(10_000));
            uint256 absCloseSize = closeSize > 0 ? uint256(closeSize) : uint256(-closeSize);
            uint256 openingNotionalDelta = (absCloseSize * orig.entryPrice) / ONE_18;
            uint256 closeNotionalAtMark = (absCloseSize * mark) / ONE_18;
            uint256 closeCollateral = fullClose ? orig.collateral : (orig.collateral * fraction) / 10_000;

            uint256 rate = p.isMaker ? 250 : TAKER_FEE_RATE;
            uint256 fee = (closeNotionalAtMark * rate) / FEE_RATE_DENOM;
            uint256 lpRebate = (fee * uint256(engine.lpRebatePct())) / 100;
            uint256 insurance = (fee * INSURANCE_PCT) / 100;
            uint256 residual = fee - lpRebate - insurance;

            ghostExpectedPositionCollateral -= closeCollateral;
            ghostExpectedInsurance += insurance;
            ghostExpectedAccruedFees += residual;

            if (isLong) {
                ghostExpectedLongOI[subject] -= openingNotionalDelta;
            } else {
                ghostExpectedShortOI[subject] -= openingNotionalDelta;
            }
            ghostExpectedTraderExposure[trader] -= openingNotionalDelta;

            if (fullClose) {
                _removePositionFromGhost(positionId, subject);
            }
        } catch {
            // skip
        }
    }

    function _removePositionFromGhost(bytes32 positionId, bytes32 subject) internal {
        // swap-and-pop on ghostAllPositionIds
        uint256 idx = _ghostPositionIndex[positionId]; // 1-based
        if (idx != 0) {
            uint256 lastIdx = ghostAllPositionIds.length;
            if (idx != lastIdx) {
                bytes32 lastId = ghostAllPositionIds[lastIdx - 1];
                ghostAllPositionIds[idx - 1] = lastId;
                _ghostPositionIndex[lastId] = idx;
            }
            ghostAllPositionIds.pop();
            delete _ghostPositionIndex[positionId];
        }
        // swap-and-pop on per-subject list
        uint256 sidx = _ghostPositionIndexBySubject[subject][positionId];
        if (sidx != 0) {
            uint256 sLast = ghostPositionsBySubject[subject].length;
            if (sidx != sLast) {
                bytes32 lastSId = ghostPositionsBySubject[subject][sLast - 1];
                ghostPositionsBySubject[subject][sidx - 1] = lastSId;
                _ghostPositionIndexBySubject[subject][lastSId] = sidx;
            }
            ghostPositionsBySubject[subject].pop();
            delete _ghostPositionIndexBySubject[subject][positionId];
        }
    }

    function hAddCollateral(uint256 traderSeed, uint256 subjectSeed, uint256 amount) external {
        callsAddCollat++;
        address trader = _pickTrader(traderSeed);
        bytes32 subject = _pickSubject(subjectSeed);
        if (engine.positionIdOf(trader, subject) == bytes32(0)) return;

        uint256 amt = bound(amount, 1 * ONE_USDC, 100_000 * ONE_USDC);
        // bound by trader's USDC balance to avoid TransferFromInsufficient
        uint256 balance = usdc.balanceOf(trader);
        if (balance == 0) return;
        if (amt > balance) amt = balance;

        vm.prank(trader);
        try engine.addCollateral(subject, amt) {
            ghostExpectedPositionCollateral += amt;
        } catch {
            // skip
        }
    }

    function hRemoveCollateral(uint256 traderSeed, uint256 subjectSeed, uint256 amount) external {
        callsRemoveCollat++;
        address trader = _pickTrader(traderSeed);
        bytes32 subject = _pickSubject(subjectSeed);
        bytes32 positionId = engine.positionIdOf(trader, subject);
        if (positionId == bytes32(0)) return;

        IPerpEngine.Position memory pos = engine.positionOf(positionId);
        if (pos.collateral <= 1) return;
        uint256 amt = bound(amount, 1, pos.collateral - 1);

        vm.prank(trader);
        try engine.removeCollateral(subject, amt) {
            ghostExpectedPositionCollateral -= amt;
        } catch {
            // skip — most reverts here are IM/leverage breaches, which are correct behavior
        }
    }

    function hPushMark(uint256 subjectSeed, int256 priceDeltaBps) external {
        callsPushMark++;
        bytes32 subject = _pickSubject(subjectSeed);
        (uint256 cur,) = engine.markOf(subject);
        if (cur == 0) cur = 100 * ONE_18;

        // Bound delta to ±20% of current
        int256 delta = int256(bound(uint256(priceDeltaBps < 0 ? -priceDeltaBps : priceDeltaBps), 0, MAX_MARK_DELTA_BPS));
        if (priceDeltaBps < 0) delta = -delta;

        int256 newMarkSigned = int256(cur) + (int256(cur) * delta) / 10_000;
        if (newMarkSigned <= 0) newMarkSigned = int256(MIN_MARK);
        uint256 newMark = uint256(newMarkSigned);
        if (newMark > MAX_MARK) newMark = MAX_MARK;

        vm.prank(markWriter);
        try engine.pushMark(subject, newMark) {
        // diagnostic only
        }
            catch {
            // skip
        }
    }

    function hRefreshMark(uint256 subjectSeed) external {
        callsRefreshMark++;
        bytes32 subject = _pickSubject(subjectSeed);
        (uint256 cur,) = engine.markOf(subject);
        if (cur == 0) cur = 100 * ONE_18;
        // Push current+1 to keep the timestamp fresh without meaningful price drift.
        uint256 newMark = cur + 1;
        if (newMark > MAX_MARK) newMark = cur - 1;
        vm.prank(markWriter);
        try engine.pushMark(subject, newMark) {} catch {}
    }

    function hLpDeposit(uint256 lpSeed, uint256 amount) external {
        callsLpDeposit++;
        address lp = _pickLp(lpSeed);
        uint256 balance = usdc.balanceOf(lp);
        if (balance == 0) return;
        uint256 amt = bound(amount, 1_000 * ONE_USDC, 5_000_000 * ONE_USDC);
        if (amt > balance) amt = balance;
        vm.prank(lp);
        try vault.deposit(amt, lp) {} catch {}
    }

    function hLpWithdraw(uint256 lpSeed, uint256 sharesBps) external {
        callsLpWithdraw++;
        address lp = _pickLp(lpSeed);
        uint256 sh = vault.balanceOf(lp);
        if (sh == 0) return;
        uint256 burn = (sh * bound(sharesBps, 1, 10_000)) / 10_000;
        if (burn == 0) return;
        vm.prank(lp);
        try vault.redeem(burn, lp, lp) {} catch {}
    }

    function hAutoPause(uint256 subjectSeed) external {
        callsAutoPause++;
        bytes32 subject = _pickSubject(subjectSeed);
        vm.prank(regGuardian);
        try registry.setAutoPaused(subject, 1) {} catch {}
    }

    function hUnpauseAuto(uint256 subjectSeed) external {
        callsUnpauseAuto++;
        bytes32 subject = _pickSubject(subjectSeed);
        // Try guardian first; falls through to permissionless if deadline elapsed.
        vm.prank(regGuardian);
        try registry.unpauseAuto(subject) {} catch {}
    }

    function hAdvanceTime(uint256 secondsBound) external {
        callsAdvanceTime++;
        uint256 sec = bound(secondsBound, 1, 25);
        vm.warp(block.timestamp + sec);
    }

    /// @dev v2-audit Fix #3 — exercise the OI cap snapshot. Most calls revert
    ///      `CappedTvlPokeTooSoon` (60s cooldown vs ~13s expected per-call time advance);
    ///      try/catch swallows. Successful calls keep the OI cap denominator in sync with
    ///      the vault's actual freeAssets after legitimate LP deposits.
    function hPokeCappedTvl() external {
        callsPokeTvl++;
        try engine.pokeCappedTvl() {} catch {}
    }
}
