# Implementation Audit — pm-contracts

**As of commit `367170c` on `main`.** Verification only; no new code in this pass.

`forge test`: **382 passed, 0 failed, 0 skipped** across 6 suites (run cold for this audit).
`forge coverage --ir-minimum`: totals **97.95% line / 99.47% branch / 98.36% func**.

The spec lives at `mechanismdesign.md` in this repo (the prompt referred to it as `People_Markets_Mechanism_Design.md`; it's the same document).

---

## 1. Scope completed

| Path | Status | Solidity LoC* | Coverage (line / branch) | `forge test` |
|---|---|---:|---|---|
| `src/libraries/PositionMath.sol` | complete · tested | 33 | 100% / 100% | pass (30 tests) |
| `src/libraries/StorageLib.sol` | complete (8 namespaces declared; 4 unused) | 201 | 41.67% / 100% (Funding/Liquidation/Feedback unused) | n/a — pure storage |
| `src/oracle/IOracleAdapter.sol` | complete | 5 | n/a (interface) | n/a |
| `src/oracle/IOracleRouter.sol` | complete | 44 | n/a | n/a |
| `src/oracle/OracleRouter.sol` | complete · tested | 127 | 98.89% / 100% (one constructor line under `--ir-minimum`) | pass (39 tests) |
| `src/oracle/SignedFeedAdapter.sol` | complete · tested | 217 | 100% / 100% | pass (50 tests) |
| `src/registry/ISubjectRegistry.sol` | complete | 104 | n/a | n/a |
| `src/registry/SubjectRegistry.sol` | complete · tested | 321 | 99.58% / 100% | pass (88 tests) |
| `src/core/IPerpEngine.sol` | complete | 124 | n/a | n/a |
| `src/core/ILPVault.sol` | complete | 95 | n/a | n/a |
| `src/core/LPVault.sol` | complete · tested | 316 | 98.32% / 100% (constructor / fall-through under `--ir-minimum`) | pass (69 tests) |
| `src/core/PerpEngine.sol` | complete · tested | 499 | 99.69% / 98.46% | pass (106 tests) |

*Approximate, computed by stripping single-line `//`, block-comment markers, and blank lines. Not a normative LoC; the actual code under audit is the file content.

**Not yet started** (week-8+ on the implementation order):
- `src/core/MarginEngine.sol`
- `src/core/FundingEngine.sol`
- `src/core/LiquidationEngine.sol`
- `src/core/InsuranceFund.sol`
- `src/core/PauseGuardian.sol`
- `src/routers/PairTradeRouter.sol`
- `src/routers/BatchRouter.sol`
- `src/feedback/FeedbackController.sol`
- `src/oracle/ChainlinkAdapter.sol`
- `src/oracle/UMAAdapter.sol`
- `src/libraries/FundingMath.sol`
- `src/libraries/LiquidationMath.sol`

---

## 2. Spec compliance — line by line

Status legend: **identical** = exact value/formula; **equivalent** = numerically identical with a different unit/encoding (and noted); **deviates** = differs from spec, see §6; **deferred** = mechanism not in scope this session, no code yet; **partial** = primitive present but full mechanism not wired.

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

> `P_mark(t+1) = P_mark(t) + ΔP_flow(t) + ΔP_impulse(t)`
> `ΔP_flow(t) = k_impact × (trade_size / vault_depth_for_subject) × P_mark(t)`
> `ΔP_impulse(t) = P_mark(t) × c_event × outcome × (1 - late_move_discount)`

| Term | Implementation | Status |
|---|---|---|
| Mark evolution as a state-equation | mark price is a single `uint256` per subject, written by permissioned `markWriters` via `PerpEngine.pushMark`. The contract does **not** compute `ΔP_flow` or `ΔP_impulse`. The composition is performed off-chain and pushed in. | **deviates intentionally** — see §6 |
| `c_event`, `outcome`, `late_move_discount` | not computed on-chain | **deferred** |

### 2.3 §2 funding-rate formula (spec lines 47–60)

> `F(t) = clamp(k_premium × (P_mark - P_index)/P_index + k_sentiment × sentiment + k_skew × (longOI - shortOI)/totalOI, -F_max, +F_max)`

| Term | Implementation | Status |
|---|---|---|
| Funding accrual per subject | `FundingStorage` namespace declared (`cumulativeFundingIndex`, `lastFundingAt`, `frozen`); no FundingEngine contract yet | **deferred** |
| `entryFundingIndex` reserved on `Position` | yes — `IPerpEngine.Position.entryFundingIndex` is `int256`, defaulted to 0 by `openPosition` | **partial (storage primitive only)** |
| Funding-during-pauses: index frozen at pause timestamp | spec lines 64–66; `FundingStorage.frozen` flag declared but not enforced (no FundingEngine) | **deferred** |
| `liquidity_factor_i = 0` if `OI_i < $25K` | reserved as `FundingStorage.minEventOiForSentiment` | **deferred** |

### 2.4 §2 per-event-category impulse coefficients (spec lines 81–89)

| Class | Spec positive | Spec negative (1.5×) | Implementation |
|---|---|---|---|
| Major | +0.04 to +0.08 | -0.06 to -0.12 | not implemented |
| Standard | +0.02 to +0.04 | -0.03 to -0.06 | not implemented |
| Minor | +0.005 to +0.01 | -0.0075 to -0.015 | not implemented |

`FeedbackStorage.coefficients[EventClass]` namespace exists; contents zero. **Status: deferred (FeedbackController, week 10–13).**

The 1.5× asymmetry is documented in `FeedbackStorage` but not enforced by any code path yet.

### 2.5 §3 position limits (spec lines 120–129)

| Spec | Spec value | Implementation | Status |
|---|---|---|---|
| Max OI per subject (one side) | 5% of vault TVL | `MarginStorage.perSubjectSideOiCapBps`, default `500` (5%); enforced in `PerpEngine._enforceOpenCaps`. "Vault TVL" reads as `IERC4626.totalAssets()`, which in `LPVault` returns `freeAssets()` — see §6 deviation #2 | **deviates** (vault-TVL definition; numerically conservative) |
| Max net OI per category | 20% of vault TVL | not implemented; no per-category OI tracking | **not yet implemented** |
| Max position per trader per subject | `$50K × KYC tier` (T1=$50K, T2=$250K, T3=$1M) | `MarginStorage.tierPerSubjectCap[KycTier]`; **values are governance-set**, not hardcoded. `PerpEngine.initialize` does not set them — caller (deploy script / test setUp) must call `setKycCaps(tier, perSubjectCap, combinedCap)` per tier | **identical (configurable)** |
| Max combined exposure per trader | `$200K × KYC tier` | `MarginStorage.tierCombinedCap[KycTier]`; same configurable shape. Cross-margin event component (`totalEventExposure`) is reserved on `AccountExposure` but not yet summed in (no event positions exist) | **partial** (perp half wired; event half deferred) |
| Max leverage | 5× | `MarginStorage.maxLeverageBps = 50_000`; enforced in `openPosition` and `removeCollateral` | **identical** |
| Initial Margin | 20% of notional | `MarginStorage.initialMarginBps = 2_000`; enforced in `openPosition` and `removeCollateral` | **identical** |
| Maintenance Margin | 5% of notional | `MarginStorage.maintenanceMarginBps = 500`; **read by views only** (`isMarginOk`). Not yet enforced as a state-changing trigger because LiquidationEngine is deferred | **partial** (value present; liquidation enforcement absent) |
| Liquidation buffer | 2.5% of notional | `MarginStorage.liquidationBufferBps = 250`; reserved, no enforcement yet | **partial** |

### 2.6 §3 fee structure (spec lines 133–139)

| Spec | Spec value | Implementation | Status |
|---|---|---|---|
| Perp taker | 0.075% | `PerpEngine.TAKER_FEE_RATE = 750` with `FEE_RATE_DENOM = 1e6`. 750/1e6 = 0.00075 = 0.075% | **equivalent** (ppm encoding — see §7 decision #1) |
| Perp maker | 0.025% | `PerpEngine.MAKER_FEE_RATE = 250`. 250/1e6 = 0.025% | **equivalent** |
| Event contract | 1.0% | not implemented (event markets deferred) | **deferred** |
| Funding rate take | 8% | not implemented (funding deferred) | **deferred** |
| LP rebate | 40% perp / 30% event (decreasing to 30%/25%) | `PerpEngine.LP_REBATE_PCT = 40` (perp). **Hardcoded at 40%; the 6-month decay path is not implemented.** Event rebate not implemented. | **deviates** — see §6 deviation #3 |

Insurance share: `INSURANCE_PCT = 50`. Residual = `fee − lpRebate − insuranceShare = 10%`. Spec calls for "50% of trading fees" to insurance and 40% LP rebate; the 10% residual is unspecified (it goes to `accruedFees` → treasury bucket). **See §8 question #5.**

### 2.7 §3 liquidation waterfall (spec lines 141–155)

| Tier | Spec | Implementation |
|---|---|---|
| Tier 1 — Partial liquidation, 25% increments, min 4 attempts, restore to MM + 100bps | `LiquidationStorage` declares `partialIncrementBps`, `minPartialsBeforeFull`, `mmRestoreBufferBps`; **no LiquidationEngine contract; no execution path** | **not yet implemented** |
| Tier 2 — Full liquidation, 1% liquidator bounty | `LiquidationStorage.fullLiquidationBountyBps` reserved; no execution | **not yet implemented** |
| Tier 3 — Insurance fund covers shortfall | bucket exists in `VaultStorage.insuranceFundBalance`; no shortfall flow | **partial (bucket only)** |
| Tier 4 — LP socialization, 30% TVL cap | `LiquidationStorage.lpSocializationCapBps` reserved; no execution | **not yet implemented** |
| Tier 5 — ADL, priority by `unrealizedPnL × leverage` | not implemented; no priority queue | **not yet implemented** |

`PerpEngine.closePosition` reverts with `UnderwaterClose` if a voluntary close would settle into negative equity — explicit defer-to-liquidation-engine decision. See §6 deviation #4.

### 2.8 §3 insurance fund (spec lines 157–163)

| Spec | Implementation | Status |
|---|---|---|
| Initial seed: $1M from treasury at launch | not implemented; must be performed by deploy script (governance can't transfer in arbitrary funds — `lockCollateral` requires PerpEngine caller). **See §8 question #6.** | **not yet implemented** |
| Ongoing replenishment: 50% of trading fees until cap | `INSURANCE_PCT = 50`; on every `openPositionFlow` and `settlePosition`, vault increments `insuranceFundBalance` by `(fee × 50%)`. **Cap is not checked.** | **partial — accrual yes, cap no** |
| Cap: 10% of vault TVL — excess to LPs as share-price boost | not implemented | **not yet implemented** |
| Floor: <5% TVL → treasury top-up to ceiling, no rebate change | not implemented | **not yet implemented** |
| Governance: separate multi-sig from operations, with timelock and rationale | the vault tracks `insuranceFundBalance` but does **not** expose any withdrawal function. There is no separate `InsuranceFundManager` role in v0 (was in earlier `VaultStorage` design; removed during v0 simplification). | **not yet implemented** |

### 2.9 §3 pause and circuit-breaker thresholds (spec lines 165–176)

| Spec trigger | Spec effect | Implementation |
|---|---|---|
| 5% mark move in 30s | 30s pause; auto-resume | `SubjectStatus.AUTO_PAUSED` exists; `setAutoPaused(subjectId, reasonCode)` callable by `pauseGuardian`. **Threshold detection is NOT on-chain — caller decides when to flip.** Auto-resume is also NOT automatic — `unpauseAuto` must be called. **See §8 question #8.** |
| 10% mark move in 30 min | 5 min pause; admin review | `SubjectStatus.COOLDOWN`; same shape — manual flip + manual unpause |
| 20% mark move in 1 hour | 15 min pause; admin review required | `SubjectStatus.FROZEN`; same shape, `setFrozen` requires `subjectAdmin` (admin review encoded in role) |
| Subject opt-out | 7-day close window, then forced settlement | `requestDelisting` sets `delistingForceSettleAt = block.timestamp + 7 days`; `forceSettle` is permissionless once elapsed. ✓ |
| Death/incapacitation, oracle-confirmed | Immediate forced settlement at last fair mark before news | `flagDeathPending` sets a 24h pending window; `confirmDeath` (admin) → `DELISTED`; `clearDeathPending` (permissionless after 24h) → `ACTIVE`. **"Forced settlement at last fair mark" is not implemented at the engine level** — DELISTED status blocks new opens but does not force-close existing positions or freeze the mark. **See §8 question #7.** |
| Involuntary delisting (legal/regulatory) | Immediate forced settlement at last pre-action mark | `involuntaryDelist` (admin) flips status to `DELISTED`. Same gap as above — no forced-close flow. |

> Spec line 176: "During pauses: no new positions, no liquidations, no funding accrual, no event-impulse application."

| Effect | Implementation |
|---|---|
| No new positions | `openPosition` calls `subjectRegistry.requireTradeable(subjectId)` which reverts on any non-`ACTIVE` status. ✓ |
| No liquidations | n/a in v0 (no liquidation engine) |
| No funding accrual | n/a in v0 (no funding engine; primitive `FundingStorage.frozen` reserved) |
| No event-impulse application | n/a in v0 (no feedback controller) |

### 2.10 §5 late-move discount formula (spec lines 285–289)

> `late_move = max(0, |price(t_resolution) - price(t_resolution - 24h)|)`
> `late_move_factor = late_move / 0.5`
> `discount = min(0.5, late_move_factor × 0.6)`

`FeedbackStorage` reserves `lateMoveDenominator`, `discountSlope`, `maxDiscount`. **No code computes the discount yet; FeedbackController is week 10–13.**

**Status: deferred.**

### 2.11 §5 cross-margining (spec lines 305–315)

> `total_exposure(trader, subject) = perp_notional + Σ event_position_i × correlation_i × c_event_xm`
> `c_event_xm = 0.25 (starting value, range 0.20-0.40)`
> `constraint: total_exposure ≤ kyc_tier_limit(trader)`

| Term | Implementation |
|---|---|
| Perp half of `total_exposure` | `MarginStorage.exposure[trader].totalPerpNotional` summed and capped against `tierCombinedCap[KycTier]` in `PerpEngine._enforceOpenCaps`. ✓ |
| Event half (`Σ event_position_i × correlation × c_event_xm`) | `AccountExposure.totalEventExposure` field reserved; never written. **Cap check currently uses only the perp half.** |
| `c_event_xm = 0.25` | `MarginStorage.crossMarginMultiplier` reserved (uninitialized). |
| Range 0.20-0.40 | not enforced anywhere |

**Status: partial — perp half only.**

### 2.12 §5 resolution magnitude vs unresolved sentiment (spec line 343)

> "Live event sentiment contributes max ±0.012%/h to funding (~10% of typical funding). Resolution impulses apply directly to mark, capped at ±15% per resolution."

The ±0.012%/h sentiment cap and the ±15% impulse cap are not enforced — both belong to the deferred funding/feedback contracts.

### 2.13 §1 / §3 mark staleness (30s) and ±15% per-resolution impulse cap

| Spec | Implementation |
|---|---|
| 30s mark staleness on trades | `PerpStorage.markStaleAfter` defaults to `30 seconds` in `initialize`; enforced on every `openPosition`, `closePosition`, `removeCollateral` via `_readFreshMark`. Bounds `[5s, 1h]` for governance changes. ✓ |
| ±15% per-resolution impulse cap | `FeedbackStorage.impulseCapBps` reserved (uint16, intended `1500`). No enforcement (deferred). |

### 2.14 §6 subject delisting and policy

| Spec | Implementation |
|---|---|
| Voluntary opt-out, 7-day close window, then force-settlement | `SubjectRegistry.requestDelisting` + `forceSettle`. ✓ |
| Death/incapacitation, 24h halt, confirmed → forced settlement | `flagDeathPending` + `confirmDeath` + permissionless `clearDeathPending`. ✓ |
| Involuntary (legal/regulatory), immediate | `involuntaryDelist`. ✓ |
| Markets on minors: catalog hard block | `PolicyFlag.MINOR` exists; `listSubject` rejects if `subj.policyFlag != NONE`. Catalog ↔ on-chain: the on-chain check is defense-in-depth. ✓ |
| US politicians in election years: catalog block | `PolicyFlag.US_POLITICIAN_ELECTION_YEAR` exists; same enforcement path. ✓ |

### 2.15 §4 oracle stack

| Spec | Implementation |
|---|---|
| Three sources: Chainlink, UMA, Signed | `IOracleRouter.SourceType` has `CHAINLINK`, `UMA`, `SIGNED` (plus `UNSET`). Only `SignedFeedAdapter` is shipped. | **partial** |
| Per-metric configuration via `OracleRouter` | `OracleRouter.proposeRegister` / `activateRegister` (timelocked); `MetricConfig` carries source, adapter, fallback, staleAfter, maxDeltaBps, degraded flag. ✓ |
| 3-of-5 EIP-712 signed feeds | `SignedFeedAdapter.SIGNER_COUNT = 5`, `THRESHOLD = 3`. Distinct ECDSA recoveries via solady; ascending-index check enforces unique signers. ✓ |
| Lazy evaluation (push only when needed) | Anyone may submit; signature gate is the security boundary. ✓ |
| Stage 1 — Degraded after 3× cadence (automatic) | `setDegraded(metricId, bool, reasonHash)` is **operator-controlled, not automatic**. A keeper bot off-chain must call. | **deviates** — see §6 deviation #5 |
| Stage 2 — Substituted after 14 days, governance vote, 48h announcement | governance can replace fallback / full config via timelocked `proposeSetFallback` / `proposeRegister`. **The 14-day requirement, the dedicated "substitute" path, and the 48h announcement window are not modeled.** The default timelock is governance-configurable in `[1h, 30d]`. | **deviates / partial** |
| Stage 3 — Permanent removal, 7-day position close window | not implemented | **not yet implemented** |
| Composite (Person Index) Merkle proof | `OracleRouter` treats each metric atomically by `metricId`; composite Person Index is registered as a single SIGNED metric whose value is derived off-chain. **No on-chain Merkle proof / challenge path.** | **deviates** — see §6 deviation #6 |
| TWAP on index-component metrics (1h minimum) | not enforced on-chain. The signed payload carries a single `(value, valueTimestamp)` pair. | **deferred** |
| EIP-712 domain | `name = "PeopleMarketsSignedFeed"`, `version = "1"`, includes chainId + verifyingContract via solady's `EIP712`. Type hash: `SignedUpdate(bytes32 metricId,uint256 value,uint64 valueTimestamp,uint64 nonce)`. **Note: spec's signed tuple includes `subjectId` separately; ours does not — see §6 deviation #7.** | **deviates** |

### 2.16 §3 LP yield expectations / single-vault decision

LP yield model is an off-chain expectation; not directly verifiable in code. The single-vault architecture is in place (one `LPVault` is counterparty to all positions). The v1.5 vault-split branching is not implemented.

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

`Position` struct (defined in `IPerpEngine`, used here): `int256 size, uint256 collateral, uint256 entryPrice, int256 entryFundingIndex, uint64 openedAt, uint64 lastInteractionAt, address owner, bytes32 subjectId`. **No struct packing** — each field takes its own slot.

### 3.2 `MarginStorage` — slot `keccak256("people.markets.margin.v1")`

Used by `PerpEngine` (read+write).

| Field | Type | Purpose |
|---|---|---|
| `exposure` | `mapping(address => AccountExposure)` | per-trader cross-margin state |
| `tierCombinedCap` | `mapping(KycTier => uint256)` | per-tier $ cap for combined exposure |
| `tierPerSubjectCap` | `mapping(KycTier => uint256)` | per-tier per-subject $ cap |
| `crossMarginMultiplier` | `uint256` | `c_event_xm`, 1e18 scale (uninitialized) |
| `initialMarginBps` | `uint16` | default 2000 |
| `maintenanceMarginBps` | `uint16` | default 500 |
| `liquidationBufferBps` | `uint16` | default 250 |
| `maxLeverageBps` | `uint16` | default 50000 |
| `perSubjectSideOiCapBps` | `uint16` | default 500 |

`AccountExposure`: `uint256 totalPerpNotional, uint256 totalEventExposure, KycTier tier`.

`KycTier` enum: `NONE, T1, T2, T3`.

The four `uint16`s + the trailing one would pack into a single 256-bit slot (10 bytes); they sit at the end of the struct so packing is deterministic.

### 3.3 `VaultStorage` — slot `keccak256("people.markets.vault.v1")`

Used by `LPVault` (read+write).

| Field | Type | Purpose |
|---|---|---|
| `positionCollateral` | `uint256` | locked collateral bucket |
| `accruedFees` | `uint256` | residual treasury fees |
| `insuranceFundBalance` | `uint256` | insurance bucket |
| `perpEngine` | `address` | sole operator allowed to move collateral / book fees |
| `governance` | `address` | timelocked admin |
| `timelockDelay` | `uint32` | seconds |
| `pendingPerpEngine` / `pendingPerpEngineActivatesAt` | `address` / `uint64` | timelocked rotation |
| `pendingGovernance` / `pendingGovernanceActivatesAt` | `address` / `uint64` | timelocked transfer |
| `operator` | `address` | fast pause lever |
| `depositsPaused` | `bool` | LP deposit gate |
| `withdrawalsPaused` | `bool` | LP withdrawal gate |

`freeAssets` is **computed**: `IERC20(asset()).balanceOf(this) − positionCollateral − insuranceFundBalance − accruedFees`. Always saturating at zero (returns 0 if invariant break).

### 3.4 `OracleStorage` — slot `keccak256("people.markets.oracle.v1")`

Used by `OracleRouter` (read+write).

| Field | Type | Purpose |
|---|---|---|
| `configs` | `mapping(bytes32 => MetricConfig)` | active per-metric routing |
| `pending` | `mapping(bytes32 => PendingChange)` | timelocked register/replace proposals |
| `pendingFallback` / `pendingFallbackActivatesAt` | maps | timelocked fallback rotation |
| `governance` | `address` | timelocked admin |
| `operator` | `address` | fast lever, `setDegraded` only |
| `timelockDelay` | `uint32` | seconds |

`MetricConfig` (in `IOracleRouter`): `SourceType sourceType, address adapter, address fallbackAdapter, uint32 staleAfter, uint32 maxDeltaBps, bool degraded`.

### 3.5 `RegistryStorage` — slot `keccak256("people.markets.registry.v1")`

Used by `SubjectRegistry` (read+write).

| Field | Type | Purpose |
|---|---|---|
| `subjects` | `mapping(bytes32 => ISubjectRegistry.Subject)` | per-subject lifecycle record |
| `kycTier` | `mapping(address => uint8)` | 0–3, mirrored from off-chain pipeline |
| `governance` | `address` | timelocked admin |
| `timelockDelay` | `uint32` | seconds |
| `pendingGovernance` / `pendingGovernanceActivatesAt` | maps | timelocked transfer |
| `subjectAdmins` / `pauseGuardians` / `kycWriters` | `mapping(address => bool)` | role sets |
| `pendingRoleChanges` | `mapping(bytes32 changeKey => PendingRoleChange)` | timelocked grant/revoke; key = `keccak(account, role)` |

`Subject` struct: `SubjectStatus status, PolicyFlag policyFlag, uint64 listedAt, uint64 statusChangedAt, bytes32 categoryId, uint64 deathPendingExpiresAt, uint64 delistingForceSettleAt`.

### 3.6 Reserved namespaces (declared but no contract reads/writes them yet)

| Namespace | Purpose |
|---|---|
| `keccak256("people.markets.funding.v1")` | `FundingStorage` — funding accrual (week 8–9) |
| `keccak256("people.markets.liquidation.v1")` | `LiquidationStorage` — partial-liquidation state (week 14+) |
| `keccak256("people.markets.feedback.v1")` | `FeedbackStorage` — event-impulse coefficients (week 10–13) |

---

## 4. Interfaces and external calls

I list every external/public function. For brevity I show access control, primary state effect, and primary event. Storage namespaces are abbreviated `Perp` / `Margin` / `Vault` / `Oracle` / `Registry`.

### 4.1 `OracleRouter` (UUPS proxy)

| Function | Access | Reads | Writes | Event |
|---|---|---|---|---|
| `initialize(governance, operator, timelockDelay)` | initializer | — | `Oracle.{governance, operator, timelockDelay}` | — |
| `proposeRegister(metricId, config)` | `governance` | `Oracle.pending[id]` | `Oracle.pending[id]` | `MetricProposed` |
| `activateRegister(metricId)` | permissionless after timelock | `Oracle.pending[id]` | `Oracle.configs[id]`, clears pending | `MetricActivated` |
| `cancelProposal(metricId)` | `governance` | `Oracle.pending[id]` | clears pending | `ProposalCancelled` |
| `setDegraded(metricId, bool, reasonHash)` | `operator` | `Oracle.configs[id]` | `Oracle.configs[id].degraded` | `MetricDegraded` |
| `proposeSetFallback(metricId, addr)` | `governance` | `Oracle.configs[id]` | `Oracle.pendingFallback[id]`, `Oracle.pendingFallbackActivatesAt[id]` | `FallbackProposed` |
| `activateSetFallback(metricId)` | permissionless after timelock | pending | `Oracle.configs[id].fallbackAdapter` | `FallbackActivated` |
| `read(metricId) view → OracleReading` | public | `configs`, dispatches to adapter | — | — |
| `configOf(metricId) view → MetricConfig` | public view | configs | — | — |
| `pendingOf(metricId) view` | public view | pending | — | — |
| `pendingFallbackOf(metricId) view` | public view | pending | — | — |
| `governance() / operator() / timelockDelay() view` | public view | accessor | — | — |
| `_authorizeUpgrade(addr)` | `governance` | — | — | UUPS event |

### 4.2 `SignedFeedAdapter` (non-upgradeable)

| Function | Access | Reads | Writes | Event |
|---|---|---|---|---|
| constructor(router, governance, operator, timelockDelay, initialSigners) | — | — | sets all immutables/state | — |
| `pushUpdate(metricId, value, valueTimestamp, nonce, sigs[])` | permissionless (signature gate) | `router.configOf(id)`, `latest[id]`, `signers` | `latest[id]` | `Pushed` |
| `readMetric(metricId) view → OracleReading` | public view | `latest[id]` | — | — |
| `proposeSignerRotation(newSigners)` | `governance` | `pendingExists` | `pendingSigners`, `pendingActivatesAt`, `pendingExists` | `SignerRotationProposed` |
| `activateSignerRotation()` | permissionless after timelock | pending | `signers`, clears pending | `SignerRotationActivated` |
| `cancelSignerRotation()` | `governance` | pending | clears pending | `SignerRotationCancelled` |
| `setPaused(bool)` | `operator` | — | `paused` | `PausedSet` |
| `transferGovernance(addr)` / `transferOperator(addr)` | `governance` | — | role addr | `GovernanceTransferred` / `OperatorTransferred` |
| `getSigners() / getPendingSigners() / readingOf() view` | public view | — | — | — |

Reentrancy: not gated on this contract (signed pushes are pure state writes; no external calls beyond the router config read).

### 4.3 `SubjectRegistry` (UUPS proxy)

| Function | Access | Effect |
|---|---|---|
| `initialize(gov, timelock, admins[], guardians[], writers[])` | initializer | Bootstraps role sets without timelock |
| `listSubject(subjectId, categoryId)` | `subjectAdmin` | `UNREGISTERED → ACTIVE`; reverts on existing or `policyFlag != NONE` |
| `setPolicyFlag(subjectId, flag)` | `subjectAdmin` | writes `subjects[id].policyFlag` |
| `requestDelisting(subjectId)` | `subjectAdmin` | sets status to `DELISTING`, sets `delistingForceSettleAt = now + 7 days` |
| `forceSettle(subjectId)` | permissionless after window | `DELISTING → DELISTED` |
| `involuntaryDelist(subjectId)` | `subjectAdmin` | → `DELISTED` immediate |
| `flagDeathPending(subjectId)` | `subjectAdmin` | → `DEATH_PENDING`, sets 24h window |
| `confirmDeath(subjectId)` | `subjectAdmin` | → `DELISTED` |
| `clearDeathPending(subjectId)` | permissionless after 24h | → `ACTIVE` |
| `setAutoPaused(subjectId, reasonCode)` | `pauseGuardian` | `ACTIVE → AUTO_PAUSED` |
| `setCooldown(subjectId, reasonCode)` | `pauseGuardian` | `ACTIVE → COOLDOWN` |
| `setFrozen(subjectId, reasonCode)` | `subjectAdmin` | `ACTIVE → FROZEN` |
| `unpauseAuto / unpauseCooldown / unpauseFrozen` | guardian / admin / admin | → `ACTIVE` |
| `setKycTier(trader, tier)` | `kycWriter` | writes `kycTier[trader]` |
| `proposeRoleChange(account, role, grant)` | `governance` | timelocked add/remove |
| `activateRoleChange(account, role)` | permissionless after timelock | mutates role set |
| `cancelRoleChange(account, role)` | `governance` | clears pending |
| `proposeGovernanceTransfer / activate / cancel` | governance / permissionless / governance | timelocked |
| Views: `subjectOf, statusOf, isTradeable, requireTradeable, kycTierOf, isAdmin, isPauseGuardian, isKycWriter, governance, timelockDelay, pendingGovernance, pendingRoleOf` | public view | — |
| `_authorizeUpgrade(addr)` | `governance` | UUPS |

### 4.4 `LPVault` (UUPS proxy, ERC-4626)

Inherited ERC-4626: `deposit, mint, withdraw, redeem, totalAssets, convertToShares, convertToAssets, previewDeposit/Mint/Withdraw/Redeem, maxDeposit/Mint/Withdraw/Redeem, asset, decimals`. `totalAssets()` is **overridden to return `freeAssets()`**.

| Function | Access | Effect |
|---|---|---|
| `initialize(usdc, gov, operator, timelockDelay, name, symbol)` | initializer | Bootstraps. PerpEngine address is left zero — set later via timelock. |
| `depositWithMinShares(assets, receiver, minShares)` | public | wraps `deposit`; reverts if shares < min |
| `withdrawWithMaxAssets(shares, receiver, owner, maxAssets)` | public | wraps `redeem`; reverts if assets > max |
| `openPositionFlow(trader, collat, fee, lpRebate, insuranceShare)` | `perpEngine` | pulls `collat + fee` USDC; books buckets; `nonReentrant` |
| `settlePosition(trader, collatToRelease, pnl, fee, lpRebate, insuranceShare)` | `perpEngine` | books buckets; pushes `returned` to trader; reverts on `UnderwaterClose` |
| `lockCollateral(from, amount)` | `perpEngine` | atomic pull + book |
| `releaseCollateral(to, amount)` | `perpEngine` | atomic book release + push |
| `proposeSetPerpEngine(addr) / activate / cancel` | gov / permissionless / gov | timelocked |
| `proposeGovernanceTransfer / activate / cancel` | gov / permissionless / gov | timelocked |
| `setDepositsPaused(bool) / setWithdrawalsPaused(bool)` | `operator` | flips bool |
| `setOperator(addr)` | `governance` | **no timelock** (narrow blast radius — see §7 decision) |
| Views: `freeAssets, positionCollateral, insuranceFundBalance, accruedFees, depositsPaused, withdrawalsPaused, perpEngine, operator, governance, timelockDelay, pendingPerpEngine, pendingGovernance` | public view | — |
| `_authorizeUpgrade` | `governance` | UUPS |

Events: `CollateralLocked, CollateralReleased, PositionOpenedOnVault, PositionSettledOnVault, PerpEngineProposed/Activated/Cancelled, GovernanceTransferProposed/Activated/Cancelled, OperatorSet, DepositsPausedSet, WithdrawalsPausedSet`.

### 4.5 `PerpEngine` (UUPS proxy)

| Function | Access | Effect |
|---|---|---|
| `initialize(gov, timelockDelay, registry, vault)` | initializer | Bootstraps; seeds margin params with §3 defaults. |
| `openPosition(OpenParams)` | public, KYC-gated, `nonReentrant` | All §3 caps, IM, leverage, slippage, mark-staleness; calls `vault.openPositionFlow`; writes `Position` and OI. |
| `closePosition(CloseParams) → realizedPnl` | public position-owner, `nonReentrant` | Reverts on `globalHalt` (closes pass through subject pauses); reverts `UnderwaterClose` if equity < 0. |
| `addCollateral(subjectId, amount)` | public position-owner, `nonReentrant` | Pulls + books; reverts on `globalHalt`. |
| `removeCollateral(subjectId, amount)` | public position-owner, `nonReentrant` | Re-checks IM and leverage; rejects if equity ≤ 0. |
| `pushMark(subjectId, newMark)` | `markWriters` | sets `markPrice`, `markUpdatedAt`. **Allowed during pauses**. |
| `setGlobalHalt(bool)` | `governance` (no timelock) | flips kill-switch |
| `proposeAddMarkWriter(addr) / activate / cancel` | gov / permissionless / gov | timelocked |
| `removeMarkWriter(addr)` | `governance` (no timelock) | fast revoke |
| `setMarginParams(im, mm, buf, maxLev)` | `governance` (no timelock) | bounds-checked; `mm < im` enforced |
| `setKycCaps(tier, perSubjectCap, combinedCap)` | `governance` (no timelock) | tier ∈ {1,2,3}; `combinedCap ≥ perSubjectCap` |
| `setPerSubjectSideOiCapBps(bps)` | `governance` (no timelock) | bounds [1, 5000] |
| `setMarkStaleAfter(seconds)` | `governance` (no timelock) | bounds [5s, 1h] |
| `proposeGovernanceTransfer / activate / cancel` | gov / permissionless / gov | timelocked |
| Views: `positionOf, positionIdOf, markOf, openInterestOf, equityOf, marginRatioBpsOf, leverageBpsOf, isMarginOk, isMarkWriter, globalHalt, governance, timelockDelay, markStaleAfter, pendingMarkWriterActivatesAt, pendingGovernance, lpVault, subjectRegistry, marginParams, tierCaps, exposureOf` | public view | — |
| `_authorizeUpgrade` | `governance` | UUPS |

Events: `PositionOpened, PositionClosed, CollateralAdded, CollateralRemoved, MarkPushed, GlobalHaltSet, MarkWriterAdded/Removed/AddProposed/AddCancelled, MarginParamsSet, KycCapsSet, MarkStaleAfterSet, GovernanceTransferProposed/Activated/Cancelled`.

---

## 5. Invariants implemented as tests

The project doc names invariants I1–I10. **None of them are implemented as Foundry-invariant handler tests yet.** Coverage of related properties exists in unit tests but those are deterministic, not fuzz-driven. Status:

| ID | Spec invariant | Foundry-invariant test? | Test file / function | Last result |
|---|---|---|---|---|
| I1 | Vault solvency: `LPVault.totalAssets() ≥ Σ open position effective collaterals + insurance fund + outstanding fee accrual` | **No** | (closest deterministic check: `LPVault.t.sol::test_FreeAssets_TracksBalanceMinusBookkeepers` and the inflation/donation tests verify the bucket arithmetic) | n/a — invariant test not written |
| I2 | Position consistency: `position.size != 0 → position.collateral > 0` | **No** | (open path enforces `collateralAmount > 0` and IM; partial close prorates collateral. No invariant fuzzer.) | n/a |
| I3 | OI conservation per subject | **No** | Unit tests verify `openInterestOf` after open/close. Sum-of-positions vs OI not fuzzed. | n/a |
| I4 | Funding index monotonicity (sign-aware) | **No** | Funding engine deferred. | n/a |
| I5 | Margin coverage: `collateral + uPnl > 0` OR mid-liquidation | **No** | `closePosition` reverts `UnderwaterClose` for voluntary closes, but fuzz coverage absent. | n/a |
| I6 | Cross-margin conservation | **No** | Event half not implemented. | n/a |
| I7 | Mark staleness: no trade against >30s mark | **No** | `test_OpenPosition_RevertOnMarkStale`, `test_ClosePosition_RevertOnStaleMark` exist as unit cases. | n/a |
| I8 | Pause respect: no state-changing op against paused subject | **No** | Unit tests cover pause-path reverts on open and the closes-allowed case. | n/a |
| I9 | Impulse boundedness | **No** | Feedback controller deferred. | n/a |
| I10 | ADL fairness (deterministic priority) | **No** | Liquidation engine deferred. | n/a |

**Summary: 0 of 10 invariants are running as Foundry-invariant tests.** The unit tests exercise the same properties as deterministic single-path cases, but the project doc explicitly calls for "100M+ invariant test runs with no violations" pre-mainnet (§8 Testing). That work is queued for the integration-tests session.

---

## 6. Deviations from spec

1. **Mark price evolution is not computed on-chain.** Spec §2 (lines 30–36) gives `P_mark(t+1) = P_mark(t) + ΔP_flow + ΔP_impulse` with `ΔP_flow = k_impact × (trade_size / vault_depth) × P_mark`. Our implementation has the markWriter push a finished mark via `pushMark`. The composition (order-flow impact, AMM curve, depth model) lives off-chain. **Why:** the project doc design principle #2 explicitly anchors this — "Mark price computation, funding rate calculation, matching live off chain and are pushed in via permissioned writers." Confirmed deliberate.

2. **"Vault TVL" in the per-subject side OI cap is `freeAssets`, not full balance.** Spec §3 says "5% of vault TVL". Our cap reads `IERC4626.totalAssets()` which `LPVault` overrides to `freeAssets()`. Numerically more conservative than total USDC balance (excludes locked collateral, insurance, accrued fees). **Why:** these three buckets are not LP-shared loss-absorbing capital, and the cap exists to bound LP-loss exposure. **Effect:** OI caps shrink as collateral gets locked (a feature: as the vault becomes more committed, new exposure tightens). **See §8 question #2.**

3. **LP rebate is hardcoded at 40%; the 6-month decay to 30% is not implemented.** Spec §3 line 139 calls for "decreasing to 30%/25% as volume grows." `PerpEngine.LP_REBATE_PCT = 40` is a constant. **Effect:** at v0 launch the contracts behave correctly per the spec's starting rate; after 6 months the contracts will be wrong unless we add the decay (governance setter and/or time-based curve) before that point. Flagged in §9.

4. **Voluntary close into negative equity reverts (`UnderwaterClose`).** Spec §3 lines 141–155 prescribe the 5-tier liquidation waterfall for underwater positions. v0 has no liquidation engine, so we reject voluntary close into negative equity rather than silently locking funds or seizing collateral. **Why:** v0 scope (the project doc says weeks 14+ for liquidation engine). **Effect:** an underwater trader cannot voluntarily exit until LiquidationEngine ships; their position remains open and is unliquidatable. **This is a real product gap that must be closed before mainnet.**

5. **Oracle "degraded" state is operator-controlled, not automatic.** Spec §4 line 242: "When a signed feed has not produced a valid update for 3× its expected refresh cadence, the OracleRouter automatically marks the metric as `degraded`." Our `setDegraded(metricId, bool, reasonHash)` is gated on `operator`. A keeper bot off-chain must monitor cadence and call. **Why:** automatic on-chain detection requires reading the per-metric refresh cadence (where would it live? per-`MetricConfig`?) and a keeper call to actually flip the flag. The keeper part can't be eliminated without a permissionless path that anyone can call when staleness is provable on-chain. Operator-gated is the v0 simplification. **See §8 question #3.**

6. **Signed-feed payload omits `subjectId`.** Spec §4 line 229 specifies the signed tuple as `(metricId, subjectId, value, timestamp, sourceProof)`. Our EIP-712 type hash is `SignedUpdate(bytes32 metricId,uint256 value,uint64 valueTimestamp,uint64 nonce)` — no `subjectId`. **Why:** the off-chain catalog computes `metricId = f(subjectId, metricKindId)` (e.g., `keccak(subjectId, metricKindId)`), so `subjectId` is implicit in `metricId` and including it in the signed payload would be redundant. Verifiers see only `metricId`. **Effect:** if the off-chain `metricId` derivation collides for two `(subjectId, kind)` pairs, signed updates would route to the wrong metric. Mitigated by using `keccak` for derivation (collision-resistant). **See §8 question #4.**

7. **Sentiment funding cap (±0.012%/h) and per-resolution impulse cap (±15%) are storage-only.** Spec §2 line 79 (impulse cap) and §5 line 343 (sentiment cap) are tracked as `FeedbackStorage.impulseCapBps` (uint16) but no contract enforces them yet. Funding cap `F_max` (0.075%/h) similarly storage-only.

8. **Stage 2 substitution timing differs.** Spec §4 line 244: "If the metric remains degraded for 14 days, governance (operations multi-sig) can vote to substitute the metric per a pre-defined fallback chain in the catalog... Substitution is on-chain registered and announced 48h before activation." Our governance can replace adapter / fallback any time after `timelockDelay` (default `[1h, 30d]`, deploy choice). The 14-day "must-be-degraded-this-long" pre-condition and the 48h announcement separation are not encoded.

9. **Mark scale: 1e18 fixed-point vs USDC's 6 decimals.** Spec doesn't specify. Internal `notional`, `collateral`, `fee`, `pnl` are 6-decimal USDC; `markPrice` and `entryPrice` are 1e18 fixed-point. `PositionMath.unrealizedPnl` divides by `1e18`, which cancels the mark scale and yields PnL in 6-decimal USDC. Documented in `PositionMath.sol`. Industry-standard mark-scale choice — flagged here for completeness.

10. **`MAX_LEVERAGE_BPS` ceiling is 6×, not 5×.** Spec §3 line 126 says "Max leverage | 5×". Default param is `50_000` (5×). The hard sanity ceiling on `setMarginParams.maxLevBps` is `60_000` (6×) because `MarginStorage.maxLeverageBps` is `uint16` (max 65535). Governance can lift the runtime cap to 6× with the current storage layout but no further. **Effect:** spec compliance at default; storage limits a hypothetical future increase. To go higher than 6× we'd need a `uint32` field (storage layout change).

11. **Storage namespace pattern.** `keccak256("people.markets.<contract>.v1")` directly — no ERC-7201 hash-mixing (`keccak256(abi.encode(uint256(keccak256("...")) - 1)) & ~bytes32(uint256(0xff))`). Project doc design principle #4 specifies this exact form. Auditable; well within Synthetix v3 conventions. Listed for transparency.

12. **OI is tracked at OPENING notional, not current mark notional.** Spec §3 line 122 says "Max OI per subject (one side) | 5% of vault TVL" — does not specify whether OI is open or current. Standard derivatives convention is opening notional (contract count × open price), which is what we do. **Effect:** caps don't drift up as mark moves up; an existing $50K position stays $50K against the cap regardless of mark.

---

## 7. Decisions you made without spec coverage

1. **Fee precision is parts-per-million (1e6), not basis points (1e4).** `TAKER_FEE_RATE = 750` (= 0.075%) and `MAKER_FEE_RATE = 250` (= 0.025%). Alternatives considered: (a) bps with rounding to whole bps (loses 0.5bps on taker fee, real revenue at scale); (b) bps with a sub-bps multiplier. Chose ppm because the spec values are clean integers in ppm and the larger denominator avoids fractional-bps rounding without adding a new unit name throughout the contract.

2. **`pmUSDC` share decimals = 12 (USDC's 6 + 6-decimal virtual offset).** ERC-4626 inflation-attack defense via OpenZeppelin's `_decimalsOffset()`. Alternatives: (a) dead shares minted to `address(0xdead)` at construction; (b) virtual-shares offset; (c) no defense + governance seed deposit only. Chose (b) because OZ ships it, it's audited, and combined with the runbook seed deposit it makes the inflation attack unprofitable. Tested in `LPVault.t.sol::test_InflationAttack_DefendedByDecimalsOffset`.

3. **`freeAssets` computed by difference (`balanceOf − bookkeepers`).** Alternatives: (a) cache `freeAssets` in storage and update on every flow; (b) compute by difference. Chose (b) because direct USDC transfers (donation attacks) increment balance without touching bookkeepers, so `freeAssets` rises by exactly the donation — donor cannot extract it atomically, existing share-holders capture it pro rata. (a) would require a special `donate` path or accept silent bucket drift.

4. **Reentrancy guard: solady's transient-storage `ReentrancyGuard` (TLOAD/TSTORE).** Cancun is enabled; gas saving over OZ's `nonReentrant` is ~3K per call. Alternative: OZ's storage-slot-based guard. Chose solady for the gas saving; both audited.

5. **One position per `(trader, subject)`, no sign-flip in a single tx.** Open reverts `PositionAlreadyOpen` if `openPositionId[trader][subjectId] != 0`. Alternatives: (a) allow flip-from-long-to-short atomically; (b) require explicit close to zero first. Chose (b) — Drift had a postmortem on flip-bug class (mis-cached `quote_entry_amount`); explicit close avoids the entire bug surface. Spec doesn't address.

6. **Position ID derivation: `keccak256(abi.encode(trader, subjectId, monotonic_nonce))`.** Alternatives: (a) `keccak(trader, subject)` only — collides on close-and-reopen, breaking event-log correlation; (b) auto-increment integer, but then traders' positions correlate across subjects (less useful for indexers). Chose nonce-keyed keccak. The nonce is monotonic and never reused even when a position is fully closed and deleted.

7. **Mark-writer add is timelocked, revoke is immediate.** Symmetric pattern to SubjectRegistry role grants. Alternatives: (a) both timelocked; (b) both immediate; (c) asymmetric (chosen). Chose (c) so a compromised governance can't instantly add a malicious writer, but a compromised writer can be cut off without delay.

8. **`setOperator` on LPVault is governance-only, NO timelock.** The operator's only power is the deposit/withdrawal pause flags — narrow blast radius, fast rotation justified for emergency response.

9. **Closes are allowed during subject pauses.** Spec §6 line 365 says "existing positions can be closed" during the 7-day delisting window. Generalized to all pause states (`AUTO_PAUSED`, `COOLDOWN`, `FROZEN`, `DEATH_PENDING`, `DELISTING`) — only `globalHalt` blocks closes outright. Spec line 176 ("During pauses: no new positions, no liquidations, no funding accrual, no event-impulse application") does not explicitly mention closes. Our reading: closes are voluntary wind-down and should not be gated. **See §8 question #1.**

10. **`OperatorTransferOperator` was renamed `setOperator` and made non-timelocked**; `transferOperator` was the original SubjectRegistry pattern. For the LPVault, governance flipping who-can-pause is a fast emergency lever. Documented inline.

11. **Mock USDC includes adversarial toggles (`transferShouldReturnFalse`, `transferShouldRevert`, `transferFeeBps`).** Test infrastructure for proving production contracts handle non-vanilla token behavior. Test-only — production assumes canonical Base USDC.

12. **Governance timelock bounds: `[1 hour, 30 days]`.** Spec §3 ("48h timelock + multi-sig") gives 48h as the baseline. Encoded as a configurable field in `[1h, 30d]` so deployment can choose. Tighter than 1h is a footgun; longer than 30d makes emergency response impractical.

13. **Initial role members in `SubjectRegistry.initialize` are granted without timelock.** Deployment is the moment of trust. After this, every grant/revoke takes the full timelock.

14. **PerpEngine uses `governance` for both timelocked actions (mark-writer adds, governance transfer) AND non-timelocked actions (margin params, KYC caps, mark-stale-after, OI cap, mark-writer revokes, globalHalt).** The same multi-sig acts at two speeds depending on the function. Alternative: separate roles for slow vs fast actions. Chose the single-role pattern because the multi-sig has operational discipline, and adding a second role complicates deployment.

15. **`UnderwaterClose` revert applies in both `LPVault.settlePosition` AND `PerpEngine.closePosition` paths.** The check is duplicated — defense-in-depth. PerpEngine refuses to call settle if equity is negative; the vault refuses even if the engine forgets.

16. **Fee residual (10%) flows to `accruedFees`** — treasury bucket inside the vault. Spec calls for 50% insurance + 40% LP rebate, totaling 90%. The 10% residual is unspecified. Sent to `accruedFees` with no automatic distribution. **See §8 question #5.**

---

## 8. Open questions for the spec author

Numbered for response.

1. **Spec §3 line 176 vs §6 line 365 on close behavior during pauses.** §3 says "no new positions, no liquidations, no funding accrual, no event-impulse application" during pauses — does not mention closes. §6 says "existing positions can be closed" during the 7-day delisting window. **Q: Are voluntary closes allowed during AUTO_PAUSED, COOLDOWN, and FROZEN as well, or are they restricted to DELISTING / DEATH_PENDING / DELISTED?** v0 currently allows closes during every status except `globalHalt`.

2. **Spec §3 "vault TVL" definition for the 5% per-subject OI cap.** Could mean (a) total USDC held by vault (`balanceOf`), (b) free LP capital (`freeAssets`), or (c) `freeAssets + positionCollateral` (working capital). Each gives a different cap as positions accumulate. **Q: which definition?** v0 uses (b).

3. **Spec §4 "automatic" degraded marking.** §4 line 242 says the OracleRouter automatically marks a metric degraded after 3× its expected refresh cadence. **Q: should we add per-`MetricConfig` cadence and a permissionless `markIfStale(metricId)` callable by anyone, OR keep operator-only with off-chain monitoring?** v0 has only the operator path.

4. **Spec §4 signed payload includes `subjectId`.** §4 line 229 lists the signed tuple as `(metricId, subjectId, value, timestamp, sourceProof)`. **Q: is `subjectId` semantically part of the signed payload, or implicit in `metricId` (off-chain catalog computes the composite)?** v0 treats it as implicit; consequence is verifiers don't see `subjectId` directly.

5. **Spec §3 fee split totals 90% (40% LP rebate + 50% insurance).** **Q: where does the remaining 10% go?** v0 routes it to a treasury bucket `accruedFees`; this isn't specified. Could be: (a) all to LPs (50% rebate); (b) all to insurance (60%); (c) treasury (current); (d) burn / governance allocation.

6. **Insurance fund $1M seed source.** Spec §3 line 159 says "$1M from treasury at launch". **Q: deploy script does a direct USDC transfer to the vault, or is there a dedicated seeding entrypoint?** v0 has no `seedInsurance` function; the deploy script would have to call `lockCollateral` from a privileged "treasury" address, which doesn't fit the role model. Need either a one-shot seed function or a clear deploy-script pattern.

7. **Death/incapacitation forced settlement at "last fair mark before news".** Spec §6 line 367. **Q: which contract is responsible for capturing the pre-news mark and for forcing existing positions to close at that mark?** v0 SubjectRegistry can flip status, but PerpEngine has no `forceSettleSubject(subjectId, mark)` function. If positions remain open after `DELISTED`, traders can't close them (`requireTradeable` would block; closes are allowed but no automatic settlement).

8. **Auto-resume of `AUTO_PAUSED` after 30s.** Spec §3 line 169 says "30s pause; auto-resume". **Q: do we model this as a stored deadline that anyone can read and unpause, or a manual `unpauseAuto` call by a guardian?** v0 has manual call; auto-resume is not on-chain.

9. **20% net category OI cap.** Spec §3 line 123. **Q: does this live in MarginEngine alongside per-trader caps, or in its own contract? And what's the category-id source — `subjects[subjectId].categoryId`?** v0 does not enforce. Currently `categoryId` is an opaque `bytes32` set on listing.

10. **Sign-flip semantics.** **Q: same-tx close-then-reopen-opposite-side allowed?** v0 forbids via the one-position invariant. Spec doesn't address. If the answer is "allowed", we'd need to relax the invariant and harden the close path (Drift's flip-bug class is the prior art).

11. **LP rebate decay (40% → 30%) over 6 months.** Spec §3 line 139 + §7 line 417 ("Phased over 6 months. Calibrate based on yield trajectory"). **Q: governance setter that ratchets the rebate down on a schedule, or a free governance setter with no schedule encoded?** v0 has no setter at all; rebate is hardcoded.

---

## 9. What's next

In order. Effort estimates assume one focused session ≈ a working day.

1. **Foundry-invariant tests for I1, I2, I3, I7, I8** (the v0-relevant invariants). Handler model with traders / LPs / markWriter / governance actors; ghost variables tracking expected `freeAssets`, `Σ position.collateral`, `Σ notionals`, etc. Real `LPVault` + `SubjectRegistry` + `PerpEngine` wired up. Project doc target is 100M+ runs eventually; this session establishes the framework with 1k×100 default and 5k×200 in CI. **Effort: 1 session.**

2. **Integration test `test/integration/PerpVault.t.sol`** — full 10-step scenario from the plan agent's design (LPs deposit, trader opens, mark moves, partial close, registry guardian pauses, trader closes during pause, etc.). Sanity-checks the cross-contract wiring beyond the unit tests. **Effort: 0.5 session.**

3. **Run the `solidity-auditor` skill** in DEEP mode against `src/`. Fix any High/Critical findings; document Mediums/Lows in a follow-up file. **Effort: 0.5–1 session depending on findings.**

4. **Resolve the §8 open questions.** Each "deviates" or "deferred" item that should land in v0 turns into an implementation task. Likely follow-ups: §8 #5 (10% residual), #6 (insurance seed), #7 (forced settlement on delist), #9 (category OI cap).

5. **Begin FundingEngine v0** (week 8–9 on the implementation order). `FundingMath` library + `FundingEngine` contract; wires the `Position.entryFundingIndex` field that's already reserved. **Effort: 2 sessions.**

Liquidation engine, feedback controller, pair-trade router, and Chainlink/UMA adapters remain in their original positions on the timeline.

---

*End of audit. Awaiting review.*
