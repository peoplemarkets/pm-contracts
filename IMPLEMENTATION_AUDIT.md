# Implementation Audit — pm-contracts

**As of commit `b19306b` on `main`.** Refresh of the original audit (commit `367170c`) following Session A v0 gap closures, the v2 `solidity-auditor` pass, and the six audit-driven fixes.

`forge test`: **481 passed, 0 failed, 0 skipped** across 8 suites (run cold for this audit).
`forge coverage --ir-minimum`: totals **98.15% line / 99.12% branch / 98.51% func**.

The spec lives at `mechanismdesign.md` in this repo (the original prompt referred to it as `People_Markets_Mechanism_Design.md`; same document).

This refresh REPLACES the prior audit snapshot. The previous version is preserved in git at commit `cdb87b3`.

---

## 1. Scope completed

| Path | Status | Solidity LoC* | Coverage (line / branch) | `forge test` |
|---|---|---:|---|---|
| `src/libraries/PositionMath.sol` | complete · tested | 33 | 100% / 100% | pass (30 tests) |
| `src/libraries/StorageLib.sol` | 8 namespaces declared; 4 in active use | 215 | 41.67% / 100% (Funding/Liquidation/Feedback unused) | n/a — pure storage |
| `src/oracle/IOracleAdapter.sol` | complete | 5 | n/a (interface) | n/a |
| `src/oracle/IOracleRouter.sol` | complete | 44 | n/a | n/a |
| `src/oracle/OracleRouter.sol` | complete · tested | 127 | 98.89% / 100% | pass (39 tests) |
| `src/oracle/SignedFeedAdapter.sol` | complete · tested | 245 | 100% / 100% | pass (56 tests) |
| `src/registry/ISubjectRegistry.sol` | complete | 106 | n/a | n/a |
| `src/registry/SubjectRegistry.sol` | complete · tested | 338 | 99.60% / 100% | pass (98 tests) |
| `src/core/IPerpEngine.sol` | complete | 154 | n/a | n/a |
| `src/core/ILPVault.sol` | complete | 110 | n/a | n/a |
| `src/core/LPVault.sol` | complete · tested · v2-audit-closed | 377 | 98.65% / 97.73% | pass (95 tests) |
| `src/core/PerpEngine.sol` | complete · tested · v2-audit-closed | 605 | 99.51% / 98.80% | pass (153 tests) |
| `test/integration/PerpVaultE2E.t.sol` | complete | n/a | n/a | pass (2 tests) |
| `test/invariant/PerpVaultHandler.sol` + `PerpVaultInvariants.t.sol` | complete | n/a | n/a | pass (8 invariants @ 5k×200) |

*Approximate, computed by stripping single-line `//`, block-comment markers, and blank lines. Not a normative LoC.

**Not yet started** (remaining implementation order):
- `src/core/MarginEngine.sol` (margin checks split out of PerpEngine)
- `src/core/FundingEngine.sol` (funding accrual; week 8-9)
- `src/core/LiquidationEngine.sol` (5-tier waterfall + ADL; week 14+)
- `src/core/InsuranceFund.sol` (cap, floor, treasury top-up; week 14+)
- `src/core/PauseGuardian.sol` (auto-detect circuit breakers)
- `src/routers/PairTradeRouter.sol` (atomic long-A / short-B)
- `src/routers/BatchRouter.sol` (multi-position ops)
- `src/feedback/FeedbackController.sol` (event impulses + late-move discount)
- `src/oracle/ChainlinkAdapter.sol`
- `src/oracle/UMAAdapter.sol`
- `src/libraries/FundingMath.sol`
- `src/libraries/LiquidationMath.sol`

---

## 2. Spec compliance — line by line

Status legend: **identical** = exact value/formula; **equivalent** = numerically identical with a different unit/encoding; **deviates** = differs from spec, see §6; **deferred** = mechanism not in scope this milestone, no code yet; **partial** = primitive present but full mechanism not wired; **closed** = was a deviation in the prior audit; resolved by Session A or v2-audit fix.

### 2.1 §2 Price formation parameters (parameters table, spec lines 70–79)

| Spec | Spec value | Implementation | Status |
|---|---|---|---|
| `k_impact` (price impact) | starting `0.0008`, range `0.0003-0.002` | not implemented (mark is push-only by writer; no on-chain AMM) | **deferred** |
| `k_premium` | `0.0125`, range `0.005-0.025` | reserved as `FundingStorage.kPremium` (uninitialized) | **deferred** |
| `k_sentiment` | `0.004`, range `0.001-0.010` | reserved as `FundingStorage.kSentiment` | **deferred** |
| `k_skew` | `0.003`, range `0.001-0.008` | reserved as `FundingStorage.kSkew` | **deferred** |
| `F_max` | `0.075%/h`, range `0.05-0.15%/h` | reserved as `FundingStorage.fMaxPerHour` | **deferred** |
| Funding interval | 1 hour, range 15min-8h | reserved as `FundingStorage.fundingIntervalSeconds` | **deferred** |
| Min event OI for sentiment | `$25K`, range `$10K-$100K` | reserved as `FundingStorage.minEventOiForSentiment` | **deferred** |
| Per-resolution impulse cap | `±15% mark` | reserved as `FeedbackStorage.impulseCapBps` (uint16) | **deferred** |

### 2.2 §2 mark-price evolution formula (spec lines 30–36)

