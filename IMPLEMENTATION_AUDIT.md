# Implementation Audit — pm-contracts

**As of commit `afa4c35` on `main`.** Third refresh of this audit. The prior refresh (at `2a243c5`) covered Session A and the v2 `solidity-auditor` closures with 5 production contracts and 481 tests. This refresh covers the engineering push that took the protocol from "v0 scaffolding" to "v1-feature-complete except ADL + the two routers."

`forge test`: **1,179 passed, 0 failed, 0 skipped** across 18 suites.

The spec lives at `mechanismdesign.md`.

This refresh REPLACES the prior audit snapshot. The previous version is preserved in git at commit `2a243c5`.

---

## 1. Scope completed

| Path | Status | Solidity LoC* | `forge test` |
|---|---|---:|---|
| `src/libraries/PositionMath.sol` | complete · tested | 33 | pass (30 tests) |
| `src/libraries/FundingMath.sol` *(new)* | complete · tested | 70 | pass (40 tests) |
| `src/libraries/LiquidationMath.sol` *(new)* | complete · tested | 193 | pass (59 tests) |
| `src/libraries/StorageLib.sol` | 11 namespaces declared; 11 in active use | 280 | n/a |
| `src/oracle/IOracleAdapter.sol` | complete | 6 | n/a |
| `src/oracle/IOracleRouter.sol` | complete | 51 | n/a |
| `src/oracle/OracleRouter.sol` | complete · auto-degraded shipped | 151 | pass (50 tests) |
| `src/oracle/SignedFeedAdapter.sol` | complete | 248 | pass (56 tests) |
| `src/oracle/ChainlinkAdapter.sol` *(new)* | complete | 263 | pass (58 tests) |
| `src/oracle/UMAAdapter.sol` *(new)* | complete | 352 | pass (71 tests) |
| `src/registry/ISubjectRegistry.sol` | complete | 106 | n/a |
| `src/registry/SubjectRegistry.sol` | complete | 338 | pass (98 tests) |
| `src/core/IPerpEngine.sol` | complete | 230 | n/a |
| `src/core/ILPVault.sol` | complete | 161 | n/a |
| `src/core/IFundingEngine.sol` *(new)* | complete | 66 | n/a |
| `src/core/IInsuranceFund.sol` *(new)* | complete | 33 | n/a |
| `src/core/IMarginEngine.sol` *(new)* | complete | 109 | n/a |
| `src/core/ILiquidationEngine.sol` *(new)* | complete | 93 | n/a |
| `src/core/LPVault.sol` | complete · insurance migrated to standalone | 560 | pass (123 tests) |
| `src/core/PerpEngine.sol` | complete · funding stub + impulse + liquidation close + margin delegated | 778 | pass (198 tests) |
| `src/core/MarginEngine.sol` *(new)* | complete · owns MarginStorage + cap/margin checks | 360 | pass (75 tests) |
| `src/core/FundingEngine.sol` *(new)* | complete · cumulative index driver | 278 | pass (70 tests) |
| `src/core/InsuranceFund.sol` *(new)* | complete · standalone bucket with LPVault migration | 142 | pass (39 tests) |
| `src/core/LiquidationEngine.sol` *(new)* | complete · 4 of 5 tiers shipped (ADL deferred) | 359 | pass (64 tests) |
| `src/core/PauseGuardian.sol` *(new)* | complete · on-chain breaker detection | 329 | pass (52 tests) |
| `src/feedback/IFeedbackController.sol` *(new)* | complete | 85 | n/a |
| `src/feedback/FeedbackController.sol` *(new)* | complete · event-resolution → mark-impulse pipeline | 287 | pass (86 tests) |
| `test/integration/PerpVaultE2E.t.sol` | complete | n/a | pass (2 tests) |
| `test/invariant/PerpVaultHandler.sol` + `PerpVaultInvariants.t.sol` | complete | n/a | pass (8 invariants) |

*Approximate, stripping comment markers and blank lines.

**New since prior audit:** 9 contracts + 2 libraries + 4 interfaces.

