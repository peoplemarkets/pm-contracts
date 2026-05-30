# People Markets — Mechanism Design

Canonical specification of the trading mechanism, LP economics, oracle stack, cross-market feedback loop, and eligibility framework for People Markets. This document defines behavior; the perp engine and architecture documents define implementation.

---

## 1. Product

People Markets is a derivatives exchange. The primary instrument is a perpetual contract on a public figure — a Person Stock — anchored to a synthetic Person Index composed of attention, sentiment, and category-native metrics from a curated catalog. Event contracts on each subject form a depth layer that feeds back into the perp through a discrete-impulse-plus-funding-rate mechanism. Pair Trades (atomic long-A / short-B on two Person Stocks) are the headline UX.

Settlement is in USDC. Deployment is on Base. The platform operates from BVI with US restriction and KYC.

---

## 2. Price formation

### Three-signal model

The Person Stock's mark price responds to three signals at different timescales:

- **Order flow** (seconds): direct trader buy/sell pressure on the perp
- **Internal events** (hours-days): event-contract resolutions apply discrete impulses to mark; live event prices feed sentiment into funding
- **External anchor** (weeks-months): the Person Index pulls mark home via funding-rate gravity

Mark price moves trade-by-trade on order flow alone in the short term. Funding rate and discrete impulses are corrective forces operating at slower timescales. Signal contribution percentages, where they appear in product copy, are framed as multi-day variance attribution: "of the subject's N% move this week, X% explained by order flow, Y% by impulse, Z% by index re-rating." This is an after-the-fact decomposition, not a price-formation formula.

### Mark price evolution

```
P_mark(t+1) = P_mark(t) + ΔP_flow(t) + ΔP_impulse(t)

ΔP_flow(t) = k_impact × (trade_size / vault_depth_for_subject) × P_mark(t)

ΔP_impulse(t) = P_mark(t) × c_event × outcome × (1 - late_move_discount)
                fires only at event resolution; zero otherwise
```

`c_event` is per-event-category, defined in the catalog. `outcome ∈ {-1, +1}` based on YES/NO and event polarity. `late_move_discount` is computed per Section 5.

Per-resolution impulse magnitude is capped at ±15% of mark price.

### Funding rate

Settled hourly. Pulls mark toward index, with sentiment adjustment from live event markets:

```
F(t) = clamp(
    k_premium × (P_mark(t) - P_index(t)) / P_index(t)
  + k_sentiment × sentiment(t)
  + k_skew × (long_OI - short_OI) / total_OI,
    -F_max, +F_max
)

sentiment(t) = Σ over qualifying live events on this subject:
                  (event_price_i - 0.5) × polarity_i × weight_i × liquidity_factor_i
              / Σ weight_i × liquidity_factor_i

liquidity_factor_i = 0 if OI_i < $25K (hard floor)
                     min(1.0, OI_i / $50K) otherwise
```

The $25K OI hard floor prevents thinly-traded event markets from contributing to sentiment.

### Funding during pauses

During all subject-level pauses (auto-pause, cooldown, freeze, delisting), funding does not accrue. The cumulative funding index is frozen at the pause timestamp and resumes from that value when the subject becomes active again.

### Parameters

| Parameter | Symbol | Starting value | Range |
|---|---|---|---|
| Price impact coefficient | `k_impact` | 0.0008 | 0.0003-0.002 |
| Premium funding weight | `k_premium` | 0.0125 | 0.005-0.025 |
| Sentiment funding weight | `k_sentiment` | 0.004 | 0.001-0.010 |
| Skew funding weight | `k_skew` | 0.003 | 0.001-0.008 |
| Funding cap | `F_max` | 0.075%/h | 0.05-0.15%/h |
| Funding interval | — | 1 hour | 15min-8h |
| Min event OI for sentiment | — | $25K | $10K-$100K |
| Per-resolution impulse cap | — | ±15% mark | — |

### Per-event-category impulse coefficients