| Term | Implementation | Status |
|---|---|---|
| Mark evolution as a state-equation | mark price is a single `uint256` per subject, written by permissioned `markWriters` via `PerpEngine.pushMark`. v2-audit Fix #5 added a per-update max-delta cap (`markMaxDeltaBps`, default 1500 = 15%) to bound single-writer compromise. The contract does NOT compute `ΔP_flow` or `ΔP_impulse`. | **deviates intentionally** — see §6 |
| `c_event`, `outcome`, `late_move_discount` | not computed on-chain | **deferred** |

### 2.3 §2 funding-rate formula (spec lines 47–60)

| Term | Implementation | Status |
|---|---|---|
| Funding accrual per subject | `FundingStorage` namespace declared (`cumulativeFundingIndex`, `lastFundingAt`, `frozen`); no FundingEngine contract yet | **deferred** |
| `entryFundingIndex` reserved on `Position` | yes — `IPerpEngine.Position.entryFundingIndex` is `int256`, defaulted to 0 by `openPosition` | **partial (storage primitive only)** |
| Funding-during-pauses | spec lines 64–66; `FundingStorage.frozen` flag declared but not enforced | **deferred** |
| `liquidity_factor_i = 0` if `OI_i < $25K` | reserved as `FundingStorage.minEventOiForSentiment` | **deferred** |

### 2.4 §2 per-event-category impulse coefficients (spec lines 81–89)

`FeedbackStorage.coefficients[EventClass]` namespace exists; contents zero. **Status: deferred (FeedbackController, week 10–13).**

### 2.5 §3 position limits (spec lines 120–129)

| Spec | Spec value | Implementation | Status |
|---|---|---|---|
| Max OI per subject (one side) | 5% of vault TVL | `MarginStorage.perSubjectSideOiCapBps`, default `500` (5%); enforced in `PerpEngine._enforceOpenCaps`. **Vault-TVL definition: `min(cappedTvl, freeAssets())`** — v2-audit Fix #3 added the slow-moving `cappedTvl` snapshot to defeat same-block flash-deposit cap inflation. | **closed** (was deviation #2 prior; now resolved with documented `min(slow, live)` semantic) |
| Max net OI per category | 20% of vault TVL | not implemented; no per-category OI tracking | **not yet implemented** |
| Max position per trader per subject | `$50K × KYC tier` (T1=$50K, T2=$250K, T3=$1M) | `MarginStorage.tierPerSubjectCap[KycTier]`; values are governance-set, validated in `setKycCaps` | **identical (configurable)** |
| Max combined exposure per trader | `$200K × KYC tier` | `MarginStorage.tierCombinedCap[KycTier]`; same configurable shape. Cross-margin event component reserved on `AccountExposure` but not yet summed in (no event positions exist). | **partial** (perp half wired; event half deferred) |
| Max leverage | 5× | `MarginStorage.maxLeverageBps = 50_000`; enforced in `openPosition` and `removeCollateral` | **identical** |
| Initial Margin | 20% of notional | `MarginStorage.initialMarginBps = 2_000`; enforced in `openPosition` and `removeCollateral` | **identical** |
| Maintenance Margin | 5% of notional | `MarginStorage.maintenanceMarginBps = 500`; read by views only (`isMarginOk`). Not yet enforced as a state-changing trigger because LiquidationEngine is deferred | **partial** (value present; liquidation enforcement absent) |
| Liquidation buffer | 2.5% of notional | `MarginStorage.liquidationBufferBps = 250`; reserved, no enforcement yet | **partial** |

### 2.6 §3 fee structure (spec lines 133–139)

