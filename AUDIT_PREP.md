# AUDIT_PREP — Funding Settlement + Tier-5 ADL

Branch: `prod-readiness/contracts-funding-adl`
Scope of this change set: wire per-position **funding-debt settlement** into the close paths, and
implement **Liquidation Tier 5 (ADL / auto-deleveraging)** — the two production blockers flagged in
`IMPLEMENTATION_AUDIT.md` (§"Per-position settle of funding debt at close" = DEFERRED, and Tier 5 =
"MAINNET LAUNCH GATE").

> This document is written for the external auditor. Sections marked **[SIGN-OFF REQUIRED]** are
> economic/mechanism decisions where the intended spec semantics were ambiguous; the implementation
> reflects a documented best interpretation and MUST be confirmed before mainnet.

---

## 1. What changed

### A. Funding-debt settlement (`PerpEngine` / `PerpInternals`)
The cumulative funding index (`FundingStorage.cumulativeFundingIndex`, pushed by `FundingEngine`
via `pushFundingIndex`, frozen during pauses) is now **consumed** at close time. The hard-coded
`FundingSettled(..., int256(0))` stub is gone.

- `closePosition` / `closePositionFor` (`_computeCloseValues`): funding debt for the **closed
  slice** = `FundingMath.computeFundingDebt(closeSize, currentIndex, entryFundingIndex)`. It is
  folded into the signed-pnl leg passed to `LPVault.settlePosition`
  (`settlePnl = realizedPnl − fundingDebt6`). The trading PnL reported in `PositionClosed` is
  unchanged; funding is reported separately in `FundingSettled`.
- Partial closes settle funding on the **closed slice only**; the residual keeps its original
  `entryFundingIndex`, so funding over the residual's full lifetime is settled at its own close —
  no double counting, no missed accrual.
- The voluntary-close **underwater guard now includes funding**: a position pushed underwater
  purely by accrued funding cannot be voluntarily closed at the vault's expense (it must go through
  liquidation).
- `closeAtForcedSettlement` (extracted to `PerpInternals.forceSettlementClose`): settles funding
  accrued up to the pause/delist freeze, folded into the loss-capped pnl leg.

Sign convention (unchanged from the already-tested `FundingMath` library): `fundingDebt6 > 0` ⇒ the
trader **pays** funding into the LP vault; `< 0` ⇒ the trader **receives** funding from it. Verified
across all four (side × index-direction) quadrants.

### B. Tier-5 ADL (`LiquidationEngine` / `LiquidationMath` / `PerpInternals` / `PerpEngine`)
New `LiquidationEngine.adl(bytes32 badPositionId, bytes32[] counterpartyIds)`:

1. Gates: bad position must be under the liquidation buffer **and** the normal Tier 1-4 waterfall
   (insurance draw + LP socialization up to the configured cap) must be unable to absorb the
   shortfall (`ADLNotRequired` otherwise).
2. The bad position is closed at **zero equity** (`signedPnl = −collateral`, payout 0, bounty 0):
   its collateral fully absorbs the loss, so the LP books **no shortfall**.
3. Its directional size is offloaded onto keeper-supplied **profitable opposite-side** positions,
   each force-closed at the bad position's **bankruptcy price**
   (`LiquidationMath.bankruptcyPrice`) rather than the more-favourable mark. The profit the
   counterparties forego between mark and bankruptcy price is exactly what funds the would-be
   shortfall. The final counterparty is closed partially to match the bad size exactly
   (`ADLInsufficientCounterpartySize` if the supplied set is too small).
4. Counterparty closes reuse `PerpEngine.liquidateClose` at `Tier.ADL`. The
   `payout ≤ releasedCollateral` cap in `PerpInternals.liquidateClose` is lifted **only** for
   `tierCode == 5` (ADL counterparties are in profit and legitimately receive collateral + gain).

Supporting change: `closeAtForcedSettlement`'s body was moved into
`PerpInternals.forceSettlementClose` (DELEGATECALL) so `PerpEngine` stays under the 24,576-byte
EIP-170 cap after the funding + ADL additions (post-change margin ≈ 807 bytes).

### C. Not implemented (deliberately deferred — see §4)
`k_impact` (trade-driven mark price impact) and the on-chain min-event-OI sentiment floor were
assessed and **not** implemented: both are architectural changes (mark and sentiment are currently
push-only), not "wire a shipped library" tasks, and shipping half-formed versions on real-money
paths would be worse than documenting them.

