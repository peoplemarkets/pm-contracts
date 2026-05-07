# pm-contracts

Solidity contracts for **People Markets** — a derivatives exchange on Base where users hold continuous perpetual positions on public figures, with event-contract feedback and a global LP-vault counterparty. USDC settlement.

The full mechanism is specified in [`mechanismdesign.md`](./mechanismdesign.md). This repo implements only the contracts layer; off-chain services (relayer, mark-price keeper, KYC pipeline) live elsewhere.

---

## Contract inventory

```
src/
├── core/                    [planned]
│   ├── PerpEngine.sol           Position lifecycle, single entry point
│   ├── LPVault.sol              ERC-4626 counterparty vault
│   ├── MarginEngine.sol         Margin checks, cross-margin with events
│   ├── FundingEngine.sol        Funding index, accrual, pause-aware
│   ├── LiquidationEngine.sol    5-tier waterfall + ADL
│   ├── InsuranceFund.sol        Bad-debt absorption, treasury floor
│   └── PauseGuardian.sol        Auto-pause / cooldown / freeze / halt
├── routers/                 [planned]
│   ├── PairTradeRouter.sol      Atomic long-A / short-B
│   └── BatchRouter.sol          Multi-position operations
├── feedback/                [planned]
│   └── FeedbackController.sol   Resolution impulses + late-move discount
├── oracle/
│   ├── IOracleRouter.sol        ✓ interface (MetricConfig, register, read, fallback)
│   ├── IOracleAdapter.sol       ✓ minimal adapter read surface
│   ├── OracleRouter.sol         ✓ keystone router, UUPS upgradeable
│   └── SignedFeedAdapter.sol    ✓ 3-of-5 EIP-712 signed feed
│   └── ChainlinkAdapter.sol     [planned]
│   └── UMAAdapter.sol           [planned]
├── registry/                [planned]
│   └── SubjectRegistry.sol      Eligibility, KYC tiers, opt-out
└── libraries/
    ├── StorageLib.sol           ✓ namespaced storage (Synthetix v3 pattern)
    ├── PositionMath.sol         [planned]
    ├── FundingMath.sol          [planned]
    └── LiquidationMath.sol      [planned]
```

✓ = shipped in this repo. [planned] = scheduled per the implementation order in the project doc.

---

## Implementation order

Audits drive timeline. Contracts ship in dependency order:

| Weeks  | Scope                                                                          |
|:------:|--------------------------------------------------------------------------------|
| 1–2    | OracleRouter + SignedFeedAdapter (mock data, lock the interface) — **shipped** |
| 3      | SubjectRegistry, Person Index registration                                     |
| 4–7    | PerpEngine v0 + LPVault — single market, mock oracle, no funding               |
| 8–9    | FundingEngine — connect to Person Index via OracleRouter                       |
| 10–13  | EventMarketFactory, EventMarket, FeedbackController                            |
| 14–15  | PairTradeRouter, position limits, circuit breakers                             |
| 16     | Integration testing, fuzzing, hand to external auditors                        |

---

## Build

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) (`foundryup`).

```bash
git clone <repo> && cd pm-contracts
forge install
forge build
forge test
```

### Useful targets

```bash
forge fmt --check               # CI gate
forge test -vvv                 # verbose tests
forge coverage --report summary # coverage by file
forge test --match-contract OracleRouterTest
forge test --match-contract SignedFeedAdapterTest
```

### Profiles

| Profile   | When to use                            |
|-----------|----------------------------------------|
| `default` | Local dev — production compiler config |
| `ci`      | CI — heavier fuzz and invariant runs   |
| `lite`    | Fast iteration — optimizer + via-IR off |

```bash
FOUNDRY_PROFILE=ci   forge test
FOUNDRY_PROFILE=lite forge test
```

---

## Compiler / toolchain

- `solc 0.8.24`
- `optimizer = true`, `optimizer_runs = 200`, `via_ir = true`
- `evm_version = cancun`
- `bytecode_hash = none`, `cbor_metadata = false` (deterministic builds)
- Fuzz: 10k runs default, 50k in CI
- Invariant: 1k runs × 100 depth default; 5k × 200 in CI

### Dependencies

- `OpenZeppelin/openzeppelin-contracts-upgradeable` — UUPS, Initializable
- `OpenZeppelin/openzeppelin-contracts` — proxy primitives
- `Vectorized/solady` — gas-optimized EIP-712, ECDSA
- `foundry-rs/forge-std` — testing harness