| Class | Positive | Negative (1.5×) | Examples |
|---|---|---|---|
| Major | +0.04 to +0.08 | -0.06 to -0.12 | Election win/loss, championship, conviction |
| Standard | +0.02 to +0.04 | -0.03 to -0.06 | Album drop, lawsuit filed |
| Minor | +0.005 to +0.01 | -0.0075 to -0.015 | Milestones, minor wins |

Negative events are 1.5× the magnitude of equivalent positive events.

### Worked example

Drake's week. Index starts at 183.10, mark at 187.42. Funding +0.012%/h. Live event "Album by Friday?" YES at 32¢.

| Time | Event | Mark | Index | Funding |
|---|---|---|---|---|
| Mon 09:00 | Calm | 187.40 | 183.10 | +0.012%/h |
| Tue 14:30 | Rumor, flow buys | 191.20 | 183.20 | +0.024%/h |
| Wed 11:00 | New event "Hot 100 #1?" lists at 55¢ | 192.40 | 183.30 | +0.028%/h |
| Thu 09:00 | Spotify monthlies +5% | 192.40 | 187.65 | +0.018%/h |
| Fri 23:55 | Insider front-running | 195.80 | 187.70 | +0.025%/h |
| Fri 00:01 | Album drops, event resolves YES | 195.80 → 203.96 | 187.70 | +0.058%/h |
| Sat 06:00 | FOMO, mark overshoots | 210.40 | 187.90 | +0.075%/h capped |
| Sun 12:00 | Mean reversion | 198.20 | 192.10 | +0.024%/h |

Net: mark +5.8%, index +5.0%. Variance attribution: ~71% order flow, ~24% impulse, ~5% index re-rating.

---

## 3. LP vault and liquidations

### Architecture

A single global USDC vault is counterparty to every position across every listed subject. ERC-4626 share token `pmUSDC`. Share price reflects vault NAV.

The single-vault decision is gated on testnet correlation analysis. If realized correlation between vertical pairs on stress days exceeds the level that produces a 99th-percentile loss day exceeding the 30% LP socialization cap, the vault splits at v1.5 into two vaults: high-volatility verticals (politicians, musicians) and low-volatility (athletes, business, creators). Cross-vault pair trades route through synthetic spread positions.

### Position limits

| Limit | Starting value |
|---|---|
| Max OI per subject (one side) | 5% of vault TVL |
| Max net OI per category | 20% of vault TVL |
| Max position per trader per subject | $50K notional × KYC tier (T1=$50K, T2=$250K, T3=$1M) |
| Max combined exposure per trader | $200K × KYC tier (perp + cross-margined event positions) |
| Max leverage | 5× |
| Initial Margin | 20% of notional |
| Maintenance Margin | 5% of notional |
| Liquidation buffer | 2.5% of notional |

### Fee structure

| Fee | Starting value |
|---|---|
| Perp taker | 0.075% |
| Perp maker | 0.025% |
| Event contract | 1.0% |
| Funding rate take | 8% |
| LP rebate | 40% perp / 30% event (decreasing to 30%/25% as volume grows) |

### Liquidation waterfall

Five tiers, executed in order until the position's loss is fully absorbed.

**Tier 1 — Partial liquidation.** When margin ratio falls below maintenance margin, position size is reduced in 25% increments. Minimum 4 partial liquidations attempted before full close. Continues until margin ratio is restored to MM + 100bps buffer.

**Tier 2 — Full liquidation.** If partials fail to restore margin, close entire position at current mark. Liquidator (permissionless) receives 1% of position notional as bounty, paid from collateral.

**Tier 3 — Insurance fund.** If position collateral insufficient to cover loss + bounty, insurance fund covers the shortfall.

**Tier 4 — LP socialization.** If insurance fund depleted, LP vault absorbs the loss. Share price drops proportionally. Capped at 30% of vault TVL per single event.

**Tier 5 — Auto-Deleveraging (ADL).** If LP loss would exceed 30% cap, profitable opposite-side positions are automatically closed at the bankruptcy price of the liquidated position, in priority order: highest unrealized P&L × leverage first.