---

## 2. Invariants that should hold (and should be checked by the auditor)

### Funding
- **F1 — Sign correctness.** Long + index grew ⇒ pays; short + index grew ⇒ receives; symmetric on
  negative growth. `longDebt == −shortDebt` for equal/opposite size at the same index delta.
- **F2 — Slice additivity / no double-count.** Funding settled across a sequence of partial closes
  of one position equals funding on the whole position over the union of windows (each slice is
  charged `(currentIndex − entryIndex)` at its own close; disjoint sizes ⇒ no overlap).
- **F3 — Vault conservation.** Funding paid by a trader increases LP `freeAssets` by exactly that
  amount; funding owed to a trader decreases it by exactly that amount (funding flows through the
  signed-pnl leg of `settlePosition`; no funding-specific bucket).
- **F4 — Underwater safety.** A close whose `collateral + realizedPnl − fundingDebt − fee < 0`
  reverts `UnderwaterClose` — the vault is never drained to pay funding the trader cannot cover.
- **F5 — Pause freeze.** `pushFundingIndex` is pause-aware (`requireTradeable`), so no funding
  accrues while a subject is paused/delisted; forced settlement therefore settles funding only up
  to the freeze.

### ADL
- **A1 — No LP bad debt.** Closing the bad position at zero equity books no shortfall; counterparty
  closes only ever reduce the LP's net payout. Every leg passes the vault's payout-conservation
  (`traderPayout + bounty == collateralReleased + signedPnl`) and
  `InsufficientFreeAssetsForLiquidation` guards, so **ADL cannot drive the vault negative** — at
  worst a leg reverts.
- **A2 — Size match.** Total |size| deleveraged across counterparties equals the bad position's
  |size| (final counterparty partial). The bad position is fully removed.
- **A3 — Counterparty eligibility.** Each counterparty is the same subject, opposite side,
  profitable at mark, and solvent at the bankruptcy price (else its leg reverts / it is rejected).
- **A4 — Bankruptcy-price zero-equity identity.** `collateral + size×(P_b − entry)/1e18 == 0`
  (unit-tested).
- **A5 — Justification gate.** ADL reverts unless the post-insurance socialization residual exceeds
  the configured cap.

### Pre-existing invariants that must remain intact
- The vault four-bucket sum invariant (`balance == positionCollateral + insurance + fees +
  freeAssets`) — the funding/ADL changes route only through existing settle primitives, but confirm.
- OI accounting (`totalLongOI` / `totalShortOI`, MarginEngine signed category OI + per-trader
  exposure) decremented by opening notional on every close path, including the new ADL legs.

---

## 3. [SIGN-OFF REQUIRED] — economic decisions to confirm

1. **Funding index omits a mark-price factor (HIGHEST priority).**
   `FundingMath.computeFundingDebt = size × (indexΔ) / 1e18`, where `indexΔ` is a dimensionless
   rate accumulation (`rate × elapsed / 3600`). Because stored `size = notionalUSDC × 1e18 / mark`,
   the realised funding equals `notional × rate / mark` rather than the textbook `notional × rate`.
   For a subject priced near $1 these coincide; for a subject priced at, say, $100 the charged
   funding is ~100× smaller than a "funding-on-notional" reading. **This is the existing, shipped,
   fully-unit-tested `FundingMath` convention** (see `test/FundingMath.t.sol::test_Debt_RealisticScale`,
   whose own comment computes `$0.10` for a $10K position at a 0.1% index move). This change set
   consumes that primitive faithfully and does **not** silently rescale it. Confirm whether the
   intended economics are funding-on-notional (→ the index must be multiplied by mark when
   accruing, a `FundingEngine`/`FundingMath` change with its own re-test) or funding-per-contract
   as currently implemented.

2. **Funding is settled entirely against the LP vault; the spec's 8% "funding rate take" (spec §3
   line 138) is not separately apportioned.** In this single-vault (LP = universal counterparty)
   model there is no peer-to-peer leg, so net funding accrues to / is paid by the LP in full.
   Confirm this is the intended treatment, or specify how the 8% venue take should be carved out
   (e.g. a haircut on trader-received funding, or a skim on all funding magnitude — this was an open
   question in `IMPLEMENTATION_AUDIT.md` §8).