---

## Design principles

1. **Boring where possible, sharp where it matters.** Borrow mature patterns (GMX v2, Drift, Synthetix v3, Hyperliquid, Polymarket UMA-CTF). Innovate only where the spec demands: synthetic mark, FeedbackController, cross-margining with events. Clean-room implementation — no forks.
2. **On-chain handles money; off-chain handles everything else.** Position state, collateral, funding accrual, liquidations, settlement live on chain. Mark price computation and order matching live off chain and are pushed in via permissioned writers.
3. **Safety boundaries are explicit and audited.** Per-subject OI caps, per-trader exposure caps, leverage caps, and circuit breakers are first-class state, not parameters tucked in admin functions.
4. **Namespaced storage.** Each storage namespace lives at a `keccak256("people.markets.<contract>.v1")` slot (Synthetix v3 / Diamond pattern). Allows UUPS upgrades without storage collisions.
5. **Upgrade strategy.** Core contracts behind UUPS proxies with 48h timelock + multi-sig. Routers immutable (deploy new, migrate front-end if buggy). Libraries immutable.

---

## Oracle architecture

`OracleRouter` is the single point of truth for any external value a People Markets contract reads (mark, index components, event resolutions, sentiment).

**Per-metric routing.** Each `metricId` (typically `keccak256(subjectId, metricKindId)`) maps to a `MetricConfig`:

```solidity
struct MetricConfig {
    SourceType sourceType;       // CHAINLINK | UMA | SIGNED
    address adapter;             // primary read surface
    address fallbackAdapter;     // used when degraded
    uint32  staleAfter;          // seconds; reads revert past this
    uint32  maxDeltaBps;         // per-refresh cap, enforced by adapters
    bool    degraded;            // operator-controlled fast lever
}
```

**Two roles.**
- `governance` — slow lever, all config changes timelocked (48h baseline). UUPS upgrades gated here.
- `operator` — fast lever, `setDegraded` only, no timelock. Required to be a separate multi-sig.

**Adapters** implement `IOracleAdapter.readMetric(bytes32)`. Three are planned:
- `SignedFeedAdapter` — 3-of-5 EIP-712 multi-sig for licensed APIs (Spotify, YouTube, X, etc.). **Shipped.**
- `ChainlinkAdapter` — wraps Chainlink Data Feeds + Functions. Planned.
- `UMAAdapter` — wraps UMA Optimistic Oracle V3. Planned.

The `SignedFeedAdapter` v1 trust model (3-of-5 multi-sig, distributed across cloud KMS / bare-metal HSM / independent custodian) is the canonical attack surface. Migration target is AWS Nitro Enclave attestation, ~12 months post-mainnet. See spec §4.

---

## Audit status

- **Internal review** — in progress, alongside implementation.
- **External audits** — not yet engaged. Pre-mainnet checklist (spec §8) requires:
  - Two completed cycles (e.g. Spearbit / Trail of Bits + OpenZeppelin / Halborn) with no Critical or High findings outstanding
  - One competitive audit (Cantina or Code4rena)
  - Bug bounty program live with $250K+ ceiling
- **Test posture** — currently 100% line / 100% branch on `OracleRouter` and `SignedFeedAdapter`. Pre-mainnet target: 100% line / 95% branch across all contracts, plus 100M+ invariant test runs without violation.

---

## v1 scope exclusions

The following are **out of scope** for v1 — do not implement, do not add stubs:

- Aspect Stocks (multiple sub-stocks per person)
- Politician markets in US election years (catalog-blocked)
- Partnership Tier (subjects earning fee share)
- Markets on minors (catalog-blocked)
- Multi-collateral perps — USDC only

---

## Repository layout

```
pm-contracts/
├── src/                  # production contracts
├── test/                 # foundry tests + mocks
├── lib/                  # foundry-installed deps (forge install)
├── script/               # deployment scripts (planned)
├── .github/workflows/    # CI: build, fmt, test, slither
├── foundry.toml          # compiler + profile config
├── remappings.txt        # import remappings
├── slither.config.json   # static analysis config
├── mechanismdesign.md    # canonical mechanism spec
└── README.md             # this file
```

---

## License

Source files are licensed under **BUSL-1.1**. The mechanism design and architectural choices are documented in `mechanismdesign.md`.