| Spec | Spec value | Implementation | Status |
|---|---|---|---|
| Perp taker | 0.075% | `PerpEngine.TAKER_FEE_RATE = 750` with `FEE_RATE_DENOM = 1e6` (= 0.075%) | **equivalent** (ppm encoding — see §7) |
| Perp maker | 0.025% | `PerpEngine.MAKER_FEE_RATE = 250` (= 0.025%) | **equivalent** |
| Event contract | 1.0% | not implemented (event markets deferred) | **deferred** |
| Funding rate take | 8% | not implemented (funding deferred) | **deferred** |
| LP rebate | 40% perp / 30% event (decreasing to 30%/25%) | `PerpStorage.lpRebatePct` (governance-set, bounds [25, 50]); initialized to 40 | **closed** (was deviation #3 prior; now resolved with `setLpRebatePct` setter) |

Insurance share: `INSURANCE_PCT = 50` (pinned). Residual = `fee − lpRebate − insuranceShare` flows to `accruedFees`. With `lpRebatePct ∈ [25, 50]`, residual ∈ [0, 25].

### 2.7 §3 liquidation waterfall (spec lines 141–155)

| Tier | Spec | Implementation |
|---|---|---|
| Tier 1 — Partial liquidation, 25% increments, min 4 attempts, restore to MM + 100bps | `LiquidationStorage` declares `partialIncrementBps`, `minPartialsBeforeFull`, `mmRestoreBufferBps`; **no LiquidationEngine contract; no execution path** | **not yet implemented** |
| Tier 2 — Full liquidation, 1% liquidator bounty | `LiquidationStorage.fullLiquidationBountyBps` reserved; no execution | **not yet implemented** |
| Tier 3 — Insurance fund covers shortfall | `VaultStorage.insuranceFundBalance` accumulates from fee splits; v2-audit Fix #1 caps trader's forced-settle loss at posted collateral so the position can settle, but the LP-side shortfall above collateral is not yet drawn from insurance | **partial (bucket only)** |
| Tier 4 — LP socialization, 30% TVL cap | `LiquidationStorage.lpSocializationCapBps` reserved; no execution | **not yet implemented** |
| Tier 5 — ADL, priority by `unrealizedPnL × leverage` | not implemented; no priority queue | **not yet implemented** |

`PerpEngine.closePosition` reverts with `UnderwaterClose` if a voluntary close would settle into negative equity — explicit defer-to-liquidation-engine decision. Documented as a hard mainnet launch gate (the entire LiquidationEngine must ship before mainnet opens).

### 2.8 §3 insurance fund (spec lines 157–163)

| Spec | Implementation | Status |
|---|---|---|
| Initial seed: $1M from treasury at launch | `LPVault.seedInsurance(uint256)` — governance-only, no timelock, capped cumulatively at `MAX_INSURANCE_SEED = 10M USDC`. Pulls USDC from caller, books to `insuranceFundBalance`. | **closed** (was deviation; now implemented via Session A Fix #6) |
| Ongoing replenishment: 50% of trading fees until cap | `INSURANCE_PCT = 50`; on every `openPositionFlow` and `settlePosition`, vault increments `insuranceFundBalance`. Cap is not yet checked. | **partial — accrual yes, cap no** |
| Cap: 10% of vault TVL — excess to LPs as share-price boost | not implemented | **not yet implemented** |
| Floor: <5% TVL → treasury top-up to ceiling, no rebate change | not implemented (the `seedInsurance` cap headroom of 10M supports operational top-up but the auto-trigger logic is absent) | **not yet implemented** |
| Governance: separate multi-sig from operations, with timelock and rationale | `LPVault.proposeFeeWithdrawal/activateFeeWithdrawal/cancelFeeWithdrawal` exposes a timelocked path for the **treasury** bucket (`accruedFees`) — Session A Fix #5. Insurance-fund withdrawals are still not exposed in v0. | **partial** (treasury bucket withdrawable; insurance-fund withdrawable in v1 via dedicated InsuranceFund contract) |

### 2.9 §3 pause and circuit-breaker thresholds (spec lines 165–176)

| Spec trigger | Spec effect | Implementation |
|---|---|---|
| 5% mark move in 30s | 30s pause; auto-resume | `SubjectStatus.AUTO_PAUSED` exists; `setAutoPaused` writes `autoPauseExpiresAt = block.timestamp + 30s`; `unpauseAuto` is permissionless after expiry, pauseGuardian-only before. **Threshold detection still off-chain — caller decides when to flip.** Auto-resume now permissionless (Session A Fix #8 closed the prior gap). |
| 10% mark move in 30 min | 5 min pause; admin review | `SubjectStatus.COOLDOWN`; manual flip + manual unpause |
| 20% mark move in 1 hour | 15 min pause; admin review required | `SubjectStatus.FROZEN`; `setFrozen` requires `subjectAdmin` |
| Subject opt-out | 7-day close window, then forced settlement | `requestDelisting` sets `delistingForceSettleAt = now + 7 days`; `forceSettle` permissionless once elapsed. ✓ |
| Death/incapacitation, oracle-confirmed | Immediate forced settlement at last fair mark before news | Two-step: `flagDeathPending` + `confirmDeath` (registry) → `forceSettleSubject(subjectId, capturedMark)` (engine). Traders claim via `closeAtForcedSettlement`. v2-audit Fix #1 added the underwater-cap so insolvent positions can still settle. **Closed** — was deviation #4 / question #7 prior. |
| Involuntary delisting (legal/regulatory) | Immediate forced settlement at last pre-action mark | Same two-step path: `involuntaryDelist` (registry) → `forceSettleSubject` (engine) → trader claims. **Closed.** |

> Spec line 176: "During pauses: no new positions, no liquidations, no funding accrual, no event-impulse application."

| Effect | Implementation |
|---|---|
| No new positions | `openPosition` calls `subjectRegistry.requireTradeable(subjectId)` which reverts on any non-`ACTIVE` status. ✓ |
| No liquidations | n/a in v0 (no liquidation engine) |
| No funding accrual | n/a in v0 (no funding engine; primitive `FundingStorage.frozen` reserved) |
| No event-impulse application | n/a in v0 (no feedback controller) |

### 2.10 §5 late-move discount formula (spec lines 285–289)

`FeedbackStorage` reserves `lateMoveDenominator`, `discountSlope`, `maxDiscount`. **Status: deferred (FeedbackController, week 10–13).**

### 2.11 §5 cross-margining (spec lines 305–315)

| Term | Implementation |
|---|---|
| Perp half of `total_exposure` | `MarginStorage.exposure[trader].totalPerpNotional` summed and capped against `tierCombinedCap[KycTier]` in `PerpEngine._enforceOpenCaps`. ✓ |
| Event half (`Σ event_position_i × correlation × c_event_xm`) | `AccountExposure.totalEventExposure` field reserved; never written. |
| `c_event_xm = 0.25` | `MarginStorage.crossMarginMultiplier` reserved (uninitialized). |

**Status: partial — perp half only.**

### 2.12 §1 / §3 mark staleness (30s) and ±15% per-resolution impulse cap

| Spec | Implementation |
|---|---|
| 30s mark staleness on trades | `PerpStorage.markStaleAfter` defaults to `30 seconds` in `initialize`; enforced on every `openPosition`, `closePosition`, `removeCollateral` via `_readFreshMark`. Bounds `[5s, 1h]` for governance changes. ✓ |
| Per-update mark max-delta cap (single-writer compromise bound) | `PerpStorage.markMaxDeltaBps = 1500` (15%); v2-audit Fix #5. Bounds [100, 5000] bps. First push for a subject is uncapped. |
| ±15% per-resolution impulse cap | `FeedbackStorage.impulseCapBps` reserved (uint16). No enforcement (deferred). |

### 2.13 §6 subject delisting and policy

| Spec | Implementation |
|---|---|
| Voluntary opt-out, 7-day close window, then force-settlement | `SubjectRegistry.requestDelisting` + `forceSettle`. ✓ |
| Death/incapacitation, 24h halt, confirmed → forced settlement | Full two-step flow in place; trader claims through `PerpEngine.closeAtForcedSettlement` (v2-audit Fix #1). ✓ |
| Involuntary (legal/regulatory), immediate | `involuntaryDelist` + `forceSettleSubject` + trader claim. ✓ |
| Markets on minors: catalog hard block | `PolicyFlag.MINOR` exists; `listSubject` rejects if `subj.policyFlag != NONE`. ✓ |
| US politicians in election years: catalog block | `PolicyFlag.US_POLITICIAN_ELECTION_YEAR` exists; same enforcement path. ✓ |

### 2.14 §4 oracle stack

| Spec | Implementation |
|---|---|
| Three sources: Chainlink, UMA, Signed | `IOracleRouter.SourceType` has `CHAINLINK`, `UMA`, `SIGNED` (plus `UNSET`). Only `SignedFeedAdapter` is shipped. | **partial** |
| Per-metric configuration via `OracleRouter` | `OracleRouter.proposeRegister` / `activateRegister` (timelocked); full `MetricConfig` carried. ✓ |
| 3-of-5 EIP-712 signed feeds | `SignedFeedAdapter.SIGNER_COUNT = 5`, `THRESHOLD = 3`. v2-audit Fix #7 replaced single-step `transferGovernance` with timelocked propose/activate/cancel matching the rest of the suite. ✓ |
| Lazy evaluation (push only when needed) | Anyone may submit; signature gate is the security boundary. ✓ |
| Stage 1 — Degraded after 3× cadence (automatic) | `setDegraded(metricId, bool, reasonHash)` is **operator-controlled, not automatic**. Off-chain keeper monitoring required. | **deviates** — see §6 |
| Stage 2 — Substituted after 14 days, governance vote, 48h announcement | governance can replace fallback / full config via timelocked `proposeSetFallback` / `proposeRegister`. The 14-day requirement, the dedicated "substitute" path, and the 48h announcement window are not modeled. | **deviates / partial** |
| Stage 3 — Permanent removal, 7-day position close window | not implemented | **not yet implemented** |
| Composite (Person Index) Merkle proof | composite Person Index is registered as a single SIGNED metric. **No on-chain Merkle proof / challenge path.** | **deviates** |
| TWAP on index-component metrics (1h minimum) | not enforced on-chain. | **deferred** |
| EIP-712 domain | `name = "PeopleMarketsSignedFeed"`, `version = "1"`, includes chainId + verifyingContract via solady's `EIP712`. Type hash: `SignedUpdate(bytes32 metricId,uint256 value,uint64 valueTimestamp,uint64 nonce)`. | **deviates** (subjectId implicit in metricId — see §6) |

---

## 3. Storage layout

All slots derived as `keccak256("people.markets.<contract>.v1")`. No ERC-7201 hash-mixing; the namespace string is the sole identifier.

### 3.1 `PerpStorage` — slot `keccak256("people.markets.perp.v1")`

Used by `PerpEngine` (read+write).

| Field | Type | Purpose |
|---|---|---|
| `markPrice` | `mapping(bytes32 => uint256)` | per-subject mark, 1e18 fixed |
| `markUpdatedAt` | `mapping(bytes32 => uint64)` | wall-clock of last push |
| `totalLongOI` | `mapping(bytes32 => uint256)` | long OI at OPENING notional |
| `totalShortOI` | `mapping(bytes32 => uint256)` | short OI at OPENING notional |
| `positions` | `mapping(bytes32 => IPerpEngine.Position)` | per-position struct |
| `openPositionId` | `mapping(address => mapping(bytes32 => bytes32))` | one-position-per-(trader,subject) index |
| `nextPositionNonce` | `uint256` | monotonic, never reused |
| `markWriters` | `mapping(address => bool)` | active writer set |
| `pendingMarkWriterActivatesAt` | `mapping(address => uint64)` | timelocked add queue |
| `globalHalt` | `bool` | governance kill-switch |
| `markStaleAfter` | `uint32` | seconds; default 30 |
| `subjectRegistry` | `address` | dependency, set in initialize |
| `lpVault` | `address` | dependency, set in initialize |
| `governance` | `address` | timelocked admin |
| `timelockDelay` | `uint32` | seconds, in `[1h, 30d]` |
| `pendingGovernance` | `address` | pending transfer |
| `pendingGovernanceActivatesAt` | `uint64` | activation deadline |
| `lpRebatePct` *(Session A #11)* | `uint8` | governance-tunable in [25, 50]; default 40 |
| `subjectSettlementMark` *(Session A #7)* | `mapping(bytes32 => uint256)` | captured mark on forced settlement |
| `subjectForceSettled` *(Session A #7)* | `mapping(bytes32 => bool)` | force-settled flag |
| `markMaxDeltaBps` *(v2 Fix #5)* | `uint16` | per-update mark delta cap (default 1500 = 15%) |
| `cappedTvl` *(v2 Fix #3)* | `uint256` | slow-moving snapshot of vault.totalAssets() |
| `cappedTvlUpdatedAt` *(v2 Fix #3)* | `uint64` | timestamp of last `pokeCappedTvl` |

### 3.2 `MarginStorage` — slot `keccak256("people.markets.margin.v1")`

Used by `PerpEngine` (read+write). Unchanged from prior audit. Fields: `exposure`, `tierCombinedCap`, `tierPerSubjectCap`, `crossMarginMultiplier`, `initialMarginBps`, `maintenanceMarginBps`, `liquidationBufferBps`, `maxLeverageBps`, `perSubjectSideOiCapBps`.

### 3.3 `VaultStorage` — slot `keccak256("people.markets.vault.v1")`

Used by `LPVault` (read+write).

| Field | Type | Purpose |
|---|---|---|
| `positionCollateral` | `uint256` | locked collateral bucket |
| `accruedFees` | `uint256` | residual treasury fees |
| `insuranceFundBalance` | `uint256` | insurance bucket |
| `perpEngine` | `address` | sole operator allowed to move locked collateral |
| `governance` / `pendingGovernance` / `pendingGovernanceActivatesAt` | mixed | timelocked admin |
| `timelockDelay` | `uint32` | seconds |
| `pendingPerpEngine` / `pendingPerpEngineActivatesAt` | mixed | timelocked rotation |
| `operator` | `address` | fast pause lever |
| `depositsPaused` / `withdrawalsPaused` | `bool` | LP pause flags |
| `insuranceSeedDeposited` *(Session A #6)* | `uint256` | cumulative governance seed (capped at MAX_INSURANCE_SEED = 10M USDC) |
| `pendingFeeWithdrawal` *(Session A #5)* | `PendingFeeWithdrawal` struct | single in-flight timelocked treasury withdrawal |

### 3.4 `OracleStorage` — slot `keccak256("people.markets.oracle.v1")`

Unchanged from prior audit. Used by `OracleRouter`.

### 3.5 `RegistryStorage` — slot `keccak256("people.markets.registry.v1")`

Used by `SubjectRegistry`. The `Subject` struct gained one field this milestone:

| Field | Type | Purpose |
|---|---|---|
| (prior fields) | — | unchanged |
| `autoPauseExpiresAt` *(Session A #8)* | `uint64` | 30s deadline written on `setAutoPaused`; cleared on unpause |

### 3.6 SignedFeedAdapter (regular state, not namespaced)

New since prior audit:
- `pendingGovernance` (address)
- `pendingGovernanceActivatesAt` (uint64)
- v2 Fix #7 — replaces single-step `transferGovernance` with timelocked propose/activate/cancel.

### 3.7 Reserved namespaces (declared but no contract reads/writes them yet)

| Namespace | Purpose |
|---|---|
| `keccak256("people.markets.funding.v1")` | `FundingStorage` — funding accrual (week 8–9) |
| `keccak256("people.markets.liquidation.v1")` | `LiquidationStorage` — partial-liquidation state (week 14+) |
| `keccak256("people.markets.feedback.v1")` | `FeedbackStorage` — event-impulse coefficients (week 10–13) |

---

## 4. Interfaces and external calls

Listing only DELTAS from the prior audit (full surface unchanged unless noted).

### 4.1 PerpEngine — added since prior audit

| Function | Access | Effect |
|---|---|---|
| `forceSettleSubject(subjectId, settlementMark)` | `governance` | Subject must be DELISTED. Captures mark, marks subjectForceSettled. Session A #7. |
| `closeAtForcedSettlement(subjectId)` | permissionless | Trader claims at captured mark. ZERO fee, no staleness check, not gated by globalHalt. v2 Fix #1: caps trader's loss at posted collateral when underwater. |
| `setLpRebatePct(uint8)` | `governance` (no timelock) | Bounds [25, 50]. Session A #11. |
| `setMarkMaxDeltaBps(uint16)` | `governance` (no timelock) | Bounds [100, 5000] bps. v2 Fix #5. |
| `pokeCappedTvl()` | permissionless | 60s cooldown. Snapshots vault.totalAssets() into cappedTvl. v2 Fix #3. |
| Views | `lpRebatePct`, `markMaxDeltaBps`, `cappedTvl`, `isForceSettled`, `settlementMarkOf` | |

### 4.2 LPVault — added since prior audit

| Function | Access | Effect |
|---|---|---|
| `seedInsurance(uint256)` | `governance` (no timelock) | Pulls USDC from caller, books to insuranceFundBalance. Capped cumulatively at 10M USDC. Session A #6. |
| `proposeFeeWithdrawal/activateFeeWithdrawal/cancelFeeWithdrawal` | gov / permissionless / gov | Timelocked treasury withdrawal from `accruedFees`. Session A #5. |
| `redeemWithMinAssets(shares, receiver, owner, minAssets)` | public | Slippage-protected redeem; reverts if assets < minAssets. v2 Fix #4 — replaces broken `withdrawWithMaxAssets`. |
| Views | `insuranceSeedDeposited`, `pendingFeeWithdrawal` | |

LPVault `settlePosition` gained the v2 Fix #2 solvency check: reverts `InsufficientFreeAssets` when `pnl > 0` and `pnl − fee` exceeds `freeAssets()`.

### 4.3 SubjectRegistry — modified since prior audit

| Function | Change |
|---|---|
| `setAutoPaused(subjectId, reasonCode)` | Now writes `autoPauseExpiresAt = block.timestamp + 30s`. Session A #8. |
| `unpauseAuto(subjectId)` | No longer `onlyPauseGuardian` — permissionless after the deadline; pauseGuardian-only before. Session A #8. |
| Views | `autoPauseExpiresAt(bytes32)` | |

### 4.4 SignedFeedAdapter — modified since prior audit

| Function | Change |
|---|---|
| `transferGovernance` | **REMOVED**. Replaced by `proposeGovernanceTransfer/activateGovernanceTransfer/cancelGovernanceTransfer` matching the LPVault pattern. v2 Fix #7. |
| `transferOperator` | Unchanged — remains single-step (operator's only power is pause; narrow blast radius). |

---

## 5. Invariants implemented as tests

**Status: 5 of 10 invariants now running as Foundry-invariant fuzz tests at handler-driven 5k×200 in CI.** This was 0/10 in the prior audit.

| ID | Spec invariant | Foundry-invariant test? | Test file / function | Last result |
|---|---|---|---|---|
| **I1** | Vault solvency: bookkeeper-sum identity | **YES** | `test/invariant/PerpVaultInvariants.t.sol::invariant_BookkeeperSumIdentity`, `::invariant_FreeAssetsNeverNegative`, `::invariant_BucketGhostMirror` | pass at 5k×200 (~6 min wall) |
| **I2** | Position consistency: size != 0 → collateral > 0 | **YES** | `::invariant_PositionConsistency`, `::invariant_OpenPositionIdMapping` | pass |
| **I3** | OI conservation per subject | **YES** | `::invariant_OIConservation` (ghost-counter form; walk-form dropped — see test NatSpec for the cumulative-rounding-loss explanation) | pass |
| I4 | Funding index monotonicity | No — FundingEngine deferred | n/a | — |
| I5 | Margin coverage with mid-liquidation | No — LiquidationEngine deferred | n/a | — |
| I6 | Cross-margin conservation | No — event half not implemented | n/a | — |
| **I7** | Mark staleness: no trade against >30s mark | **YES** | `::invariant_StalenessRespected` (counter `ghostStaleOpenSuccesses` must stay 0) | pass |
| **I8** | Pause respect: no state-changing op against paused subject | **YES** | `::invariant_PauseRespected` (counter `ghostNonActiveOpenSuccesses` must stay 0) | pass |
| I9 | Impulse boundedness | No — FeedbackController deferred | n/a | — |
| I10 | ADL fairness | No — LiquidationEngine deferred | n/a | — |

**Handler design**: 17 fuzzer-targetable actions (open long/short, close, add/remove collateral, push/refresh mark, LP deposit/withdraw, three pause states + their unpauses, advance time, poke cappedTvl). Try/catch wraps every contract call so legitimate reverts don't poison the run. Ghost state mirrors the contract's bucket arithmetic exactly. See `test/invariant/PerpVaultHandler.sol` for the full surface.

**Run cadence**: default profile (1k × 100) green in ~30s; CI profile (5k × 200) green in ~6 min. Pre-mainnet 100M+ scaling path via sharded GitHub Actions matrix is documented but not yet wired into CI.

---

## 6. Deviations from spec

Items resolved by Session A or v2-audit fixes are noted as **closed** with reference. Remaining deviations (intentional or deferred):

1. **Mark price evolution is not computed on-chain.** Spec §2 (lines 30–36) gives `P_mark(t+1) = P_mark(t) + ΔP_flow + ΔP_impulse`. Our implementation has the markWriter push a finished mark via `pushMark`. The composition lives off-chain. **Why:** project-doc design principle #2 ("Mark price computation, funding rate calculation, matching live off chain"). v2 Fix #5 adds a per-update max-delta cap to bound single-writer compromise — unchanged design intent, narrower attack surface.

2. **"Vault TVL" definition for the per-subject side OI cap is `min(cappedTvl, freeAssets())`, not pure `freeAssets`.** v2 Fix #3 added the slow-moving `cappedTvl` snapshot to defeat same-block flash-deposit cap inflation. Updated by permissionless `pokeCappedTvl()` with a 60s cooldown; takes the min with live `freeAssets` so withdrawals immediately tighten the cap. **Closed** vs prior audit deviation #2 — the freeAssets-only reading was vulnerable; this composite is now safe.

3. **LP rebate is governance-tunable, not hardcoded.** Storage field `PerpStorage.lpRebatePct` (Session A #11), default 40, bounds [25, 50], setter `setLpRebatePct(uint8)`. Spec §3 line 139 calls for "decreasing to 30%/25% as volume grows" — governance ratchets the value down per the spec curve; the curve itself is intentionally not encoded on-chain (governance discretion per §7 line 417). **Closed** vs prior audit deviation #3.

4. **Voluntary close into negative equity reverts (`UnderwaterClose`).** Spec §3 lines 141–155 prescribe the 5-tier liquidation waterfall. v0 has no liquidation engine, so `closePosition` rejects voluntary close into negative equity. **Underwater forced settlement now resolves correctly**: v2 Fix #1 caps the trader's forced-settlement loss at posted collateral, so the position can clear from `positionCollateral` rather than stranding it forever. Voluntary close into negative equity remains a hard mainnet gate — LiquidationEngine must ship before mainnet opens.

5. **Oracle "degraded" state is operator-controlled, not automatic.** Spec §4 line 242 calls for automatic detection after 3× refresh cadence. Implementation: `setDegraded(metricId, bool, reasonHash)` is gated on `operator`. A keeper bot off-chain must monitor cadence and call. **Why:** automatic on-chain detection requires per-metric cadence storage and a keeper to actually call. The keeper part can't be eliminated. v0 simplification.

6. **Signed-feed payload omits `subjectId`.** Spec §4 line 229 specifies the signed tuple as `(metricId, subjectId, value, timestamp, sourceProof)`. Our EIP-712 type hash is `SignedUpdate(bytes32 metricId,uint256 value,uint64 valueTimestamp,uint64 nonce)` — `subjectId` is implicit in `metricId = keccak(subjectId, kindId)`. Mitigated by keccak collision-resistance.

7. **Stage 2 substitution timing differs.** Spec §4 line 244: "If the metric remains degraded for 14 days... 48h before activation." The 14-day pre-condition and the 48h announcement separation are not encoded. Governance can replace adapter / fallback any time after `timelockDelay`.

8. **Mark scale: 1e18 fixed-point vs USDC's 6 decimals.** Spec doesn't specify. Internal `notional`, `collateral`, `fee`, `pnl` are 6-decimal USDC; `markPrice` and `entryPrice` are 1e18 fixed-point. `PositionMath.unrealizedPnl` divides by `1e18`, which cancels the mark scale and yields PnL in 6-decimal USDC.

9. **`MAX_LEVERAGE_BPS` ceiling is 6×, not 5×.** Spec §3 line 126 says "Max leverage | 5×". Default param is `50_000` (5×). The hard sanity ceiling on `setMarginParams.maxLevBps` is `60_000` (6×) because `MarginStorage.maxLeverageBps` is `uint16`. Spec compliance at default; storage limits a hypothetical future increase.

10. **OI is tracked at OPENING notional, not current mark notional.** Spec §3 line 122 doesn't specify. Standard derivatives convention. Caps don't drift with mark moves.

11. **Sentiment funding cap (±0.012%/h) and per-resolution impulse cap (±15%) are storage-only.** Both captured in `FeedbackStorage` but no contract enforces them yet. Funding cap `F_max` (0.075%/h) similarly storage-only.

12. **Storage namespace pattern.** `keccak256("people.markets.<contract>.v1")` directly — no ERC-7201 hash-mixing. Project-doc design principle #4 specifies this exact form.

---

## 7. Decisions made without spec coverage

Cumulative across the prior audit + Session A + v2-audit fixes. Items added since the prior audit are marked *new*.

1. **Fee precision is parts-per-million (1e6), not basis points (1e4).** `TAKER_FEE_RATE = 750`, `MAKER_FEE_RATE = 250`. Avoids fractional-bps rounding without renaming the unit throughout.
2. **`pmUSDC` share decimals = 12 (USDC's 6 + 6-decimal virtual offset).** ERC-4626 inflation defense via OpenZeppelin's `_decimalsOffset()`.
3. **`freeAssets` computed by difference (`balanceOf − bookkeepers`).** Donation attacks neutralized: direct USDC transfers go to existing share-holders pro rata.
4. **Reentrancy guard: solady's transient-storage `ReentrancyGuard`.** ~3K gas saving over OZ on cancun-enabled chains.
5. **One position per `(trader, subject)`, no sign-flip in a single tx.** Drift's flip-bug class is real prior art.
6. **Position ID derivation: `keccak256(abi.encode(trader, subjectId, monotonic_nonce))`.** Nonce never reused even after full close; events stay correlatable.
7. **Mark-writer add is timelocked, revoke is immediate.** Symmetric to SubjectRegistry role grants.
8. **`setOperator` on LPVault is governance-only, NO timelock.** Operator's only power is pause flags; fast rotation is right for emergency.
9. **Closes are allowed during subject pauses.** Spec §6 line 365 implies wind-down. Generalized to all pause states; only `globalHalt` blocks closes.
10. **Mock USDC includes adversarial toggles.** Test infrastructure for proving production handles non-vanilla tokens.
11. **Governance timelock bounds: `[1 hour, 30 days]`.** Spec §3 ("48h timelock + multi-sig") gives 48h baseline.
12. **Initial role members in `SubjectRegistry.initialize` are granted without timelock.** Deployment is the moment of trust.
13. **PerpEngine uses `governance` for both timelocked actions and non-timelocked actions.** Same multi-sig acts at two speeds depending on the function.
14. **`UnderwaterClose` revert applies in both `LPVault.settlePosition` AND `PerpEngine.closePosition` paths.** Defense-in-depth.
15. **Fee residual (10%) flows to `accruedFees`** — treasury bucket inside the vault.
16. *(new)* **Forced settlement uses a push model**: governance captures a settlement mark on a DELISTED subject; traders permissionlessly claim via `closeAtForcedSettlement`. No on-chain iteration over open positions; ADL queueing deferred to LiquidationEngine.
17. *(new)* **`closeAtForcedSettlement` charges ZERO fee.** Forced settlement is a venue obligation, not a discretionary trade.
18. *(new)* **`forceSettleSubject` requires status == DELISTED.** Two-step audit trail (registry transition first, then engine capture). Engine does not read registry-internal state to infer eligibility.
19. *(new)* **MAX_INSURANCE_SEED = 10M USDC** (10× the spec's $1M initial seed). Generous floor-mechanic headroom; lifting requires UUPS upgrade. High friction by design.
20. *(new)* **`setLpRebatePct` bounds [25, 50] with no minimum residual.** Governance can zero treasury fees if they want to maximize LP yield.
21. *(new)* **`pendingFeeWithdrawal` is single in-flight.** Matches `pendingPerpEngine`. Queueing belongs upstream in a treasury contract.
22. *(new, v2 Fix #1)* **Forced-settlement underwater positions are capped at posted collateral.** Trader gets nothing on a wipe-out; LP gains the full collateral; the shortfall is unfunded LP loss until InsuranceFund/LiquidationEngine ships.
23. *(new, v2 Fix #3)* **OI cap denominator = `min(cappedTvl, freeAssets())`.** cappedTvl is updated by permissionless `pokeCappedTvl()` with a 60s cooldown. Conservative on both sides — same-block deposits can't inflate; sudden withdrawals immediately tighten.
24. *(new, v2 Fix #5)* **Default `markMaxDeltaBps = 1500` (15%).** Generous bound for legitimate volatility; bounds [100, 5000] for governance tuning. First push for a fresh subject is uncapped.
25. *(new, v2 Fix #7)* **SignedFeedAdapter uses the same timelocked propose/activate/cancel pattern as the rest of the suite for governance transfer.** Operator transfer remains single-step (narrow blast radius).

---

## 8. Open questions for the spec author

Numbered for response. Items resolved by Session A or v2 fixes are marked **resolved**.

1. *(resolved)* Closes during pauses → allowed in all pause states except `globalHalt`. v0 implementation matches.
2. *(resolved)* Vault TVL definition → `min(cappedTvl, freeAssets())` per v2 Fix #3.
3. **Spec §4 "automatic" degraded marking.** §4 line 242 says the OracleRouter automatically marks a metric degraded after 3× its expected refresh cadence. **Q: should we add per-`MetricConfig` cadence and a permissionless `markIfStale(metricId)` callable by anyone, OR keep operator-only with off-chain monitoring?** v0 still has only the operator path.
4. **Spec §4 signed payload includes `subjectId`.** **Q: is `subjectId` semantically part of the signed payload, or implicit in `metricId`?** v0 still treats it as implicit.
5. *(resolved)* 10% fee residual → treasury bucket (`accruedFees`), now withdrawable via timelocked `withdrawAccruedFees` flow per Session A Fix #5.
6. *(resolved)* Insurance fund seed mechanism → `seedInsurance(uint256)` per Session A Fix #6.
7. *(resolved)* Forced settlement on death/delist → `forceSettleSubject` + `closeAtForcedSettlement` shim per Session A Fix #7. v2 Fix #1 closes the underwater-collateral-strand follow-up issue.
8. *(resolved)* Auto-resume from `AUTO_PAUSED` → permissionless after 30s deadline per Session A Fix #8.
9. **20% net category OI cap.** Spec §3 line 123. **Q: does this live in MarginEngine alongside per-trader caps, or in its own contract? And what's the category-id source — `subjects[subjectId].categoryId`?** v0 still does not enforce.
10. *(resolved)* Sign-flip → forbidden via the one-position invariant. Documented.
11. *(resolved)* LP rebate decay → governance setter `setLpRebatePct` with bounds [25, 50] per Session A Fix #11.

**Net remaining open questions**: 3, 4, 9 (3 of 11). The first two are oracle infrastructure; the third is the next category-OI-cap implementation work, naturally landing with MarginEngine.

---

## 9. What's next

In order of priority. Effort estimates assume one focused session ≈ a working day.

1. **20% net-category OI cap** (open question #9). Add a `categoryNetOiBps` field to `MarginStorage`, plus a per-category accumulator that tracks `Σ (longOI − shortOI)` across subjects sharing a category. Enforcement in `_enforceOpenCaps` alongside the per-subject cap. Storage layout: subjects already carry `categoryId`. **Effort: 0.5 session.**

2. **Stage 1 degraded auto-detection** (open question #3). Add a per-`MetricConfig` `expectedCadenceSeconds` field and a permissionless `markIfStale(metricId)` that flips `degraded` when `valueTimestamp + 3 × cadence < block.timestamp`. Operator path stays as the fast lever. **Effort: 0.5 session.**

3. **InsuranceFund cap + treasury top-up flow.** Spec §3 calls for the 10% TVL cap on the insurance fund (excess flows to LPs as share-price boost) and a 5% TVL floor with treasury matching. Adds two governance hooks on LPVault. **Effort: 0.5 session.**

4. **Begin FundingEngine v0** (week 8–9 on the implementation order). `FundingMath` library + `FundingEngine` contract; wires the `Position.entryFundingIndex` field that's already reserved. Funding accrual gated by `FundingStorage.frozen` flag during pauses (per spec §3 line 64–66). **Effort: 2 sessions.**

5. **LiquidationEngine v0** (week 14+). The 5-tier waterfall is the hard mainnet launch gate (deviation #4 — voluntary close into negative equity reverts and v0 has no liquidation path). Until LiquidationEngine ships, mainnet must NOT open. **Effort: 3-4 sessions.**

Liquidation engine, feedback controller, pair-trade router, and Chainlink/UMA adapters remain in their original positions on the timeline. The `pre-mainnet 100M+ invariant runs` scaling work (sharded CI matrix) is operational and tracked separately.

---

*End of audit refresh.*