**Remaining — ADL + routers + final audit:**
- `src/routers/PairTradeRouter.sol` (in flight at the time of this refresh — Wave 6B agent running).
- `src/routers/BatchRouter.sol` (queued — Wave 6C, sequential after 6B because both add `openPositionFor` to PerpEngine).
- Liquidation Tier 5 (ADL) — explicit gap in `LiquidationEngine.liquidate`; reverts `ADLNotImplemented`. **Mainnet launch gate.**
- Final `solidity-auditor` DEEP pass across the full src/ tree.

---

## 2. Spec compliance — line by line

Status legend: **identical**, **equivalent**, **deviates**, **closed** (was a deviation; resolved), **deferred**, **partial**.

### 2.1 §2 Price formation parameters (parameters table, spec lines 70–79)

| Spec | Spec value | Implementation | Status |
|---|---|---|---|
| `k_premium` | `0.0125`, range `0.005-0.025` | `FundingEngineStorage.kPremium_e18 = 1.25e16`; governance-tunable in bounds | **closed** |
| `k_sentiment` | `0.004`, range `0.001-0.010` | `kSentiment_e18 = 4e15`; tunable in bounds | **closed** |
| `k_skew` | `0.003`, range `0.001-0.008` | `kSkew_e18 = 3e15`; tunable in bounds | **closed** |
| `F_max` | `0.075%/h`, range `0.05-0.15%/h` | `fMaxPerHour_e18 = 7.5e14`; tunable in bounds | **closed** |
| Funding interval | 1 hour | Implicit — `pokeFunding` permissionless; rate is per-hour, scaled by actual elapsed | **equivalent** |
| Min event OI for sentiment | `$25K` | Sentiment input passes through; no on-chain OI-floor today | **deferred** |
| Per-resolution impulse cap | `±15% mark` | `FeedbackController.impulseCapBps = 1500`, tunable [100, 5000]; enforced before late-move discount | **closed** |
| `k_impact` (price impact) | starting `0.0008` | not implemented (mark is push-only) | **deferred** |

### 2.2 §2 mark-price evolution

| Term | Implementation | Status |
|---|---|---|
| `P_mark(t+1) = P_mark(t) + ΔP_flow + ΔP_impulse` | Two channels now: (1) live-feed `pushMark` by mark-writers (with the v2-audit max-delta cap), (2) discrete `applyImpulse` from FeedbackController on resolution. Order-flow ΔP composition lives off-chain. | **closed** (impulse channel shipped) |
| Late-move discount | `FeedbackController._applyLateMoveDiscount` per spec §5: linear in `lateBy × slope / denominator`, clamped at `maxDiscountBps` (default 50%) | **closed** |
| Event-category coefficients (spec §2 line 81-89) | `FeedbackController.coefficients[EventClass]` — 9 default coefficients seeded at initialize; tunable per-event | **closed** |

### 2.3 §2 funding-rate formula (spec lines 47–60)

| Term | Implementation | Status |
|---|---|---|
| Per-subject cumulative funding index | `FundingStorage.cumulativeFundingIndex[subjectId]` written by `PerpEngine.pushFundingIndex` (gated `onlyFundingEngine`); driven by `FundingEngine.pokeFunding` | **closed** |
| Funding-during-pauses freeze | `pushFundingIndex` routes through `subjectRegistry.requireTradeable` per spec §2 line 66 | **closed** |
| `entryFundingIndex` snapshot on open | Snapshotted from FundingStorage at position open (Wave 2) | **closed** |
| Per-position settle of funding debt at close | **DEFERRED** — `FundingSettled(fundingDelta=0)` emitted today; `FundingMath.computeFundingDebt` is shipped and tested, ready to wire | **partial** |
| `liquidity_factor_i = 0` if OI < $25K | not gated | **deferred** |

### 2.4 §3 position limits