3. **Sub-unit funding rounding.** `computeFundingDebt` truncates toward zero. On the trader-pays
   side this rounds the debt **down** (favours the trader by ≤ 1e-6 USDC); on the trader-receives
   side it rounds the magnitude down (favours the vault). The brief asked to favour the
   vault/protocol on rounding; the tested shared primitive truncates symmetrically. Magnitude is
   economically negligible (≤ 1 micro-USDC per close) but flagged for a decision on whether to add
   asymmetric rounding at the consumption site.

4. **ADL offloads the FULL bad-position size at the bankruptcy price** (not only the residual
   beyond insurance + cap). This is simpler and provably avoids LP bad debt, but deleverages more
   counterparty size than the strict "cover only the uncovered residual" reading of spec §3 line
   153 — i.e. it can be more punitive to profitable counterparties than necessary. Confirm whether
   full-size or residual-only deleveraging is intended.

5. **ADL priority ordering is trusted off-chain.** The contract validates each counterparty's
   eligibility but does **not** verify the global "highest unrealized PnL × leverage first" ordering
   (`LiquidationMath.adlPriority`) — there is no on-chain enumerable position index. A keeper must
   submit counterparties in the published front-end order. Confirm this trust assumption, or
   specify an on-chain queue/heap (the chunked-vs-heap tradeoff was the open question in
   `IMPLEMENTATION_AUDIT.md` §8).

6. **No liquidator bounty on ADL**, and **ADL does not settle funding** on the deleveraged slices
   (consistent with the existing liquidation path, which also does not settle funding — see §4).
   Confirm both.

7. **Relaxed `payout ≤ releasedCollateral` cap for `tierCode == 5`.** A buggy/compromised
   LiquidationEngine could, in principle, pass an inflated payout on an ADL leg; the vault's
   payout-conservation + freeAssets guards are the remaining authoritative checks. Confirm this is
   acceptable, or re-introduce a tighter bound specific to the ADL path.

---

## 4. Remaining deferred items (out of scope here)

- **Funding settlement on the liquidation path.** `liquidateClose` (Tiers 1-4) and the ADL legs do
  **not** settle funding. For deeply-underwater liquidations the omission is usually immaterial
  (collateral is already exhausted), but a position liquidated with a large *positive* trading PnL
  but a large funding debt would not have that funding collected. Recommend wiring
  `computeFundingDebt` into `PerpInternals.liquidateClose` as a follow-up.
- **`k_impact` (trade price-impact on mark).** Mark is intentionally push-only in v0; adding
  trade-driven impact touches open/close, slippage, the circuit breaker, and the oracle path.
  Deferred as a design item.
- **On-chain min-event-OI sentiment floor.** Sentiment is push-only (off-chain aggregator applies
  the $25K OI floor per spec §2 / §6 line 301 before pushing a single score). On-chain enforcement
  would require the FundingEngine to read per-event OI from `EventMarketFactory` and aggregate
  sentiment on-chain — a substantial feature, not wired here. The legacy
  `FundingStorage.minEventOiForSentiment` field is in a namespace the live `FundingEngine` does not
  use.
- **External audit** (human gate) — not yet performed.

---

## 5. Test results

`forge test` (reduced fuzz/invariant runs for CI speed: `FOUNDRY_FUZZ_RUNS=16`,
`FOUNDRY_INVARIANT_RUNS=8`, `FOUNDRY_INVARIANT_DEPTH=15`):

**1342 passed, 0 failed, 0 skipped** (22 suites).

New tests added by this change set:
- `test/PerpEngineFunding.t.sol` (8) — funding settlement at close / partial / forced settlement,
  sign quadrants, entry-index snapshot, underwater-by-funding guard.
- `test/LiquidationADL.t.sol` (7) — ADL happy path (matched + partial counterparty), and reverts
  (not-required, insufficient counterparty size, wrong side, not-under-buffer, non-liquidator).
- `test/LiquidationMath.t.sol` (+8) — `bankruptcyPrice` (long/short/zero-equity identity/reverts)
  and `signedPnlAt` quadrants.

Contract sizes (EIP-170): `PerpEngine` 23,769 (margin 807), `LiquidationEngine` 12,340,
`PerpInternals` (linked library) 3,626.

> NOTE: `FundingMath` is used only via internal (inlined) calls, and `PerpInternals` is the existing
> linked library — no new deploy-time library linking was introduced. Re-run the full suite at
> production fuzz settings (`profile.ci`) before audit.