ADL queue position is exposed in the front-end. Each trader sees their current rank (1 = first to be ADL'd if needed, N = least likely).

### Insurance fund

- Initial seed: $1M from treasury at launch
- Ongoing replenishment: 50% of trading fees until fund reaches cap
- Cap: 10% of vault TVL — excess flows to LPs as enhanced rebate via share-price boost (gas-free)
- Floor mechanic: when fund drops below 5% of TVL, treasury commits matching capital up to a pre-set ceiling, with no change to LP rebate flow. Standard fee replenishment continues at 50%
- Governance: separate multi-sig from operations, with timelock and rationale required for withdrawals

### Pause and circuit breaker thresholds

| Trigger | Effect |
|---|---|
| 5% mark move in 30s | 30s pause; auto-resume |
| 10% mark move in 30 min | 5 min pause; admin review |
| 20% mark move in 1 hour | 15 min pause; admin review required to resume |
| Subject opt-out | 7-day close window, then forced settlement |
| Death/incapacitation (oracle-confirmed) | Immediate forced settlement at last fair mark before news |
| Involuntary delisting (legal/regulatory) | Immediate forced settlement at last pre-action mark |

During pauses: no new positions, no liquidations, no funding accrual, no event-impulse application.

### LP yield expectations

At $10M TVL with 1× daily turnover and 60% long skew:

```
Annual volume:        $3.65B
Fee revenue (0.075%): $2.74M
LP rebate (40%):      $1.10M  →  11.0% APR
Funding income to vault (8% take retained): ~2.4% APR
Trading fees + funding: ~13.4% APR baseline
```

Worst credible 30-day drawdown: -8% to -12%, primarily from coordinated category moves. Single-event tail (presidential assassination, 80% in 1h on $TRMP) bounded by per-subject OI cap to ~4% of vault TVL.

LPs have unhedgeable directional exposure on a synthetic basket. There is no external spot market to hedge against. This is disclosed in LP-facing materials.

---

## 4. Oracle stack

### Three sources

**Chainlink** for standardized public data feeds — election results, sports scores, FX, public-company stock prices. Data Feeds where they exist; Chainlink Functions for one-off API calls.

**UMA Optimistic Oracle V3** for subjective and dispute-prone resolutions — event-contract resolutions, polling-basket averages, sentiment-window resolutions, narrative metrics.

**In-house signed feeds** for licensed APIs — Spotify, YouTube, X, Google Trends, Wikipedia pageviews. Multi-sig signed (3-of-5), with operationally distributed signers across cloud KMS, bare-metal HSM, and an independent custodian.

Each catalog metric specifies its oracle source. Routing is dispatched through the OracleRouter contract.

### Per-metric configuration

| Metric | Source | Cadence | Manipulation cost (1% on midtier subject) | Mitigation |
|---|---|---|---|---|
| Spotify monthlies | Signed | Daily | $25-50K stream farming | 3% per-day delta cap, multi-source cross-check |
| YouTube subs/views | Signed | Daily | $10-30K bot views | Subs > views weighting |
| X mentions | Signed | 15min | $5-10K bot networks | Cap weight at 8%, sustained-signal filter |
| X follower count | Signed | Hourly | $1-5K bot follows | Verified-only counts, growth-rate caps |
| Google Trends | Signed | Hourly | $20-40K coordinated search | Multi-region averaging |
| Wikipedia pageviews | Signed | Daily | $15K bot traffic | WMF-side anti-bot |
| Tier-1 media mentions | Signed (NLP) | Daily | High (real coverage required) | Strong signal |
| Polling baskets | UMA | Weekly | Hard at aggregate | Naturally resistant |
| Election results | Chainlink + UMA | Event-driven | Effectively impossible | Strongest source |
| Sports performance | Chainlink | Event-driven | Effectively impossible | Strongest source |
| Billboard charts | Signed | Weekly | Hard at chart level | Industry-vetted |

### Signed feed architecture

The relayer service pulls licensed data on per-metric cadence and produces signed tuples:

```
(metricId, subjectId, value, timestamp, sourceProof)
```

Each tuple is EIP-712 signed by 3-of-5 multi-sig. Signers run independent verifier services that re-pull the data before signing. Signed payloads are posted on-chain to the metric's `SignedFeedAdapter`, which verifies signatures and updates state.

Lazy evaluation: values are pushed on-chain only when a market needs to read them (triggered by a trade, funding update, or keeper bot when staleness exceeds tolerance).

Composite optimization: the Person Index is computed off-chain with a Merkle proof of components; the composite value is posted on-chain with the proof. Anyone can challenge the composition by recomputing.

### Metric-source-death cascade

Three-stage response when a metric source becomes unreliable or unavailable:

**Stage 1 — Degraded.** When a signed feed has not produced a valid update for 3× its expected refresh cadence, the OracleRouter automatically marks the metric as `degraded`. The Person Index recomputes with the metric's weight redistributed proportionally to other metrics in the composite. Markets continue trading.

**Stage 2 — Substituted.** If the metric remains degraded for 14 days, governance (operations multi-sig) can vote to substitute the metric per a pre-defined fallback chain in the catalog. Each metric declares its fallback chain in `pm-catalog`. Substitution is on-chain registered and announced 48h before activation.

**Stage 3 — Permanent removal.** If the metric source is unrecoverable, the metric is dropped from the catalog by governance vote. Affected subjects' indexes are recomputed. Position holders have a 7-day window to close before any forced parameter change takes effect.

### TEE attestation migration

The 3-of-5 multi-sig is the v1 trust model for in-house signed feeds. It is a centralization vulnerability that cannot be eliminated in v1.

**Migration target:** AWS Nitro Enclaves with remote attestation, replacing multi-sig signing. The relayer runs inside the enclave; signed payloads include the Nitro attestation document. On-chain verification accepts only payloads with valid attestation matching a registered enclave image hash.

**Timeline:** target completion 12 months post-mainnet. Infrastructure spike in months 6-9, full migration months 9-12. Budget: ~$130-150K (one senior infrastructure engineer for one quarter, AWS Nitro infrastructure, audit cycle on the verifier).

**If the 12-month target is missed:** the platform publicly owns the multi-sig as a permanent architectural choice and prices the trust assumption into LP rebates and into all trustless-claim language. The TEE migration is not an optional roadmap item.

### Manipulation surface

Specific attack vectors and residual risk:

- **Bot Wikipedia edits:** not exploitable (pageviews, not content)
- **Click-farm Spotify streams:** real risk; mitigated by per-refresh delta cap (max 3%/day) and multi-source cross-validation. Residual risk: medium
- **Coordinated X mention campaigns:** real; weight capped at 8%, sustained-signal filter (1h and 24h averages, not point-in-time)
- **UMA dispute griefing:** mitigated by strict claim-language standards (catalog-managed) and insurance fund coverage of mis-resolutions
- **Multi-sig key compromise:** distributed signers, time-locked governance, public attestation dashboard, insurance fund backstop
- **Flash-loan oracle manipulation:** TWAP on all index-component metrics (1-hour minimum)

---

## 5. Cross-market feedback loop

### Event resolution → discrete mark impulse

```
ΔP_impulse = P_mark × c_event × outcome × (1 - late_move_discount)
```

`c_event` is per-event-category from the catalog (Section 2). `outcome ∈ {-1, +1}`. `late_move_discount` is computed below.

### Late-move discount

Targets manipulation patterns (last-24h pumping) without penalizing efficient continuous price discovery.

```
late_move = max(0, |price(t_resolution) - price(t_resolution - 24h)|)
late_move_factor = late_move / 0.5
discount = min(0.5, late_move_factor × 0.6)
```

Behavior:

- Event lived at 80¢ for a week, resolves YES: late_move ≈ 0.05, discount ≈ 0.06. Negligible penalty
- Event pumped from 30¢ to 80¢ in final 24h, resolves YES: late_move = 0.50, discount = 0.50 (capped). Half impulse
- Steady drift 50¢→70¢ over a week: late_move ≈ 0.05, discount ≈ 0.06. Negligible penalty

A legitimate news leak in the final 24h before resolution is penalized the same as a manipulation pump. This is intentional: the impulse mechanism does not reward last-minute information advantage, regardless of source. Insiders capture value through the perp side; the impulse channel is reserved for confirmed news that the broader market did not anticipate.

### Live event prices → funding sentiment

Live event prices feed sentiment into funding rate per Section 2. Hard floor: events with OI < $25K contribute zero to sentiment.

### Cross-margining

A trader's combined exposure across the perp and correlated event markets is capped:

```
total_exposure(trader, subject) = perp_notional 
                                + Σ event_position_i × correlation_i × c_event_xm

correlation_i ∈ {-1, 0, +1}
c_event_xm = 0.25 (starting value, range 0.20-0.40)

constraint: total_exposure ≤ kyc_tier_limit(trader)
```

`c_event_xm` reflects total manipulation potential per dollar of event position — the resolution impulse plus cumulative sentiment effect over a typical 30-day resolution window — not the impulse coefficient alone.

**Tuning posture:** false-negatives (manipulation succeeds) are strictly worse than false-positives (legitimate trader rejected at the margin). When ambiguous, the parameter defaults higher. Empirical tuning during testnet adjusts toward 0.30+ if red-team finds the play profitable; relaxes toward 0.20 only with clear evidence of legitimate hedging being blocked at scale.

Anti-correlated event positions (correlation = -1) reduce effective exposure, allowing traders to use event markets as hedges against perp positions.

### Manipulation example

Attacker thesis: pump $DRAKE.

- Long $50K $DRAKE perp at 5× leverage = $250K notional
- Wants $80K of "Album by Q3" YES position to drive sentiment + earn impulse
- Cross-margin check: $250K perp + $80K event × 0.25 = $270K. Tier 1 cap $250K. **Position rejected**

At smaller scale:
- $20K perp at 5× = $100K notional
- $80K event × 0.25 = $20K event exposure
- Combined: $120K. Fits under cap
- Sentiment subsidy on $20K perp over 30 days: ~$230
- Late-move discount halves impulse to ~2%, yielding ~$400 on $20K position
- Total potential extraction: ~$630
- Cost of pumping event market and paying spread: $1,500-3,000 minimum
- **Unprofitable**

### Resolution magnitude vs unresolved sentiment

Resolutions matter more than unresolved prices. Resolutions are verified facts; live event prices are noisier speculation. Live event sentiment contributes max ±0.012%/h to funding (~10% of typical funding). Resolution impulses apply directly to mark, capped at ±15% per resolution.

---

## 6. Subject eligibility, delisting, legal

### Eligibility

A subject is auto-eligible if at least one of the following criteria is currently active in the past 12 months:

- Verified profile with 100K+ followers on a major platform
- Holding public office at a defined level
- N tier-1 media mentions in the past 12 months
- Wikipedia article authored by someone other than the subject
- Top-N position on a recognized industry chart

Recency filter excludes aging public figures whose qualifying criteria are dormant.

### Delisting

Three flows by trigger:

**Voluntary opt-out:** subject submits delisting request. Status transitions to `DELISTING`. New positions blocked immediately; existing positions can be closed. 7-day close window. At end of window, force-settlement at last fair mark.

**Death or incapacitation:** confirmed by Chainlink celebrity death feeds (where available) plus UMA optimistic resolution. Manual platform flag triggers 24h trading halt pending oracle confirmation. Confirmed: immediate forced settlement at last fair mark before the news. Unconfirmed at 24h: halt lifted, no positions affected.

**Involuntary (legal/regulatory):** immediate forced settlement at last pre-action mark, no warning.

### Defamation and right-of-publicity

Even with offshore base, exposure is real in California, New York, and EU jurisdictions. Mitigations:

- Strict catalog vetting; no markets that imply false statements about a subject
- Subject opt-out always available
- No use of subject likeness in marketing without permission
- GDPR-compliant data deletion on request

Legal reserve: ~$500K in years 1-2 for one or two test cases.

### Partnership Tier

Excluded from v1. v1.5 launch with constraints:

- Subject cannot trade their own market
- Material non-public information disclosed via pre-set channels with timestamp
- Fee share capped at 5% of trading fees
- Legal opinion in v1 jurisdiction (BVI) before launch

### Jurisdiction

BVI for v1. Cayman is the v2 destination once institutional capital is involved.

### v1 scope exclusions

The following are out of scope for v1:

- **Aspect Stocks** (multiple sub-stocks per person across metric verticals): adds storage and gas overhead, dilutes headline UX, creates new mechanism design problems around cross-aspect interactions. Reconsider for v1.5 only with v1 demand evidence
- **Politician markets in US election years:** elevated CFTC and election-integrity risk. Add post-launch
- **Partnership Tier:** add in v1.5 with constraints above
- **Markets on minors:** catalog-level hard block
- **Multi-collateral perps:** USDC only

---

## 7. Empirically-tuned parameters

The following parameters are starting values that require validation during the 90-day testnet phase. All are subject to refinement before mainnet parameter lock.

| Parameter | Starting value | Validation method |
|---|---|---|
| `c_event` per category | Per Section 2 table | Run 50+ resolutions, measure mark response |
| Effective signal weights (multi-day attribution) | 70/25/5 priors | Measure variance contribution by signal over 30 days |
| `F_max` (funding cap) | 0.075%/h | Set at 1.5× observed 95th percentile premium |
| Position limits per subject | 5% TVL per side | Loosen as drawdowns prove manageable |
| LP rebate transition (40%→30%) | Phased over 6 months | Calibrate based on yield trajectory |
| `k_sentiment` | 0.004 | A/B test sentiment-on vs sentiment-off |
| `c_event_xm` (cross-margin multiplier) | 0.25 | Red-team exercise with realistic attacker capital; default toward higher when ambiguous |
| `late_move_discount` formula coefficients | Per Section 5 | Run 50+ resolutions with varied pre-resolution price paths |
| Cross-category correlation threshold for v1.5 vault split | TBD by analysis | Testnet measures realized correlation; threshold set from LP-drawdown analysis |
| Insurance fund treasury top-up ceiling | TBD | Set based on treasury size and risk tolerance |

---

## 8. Pre-mainnet checklist

The following gates must pass before mainnet launch.

### Audits

- Two completed audit cycles (Spearbit/Trail of Bits + OpenZeppelin/Halborn) with no Critical or High findings outstanding
- One competitive audit (Cantina or Code4rena) completed
- Bug bounty program live with $250K+ ceiling

### Testing

- 100% line coverage, 95% branch coverage on all contracts
- 100M+ invariant test runs with no violations
- 90-day testnet phase completed with parameters locked
- Cross-margin red-team exercise completed; `c_event_xm` validated empirically

### Tail-event drills

Tail events do not arrive on schedule. The following drills run on testnet with synthetic shocks injected by the team:

- **Assassination drill:** simulated 80%-in-1h move on a single subject; verify pause cascade, ADL ordering, insurance fund mechanics
- **Mass scandal drill:** simulated 30% multi-subject correlated move within a vertical; verify category limits, vault solvency
- **Oracle catastrophic failure:** simulated total loss of all signed feeds for 48h; verify Stage 1 degraded mode and metric-source-death cascade
- **Multi-sig compromise:** simulated key compromise; verify guardian pause and rotation procedure
- **Mass liquidation:** simulated 100+ position liquidation cascade in a single block; verify partial-liquidation step ordering and ADL queue

Pass/fail criteria documented in `pm-ops/runbooks/`.

### Operational readiness

- Insurance fund seeded ≥ 5% of expected v1 TVL
- At least one institutional market-maker partnership signed
- Legal opinion on cross-market feedback loop in BVI jurisdiction
- KYC/AML pipeline operating with <5% false-rejection rate at scale
- TEE migration plan documented with target dates and budget owner assigned
- Public docs in plain English published

### Testnet phase plan

| Weeks | Experiment |
|---|---|
| 1-2 | Vault stress test with synthetic flow |
| 3-4 | Live trader onboarding (testnet capital) |
| 5-6 | Event resolution series with varied pre-resolution price paths |
| 7-8 | Cross-market manipulation red team |
| 9-10 | Oracle attack simulation |
| 11-12 | Death/delist drill + tail-event paper drills |
| 13 | Final parameter lock |

---

*End of specification.*