| Spec | Spec value | Implementation | Status |
|---|---|---|---|
| Max OI per subject (one side) | 5% of vault TVL | `MarginStorage.perSubjectSideOiCapBps = 500`, enforced in `MarginEngine.enforceOpenCaps`. TVL denominator: `min(cappedTvl, liveTvl)` (v2-audit Fix #3) | **identical** |
| Max net OI per category | 20% of vault TVL | `MarginStorage.categoryNetOiCapBps = 2000`, tunable [500, 5000]. Signed accumulator; `|prospective|` capped | **closed** |
| Max position per trader per subject | `$50K × KYC tier` | `MarginStorage.tierPerSubjectCap[KycTier]`; governance-set in `MarginEngine.setKycCaps` | **identical** |
| Max combined exposure per trader | `$200K × KYC tier` | `tierCombinedCap[KycTier]`; perp half wired, event half deferred | **partial** |
| Max leverage | 5× | `maxLeverageBps = 50_000`; enforced in `MarginEngine.checkInitialMargin` | **identical** |
| Initial Margin | 20% | `initialMarginBps = 2_000` | **identical** |
| Maintenance Margin | 5% | `maintenanceMarginBps = 500`; LiquidationEngine triggers off `LiquidationMath.isUnderLiquidationBuffer` | **closed** (was partial — now enforced) |
| Liquidation buffer | 2.5% | `liquidationBufferBps = 250`; reads in `LiquidationMath.isUnderLiquidationBuffer` | **closed** |

### 2.5 §3 fee structure

| Spec | Value | Implementation | Status |
|---|---|---|---|
| Perp taker | 0.075% | `TAKER_FEE_RATE = 750` (ppm) | **equivalent** |
| Perp maker | 0.025% | `MAKER_FEE_RATE = 250` (ppm) | **equivalent** |
| Event contract | 1.0% | not implemented | **deferred** |
| Funding rate take | 8% | not yet wired at close | **deferred** |
| LP rebate | 40% → 30% (perp) | `PerpStorage.lpRebatePct = 40`, tunable [25, 50] | **closed** |

### 2.6 §3 liquidation waterfall (spec lines 141–155)

| Tier | Spec | Implementation |
|---|---|---|
| Tier 1 — Partial liquidation, 25% increments, min 4 attempts, restore to MM + 100bps | `LiquidationEngine.liquidate` calls `LiquidationMath.computePartialIncrement`. Counter `partialAttempts[positionId]`. Partial bounty paid each attempt | **closed** |
| Tier 2 — Full liquidation, 1% bounty | `LiquidationMath.computeFullLiquidation`. Three cases: solvent / marginal / wipeout | **closed** |
| Tier 3 — Insurance fund covers shortfall | InsuranceFund drained via `LPVault.drawFromInsuranceForLiquidation`. LiquidationEngine pre-funds the vault before `PerpEngine.liquidateClose` → trader payout + bounty atomic | **closed** |
| Tier 4 — LP socialization, 30% TVL cap | Residual absorbed via LPVault.settlePosition with negative PnL. Cap check (`socializationCapBps = 3000`) reverts on exceed (spec §3 line 152) | **closed** |
| Tier 5 — ADL | **DEFERRED**. `liquidate` reverts `ADLNotImplemented` when Tier 4 cap is exceeded. `LiquidationMath.adlPriority` is shipped and tested; queue iteration is the remaining work. **MAINNET LAUNCH GATE.** | **deferred** |

### 2.7 §3 insurance fund (spec lines 157–163)

| Spec | Implementation | Status |
|---|---|---|
| Initial seed: $1M from treasury | Pre-migration: `LPVault.seedInsurance` (gov, capped at 10M); post: `InsuranceFund.deposit` | **closed** |
| Ongoing 50% of trading fees | `INSURANCE_PCT = 50`; routed to InsuranceFund post-migration via `IInsuranceFund.accrue` | **closed** |
| Cap: 10% of vault TVL; excess → LPs | `insuranceCapBps = 1000`, tunable [100, 5000]. Excess left unbooked → freeAssets absorbs as LP yield | **closed** |
| Floor: <5% TVL → treasury top-up | `insuranceFloorBps = 500`, tunable [0, 1000]; emits `InsuranceFloorBreached`; treasury responds off-chain | **closed** |
| Separate multi-sig from operations | InsuranceFund is STANDALONE UUPS under its own governance per spec §3 line 162 | **closed** |

### 2.8 §3 pause and circuit-breaker thresholds (spec lines 165–176)

| Spec trigger | Spec effect | Implementation |
|---|---|---|
| 5% mark move in 30s | 30s pause; auto-resume | `PauseGuardian.observe` ring-buffers per-subject marks; worst-tier-wins. 5% → `setAutoPaused`; auto-resume permissionless after 30s. **Closed.** |
| 10% mark move in 30 min | 5 min pause | 10% → `setCooldown` |
| 20% mark move in 1 hour | 15 min pause; admin review | 20% → `setFrozen` (PauseGuardian needs PAUSE_GUARDIAN_ROLE AND SUBJECT_ADMIN_ROLE) |
| Subject opt-out | 7-day window + force-settle | `requestDelisting` + `forceSettle` |
| Death/incapacitation | Immediate force-settle | `flagDeathPending` + `confirmDeath` + `forceSettleSubject` + `closeAtForcedSettlement` (v2-audit Fix #1) |
| Involuntary delisting | Immediate force-settle | Same path |

During pauses (spec line 176): no new positions / no liquidations / no funding accrual / no event-impulse. All four enforced via `requireTradeable` on the respective entry paths. Defense in depth: `pushFundingIndex` AND `applyImpulse` BOTH call `requireTradeable`.

### 2.9 §4 oracle stack

| Spec | Implementation |
|---|---|
| Three sources | All three shipped — `ChainlinkAdapter` + `UMAAdapter` + `SignedFeedAdapter` |
| Per-metric configuration via OracleRouter | Timelocked register/update |
| 3-of-5 EIP-712 signed feeds | unchanged |
| Stage 1 auto-degraded | **Closed.** Permissionless `markIfStale(metricId)` flips degraded when `now > valueTimestamp + 3 × cadence` |
| Stage 2 substituted after 14 days | governance can replace adapter via timelocked flow; 14-day + 48h timing not encoded | **deviates / partial** |
| Stage 3 permanent removal | not implemented |
| Composite Person Index Merkle proof | single SIGNED metric | **deviates** (unchanged) |

---

## 3. Storage layout — namespaces in active use

Each namespace slot is `keccak256("people.markets.<contract>.v1")`. Library namespaces resolve to slots in the CALLING proxy's storage; "shared" only means two callers can read the same slot if they decide to. In practice each library is owned by exactly one contract. The exception is `MarginStorage`: `MarginEngine` owns it now (post-Wave-4); `PerpEngine` reaches into it only via `IMarginEngine.recordOpenDelta` / `recordCloseDelta` hooks (gated `onlyPerpEngine`).

| Namespace | Owner contract | Purpose |
|---|---|---|
| `people.markets.perp.v1` | PerpEngine | Positions, marks, governance, mark-writers, funding/feedback/margin/liquidation engine wiring, cappedTvl |
| `people.markets.margin.v1` | MarginEngine | Exposure per trader, KYC tier caps, margin/leverage params, signed net category OI |
| `people.markets.vault.v1` | LPVault | Bookkeepers, governance, operator, pause flags, insurance cap/floor, post-migration `insuranceFund` pointer |
| `people.markets.oracle.v1` | OracleRouter | Per-metric configs, governance |
| `people.markets.registry.v1` | SubjectRegistry | Subjects, statuses, roles, auto-pause deadlines |
| `people.markets.fundingengine.v1` | FundingEngine | Subject↔metric, sentiment, coefficients, writer rotation, governance |
| `people.markets.feedbackcontroller.v1` | FeedbackController | Per-event-class coefficients, impulse cap, late-move params, resolution-writer rotation, governance |
| `people.markets.pauseguardian.v1` | PauseGuardian | Per-subject mark ring buffer, threshold params, governance |
| `people.markets.marginengine.v1` | MarginEngine | Governance, perpEngine pointer (supplements MarginStorage) |
| `people.markets.insurancefund.v1` | InsuranceFund | tracked balance, governance, lpVault pointer |
| `people.markets.liquidationengine.v1` | LiquidationEngine | Per-position partial-attempt counter, liquidators, params, governance, dependency wiring |
| `people.markets.chainlinkadapter.v1` | ChainlinkAdapter | Per-metric feed config, pending registers/updates, governance |
| `people.markets.umaadapter.v1` | UMAAdapter | Per-metric UMA config, per-assertion records, pending registers/updates, governance |

### Reserved (declared, partially used)

- `people.markets.funding.v1` (FundingStorage) — `cumulativeFundingIndex` and `lastFundingAt` ARE used; the coefficient fields are obsolete (FundingEngine owns coefficients in its own namespace). Documentation pass recommended.
- `people.markets.liquidation.v1` (LiquidationStorage) — superseded by LiquidationEngine's own namespace. Fields can be cleaned up in a future pass.
- `people.markets.feedback.v1` (FeedbackStorage) — superseded by FeedbackController's own namespace. Same.

---

## 4. Interfaces and external calls — added since prior audit

### 4.1 PerpEngine

| Function | Access | Wave |
|---|---|---|
| `pushFundingIndex(subjectId, newIndex, fundingRate)` | `onlyFundingEngine` | 2 |
| `proposeSetFundingEngine` / activate / cancel | gov / permissionless / gov | 2 |
| `applyImpulse(subjectId, impulseBps)` | `onlyFeedbackController` | 3B |
| `proposeSetFeedbackController` / activate / cancel | gov / permissionless / gov | 3B |
| `proposeSetMarginEngine` / activate / cancel | gov / permissionless / gov | 4 |
| `liquidateClose(positionId, sizeToClose, collateralToReturn, bountyToPay, signedPnl, liquidator, tier)` | `onlyLiquidationEngine` | 5B |
| `proposeSetLiquidationEngine` / activate / cancel | gov / permissionless / gov | 5B |
| `openPositionFor(trader, params)` | `onlyRouter` | 6B (in flight) |
| `proposeAddRouter` / activate / cancel / `removeRouter` | gov / permissionless / gov / gov | 6B |

Removed (moved to MarginEngine in Wave 4): `setKycCaps`, `setMarginParams`, `setCategoryNetOiCapBps`; views `initialMarginBps`, `maintenanceMarginBps`, `liquidationBufferBps`, `maxLeverageBps`, `perSubjectSideOiCapBps`, `categoryNetOiCapBps`, `tierPerSubjectCap`, `tierCombinedCap`, `netCategoryOiOf`.

### 4.2 LPVault

| Function | Access | Wave |
|---|---|---|
| `setInsuranceCapBps` / `setInsuranceFloorBps` | gov | 2 |
| `checkInsuranceFloor()` | permissionless | 2 |
| `migrateInsuranceFund(newFund)` | gov | 6A |
| `approveInsuranceFund()` | gov | 6A |
| `drawFromInsuranceForLiquidation(recipient, amount)` | `onlyLiquidationEngine` | 5B |
| `settleLiquidation(trader, liquidator, collateral, traderPayout, bountyPayout, pnl)` | `onlyPerpEngine` | 5B |
| `proposeSetLiquidationEngine` / activate / cancel | gov / permissionless / gov | 5B |

### 4.3 New contracts (full surface in interface files)

- **`OracleRouter`** — `markIfStale(metricId)` permissionless.
- **`ChainlinkAdapter`** — `proposeRegisterFeed/activate/cancel`, `proposeUpdateFeed/activate/cancel`, `latestValue/latestTimestamp/readMetric`, timelocked governance transfer.
- **`UMAAdapter`** — `proposeRegisterMetric` / activate / cancel / update, `proposeAssertion(metricId, claimedValue, claim)`, `settleAssertion(assertionId)`, `latestValue/latestTimestamp/readMetric`, timelocked governance transfer.
- **`PauseGuardian`** — `observe(subjectId)` permissionless ring-buffer + breaker eval, `setThresholds` propose/activate/cancel.
- **`FundingEngine`** — `pokeFunding(subjectId)` permissionless, `registerSubject` / `deregisterSubject`, `setSentimentScore` (writer rotation), `setFundingCoefficients`, governance transfer.
- **`FeedbackController`** — `applyResolution(input)` writer-only, `setCoefficient` / `setImpulseCapBps` / `setLateMoveParams`, resolution-writer rotation, governance transfer.
- **`MarginEngine`** — `enforceOpenCaps`, `checkInitialMargin`, `isUnderMaintenance`, `recordOpenDelta` / `recordCloseDelta` (perp-only), `setKycCaps` / `setMarginParams` / `setCategoryNetOiCapBps`, governance transfer.
- **`InsuranceFund`** — `deposit`, `accrue` (vault-only), `drawShortfall` (vault-only), `setLPVault`, governance transfer.
- **`LiquidationEngine`** — `liquidate(positionId)` writer-only, `setConfig`, liquidator rotation, governance transfer.

---

## 5. Invariants implemented as tests

8 of 10 invariants now running as Foundry-invariant fuzz tests at handler-driven 5k×200 in CI.

| ID | Spec invariant | Status |
|---|---|---|
| **I1** | Vault solvency: bookkeeper-sum identity | pass at 5k×200 |
| **I2** | Position consistency: size ≠ 0 → collateral > 0 | pass |
| **I3** | OI conservation per subject (ghost-counter form) | pass |
| I4 | Funding index monotonicity | implementable now — not yet wired |
| I5 | Margin coverage with mid-liquidation | implementable now — not yet wired |
| I6 | Cross-margin conservation | event half still deferred |
| **I7** | Mark staleness | pass |
| **I8** | Pause respect | pass |
| I9 | Impulse boundedness | implementable now — not yet wired |
| I10 | ADL fairness | ADL not yet implemented |

**Follow-up**: extend the handler with `hPokeFunding` / `hApplyResolution` / `hLiquidate`, wire I4 / I5 / I9.

---

## 6. Deviations from spec

1. **Mark price evolution still off-chain** for the ΔP_flow half (order-flow composition). ΔP_impulse half (event resolutions) is now on-chain. **Closed for impulse.**
2. **OI cap denominator** = `min(cappedTvl, freeAssets())` (v2-audit Fix #3). **Closed.**
3. **LP rebate governance-tunable.** **Closed.**
4. **Voluntary close into negative equity reverts.** LiquidationEngine path is the only way to clear deeply-underwater positions. 4-tier waterfall works end-to-end. Mainnet launch gate is **Tier 5 ADL**.
5. **Oracle "degraded"** now both operator-controlled AND automatic (markIfStale). **Closed for staleness half.**
6. **Signed-feed payload omits subjectId.** Implicit in metricId.
7. **Stage 2 oracle substitution timing** (14-day + 48h) not encoded.
8. **Mark scale: 1e18** fixed-point vs USDC's 6 decimals. Documented.
9. **MAX_LEVERAGE_BPS ceiling is 6×.** Default 5×.
10. **OI tracked at opening notional.** Standard convention.
11. **Sentiment funding cap** bundled into `fMaxPerHour` clamp. Spec implies three-cap layering; we apply total cap. **Closed in spirit.**
12. **Storage namespace pattern.**
13. **Funding settle at close** still emits `fundingDelta=0`. Math is shipped; integration is the next funding wave. Spec line 138 (8% vault take) also not apportioned at close.
14. **ADL (Tier 5)** is not shipped. **MAINNET LAUNCH GATE.**

---

## 7. Decisions made without spec coverage

Cumulative across the entire audit history. Items new to this refresh are marked *new*.

1. Fee precision = ppm (1e6).
2. `pmUSDC` share decimals = 12.
3. `freeAssets` computed by difference.
4. Solady transient-storage ReentrancyGuard.
5. One position per `(trader, subject)`; no sign-flip.
6. Position ID derivation; nonce never reused.
7. Mark-writer add timelocked, revoke immediate.
8. `setOperator` immediate.
9. Closes allowed during subject pauses.
10. Mock USDC adversarial toggles.
11. Governance timelock bounds [1h, 30d].
12. Initial role grants without timelock at init.
13. PerpEngine `governance` for both speeds.
14. `UnderwaterClose` revert in both LPVault.settlePosition AND PerpEngine.closePosition.
15. Fee residual (≈10%) to `accruedFees`.
16. Forced-settle push model; trader claims.
17. `closeAtForcedSettlement` zero-fee.
18. `forceSettleSubject` requires DELISTED.
19. `MAX_INSURANCE_SEED = 10M` USDC.
20. `setLpRebatePct` bounds [25, 50] with zero-residual allowed.
21. `pendingFeeWithdrawal` single in-flight.
22. Forced-settlement underwater → capped at posted collateral.
23. OI cap denominator = `min(cappedTvl, freeAssets())`.
24. Default `markMaxDeltaBps = 1500` (15%).
25. SignedFeedAdapter timelocked governance transfer.
26. *(new, Wave 1A)* `markIfStale` permissionless. Restricting to multi-sig would re-introduce human latency.
27. *(new, Wave 1A)* `markIfStale` reverts on already-degraded rather than idempotent no-op.
28. *(new, Wave 1B)* ChainlinkAdapter keeps deprecated `answeredInRound >= roundId` as defense-in-depth.
29. *(new, Wave 1C)* UMAAdapter bond flow via `safeTransferFrom`; LPVault pre-approves InsuranceFund max-uint once at wiring time.
30. *(new, Wave 1D)* PauseGuardian uses a 128-slot ring buffer with 5s minimum observation interval. Pull-model.
31. *(new, Wave 1D)* Worst-tier-wins when multiple breakers fire simultaneously.
32. *(new, Wave 2)* `FundingSettled(fundingDelta=0)` event emitted at close even though math is deferred. Indexer subscribes today.
33. *(new, Wave 2)* `entryFundingIndex` snapshotted at open from FundingStorage.
34. *(new, Wave 2)* Category OI tracked as signed accumulator; `|prospective|` capped.
35. *(new, Wave 2)* Insurance overflow above cap left UNBOOKED → freeAssets absorbs as LP yield.
36. *(new, Wave 2)* Floor breach informational only. cap > floor strict invariant on both setters.
37. *(new, Wave 3A)* FundingEngine has its own namespace; FundingStorage's coefficient fields are legacy.
38. *(new, Wave 3A)* `pokeFunding` permissionless. Pauses freeze accrual via the perp-side gate.
39. *(new, Wave 3A)* First poke seeds `lastFundingAt` clock with rate=0.
40. *(new, Wave 3B)* `applyImpulse` does NOT consult `markMaxDeltaBps` — impulse channel has its own cap.
41. *(new, Wave 3B)* FeedbackController defaults 9 EventClass coefficients at midpoint values.
42. *(new, Wave 4)* MarginStorage owned by MarginEngine exclusively. PerpEngine reaches in via `recordOpenDelta`/`recordCloseDelta` hooks (gated `onlyPerpEngine`). The prior "shared library namespace" design wouldn't have worked because library namespaces resolve to slots in the CALLING proxy's storage.
43. *(new, Wave 4)* `setKycCaps` / `setMarginParams` / `setCategoryNetOiCapBps` migrated to MarginEngine. PerpEngine no longer exposes them.
44. *(new, Wave 5A)* LiquidationMath is pure stateless. Units documented: collateral/notional/PnL = 6-decimal USDC; mark = 1e18; size = 1e6-fixed.
45. *(new, Wave 5B)* Partial liquidation counts each call as one attempt regardless of math outcome. After N failed partials, next caller escalates to full.
46. *(new, Wave 5B)* Tier 3 → Tier 4 transition: insurance drains first, socialization absorbs residual up to cap. Cap exceeded → revert (ADL is the fallback that's not yet built).
47. *(new, Wave 5B)* Liquidation pre-funds LPVault by drawing insurance BEFORE calling `PerpEngine.liquidateClose`. Trader payout + bounty in one atomic settle.
48. *(new, Wave 6A)* `InsuranceFund.balance()` returns `trackedBalance` not `usdc.balanceOf`. Donations don't inflate cap math.
49. *(new, Wave 6A)* `seedInsurance` reverts post-migration. Treasury operators learn `InsuranceFund.deposit`.
50. *(new, Wave 6A)* `InsuranceFund.setLPVault` is governance-only with NO timelock — fast cut-off for compromised-key response.

---

## 8. Open questions for the spec author

1–11 from the prior audit are all **resolved** through Waves 1–5B. Carryovers:
- **9 (category OI cap)** — closed in Wave 2.
- **3 (Stage 1 auto-degraded)** — closed in Wave 1A.
- **4 (signed-feed subjectId)** — still implicit in metricId.

New questions raised by this push:

- **Funding settle at close** — does the 8% vault take (spec line 138) come out of (a) trader-paid funding only, or (b) every funding flow magnitude regardless of direction?
- **Insurance fund top-up trigger details.** Should `InsuranceFloorBreached` drive an on-chain treasury contract, or is it strictly an off-chain ops process?
- **ADL (Tier 5) priority queue.** Chunked across multiple txs with `advanceADL(positionId)`, or a single-tx top-K dequeue with a maintained heap? Option (a) is simpler but slower to clear bad debt; option (b) costs ongoing per-trade gas to maintain the heap.

---

## 9. What's next

1. **PairTradeRouter (Wave 6B)** — in flight.
2. **BatchRouter (Wave 6C)** — queued, sequential after 6B.
3. **ADL (Tier 5)** — the mainnet launch gate. Requires the priority-queue / chunked-iteration mechanism (see open question above).
4. **Per-position funding settle at close** — wire `FundingMath.computeFundingDebt` into `closePosition` / `closeAtForcedSettlement` / `liquidateClose`. Library is shipped; this is a PerpEngine close-path edit + LPVault.settlePosition extension.
5. **Full `solidity-auditor` DEEP pass (Wave 7)** across the entire src/ tree. The codebase has grown ~4× since the last DEEP pass.
6. **Invariants I4, I5, I9** wired into the handler.
7. **Storage cleanup**: drop the obsolete fields in FundingStorage / LiquidationStorage / FeedbackStorage.

---

## 10. Engineering metadata — agent waves in this push

| Wave | Commit | Scope |
|---|---|---|
| 1A | `cf06561` | OracleRouter `markIfStale` + per-metric cadence |
| 1B | `234e088` | ChainlinkAdapter |
| 1C | `9efa6a3` | UMAAdapter |
| 1D | `4bfcc56` | PauseGuardian |
| 2  | `9d120d6` | Tier-1 bundle: funding stub + category OI cap + insurance cap/floor |
| 5A | `b3ae29a` | LiquidationMath library (retry — first attempt had unit bugs) |
| 3A | `3955dd3` | FundingMath + FundingEngine v1 |
| 3B | `abce0fe` | FeedbackController + PerpEngine.applyImpulse |
| 4  | `85a1616` | MarginEngine extraction (PerpEngine shrinks 1.65KB) |
| 6A | `7ad5aa0` | InsuranceFund standalone + LPVault migration |
| 5B | `afa4c35` | LiquidationEngine v0 (4 of 5 tiers; ADL deferred as launch gate) |
| 6B | (in flight) | PairTradeRouter |
| 6C | (queued) | BatchRouter |
| 7  | (queued) | Final solidity-auditor DEEP pass |

11 commits landed; 1 agent active; 2 queued. Tests grew from 481 → 1,179 (+145% over the push). Production contracts grew from 5 → 11.

---

*End of audit refresh.*
