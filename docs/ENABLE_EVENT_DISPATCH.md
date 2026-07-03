# Enable Event Dispatch (Custodial Event-Market Path) — Base Sepolia

> Contracts side of pm-engine issue #10. This turns on the **engine-relayed / custodial**
> event-market execution path on Base Sepolia for the play-money dogfood: an approving trader's
> USDC is moved into LMSR event markets by a single engine operator key, with shares credited to
> the trader.
>
> **This is testnet play-money.** A single operator key is fine — **no KMS / audit / multisig is
> required for the dogfood** (mainnet would want KMS custody + a governance multisig; see the trust
> model in `src/events/EventMarketRouter.sol`). Say so to whoever provisions the key.

---

## 1. What the path is

Two trust layers (both governance-timelocked to add, immediate to remove):

- **Layer (i): the market trusts the router.** `EventMarketRouter` is allowlisted as an operator on
  `EventMarketFactory` (`factory.isOperator(router) == true`). Every market's `*For` entrypoints
  then accept the router as caller.
- **Layer (ii): the router trusts the engine operator key.** The engine's operator **signer**
  address (`EVENT_OPERATOR`) is allowlisted on the router (`router.isOperator(EVENT_OPERATOR) ==
  true`). Only that key can call `buyOutcomeFor` / `sellOutcomeFor`.

Net authority: the engine operator key can spend the USDC a user has approved **to the router**, on
that user's behalf, into genuine factory markets. Kill switch: `removeOperator` on either the router
(cut the key) or the factory (cut the whole router) — both immediate.

---

## 2. Contract ⇄ engine address contract

The engine and contracts must agree on ONE address: the engine's operator **signer** is exactly the
address allowlisted on the router as `EVENT_OPERATOR`.

| Engine config key            | Value (from this deploy)                    |
|------------------------------|---------------------------------------------|
| `chain.event_market_router`  | `EventMarketRouter` **proxy** address        |
| `event_market_factory`       | `EventMarketFactory` **proxy** address       |
| `chain.event_operator` (signer) | the `EVENT_OPERATOR` address (must match the key allowlisted on the router) |

Users perform a **single USDC approval to the router** (`chain.event_market_router`), not to each
market.

---

## 3. Timelock reality on Sepolia

The task brief mentions a "~225s" timelock. **The router hard-floors `timelockDelay` at
`MIN_TIMELOCK_DELAY = 1 hour`** in `initialize()` (`src/events/EventMarketRouter.sol`), so the
shortest achievable delay for the *custodial* enable is **1 hour**. The factory alone would allow a
shorter (even zero) delay, but the router path gates the floor, so plan for a **1-hour wait** between
propose and activate. (The fully-isolated `DeployWorldCupTest` stack sidesteps this by using a
factory-timelock of 0 and a direct-resolve market impl — but it does **not** use the router.)

---

## 4. Sequence

### 4.1 Deploy the factory + router

`script/DeployEventMarkets.s.sol` already deploys `EventMarketFactory` (proxy), the `EventMarket`
implementation, and `EventMarketRouter` (proxy), and prints the follow-up governance steps. It does
**not** perform the allowlisting (that's `EnableEventOperator`).

```bash
export BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
export DEPLOYER_PK=0x...                 # deployer / governance key
export GOVERNANCE=0x...                   # governance (factory + router owner); can equal deployer
export TIMELOCK_DELAY=3600                # 1h — the router's MIN floor
export LP_VAULT_ADDRESS=0x...             # existing perp LPVault proxy
export USDC=0x...                         # play-money USDC (mock) token
export UMA_ADAPTER_ADDRESS=0x...
export FEEDBACK_CONTROLLER_ADDRESS=0x...

# Simulate:
forge script script/DeployEventMarkets.s.sol:DeployEventMarkets --rpc-url $BASE_SEPOLIA_RPC_URL
# Broadcast:
forge script script/DeployEventMarkets.s.sol:DeployEventMarkets \
  --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
```

Record the printed **`EventMarketFactory Proxy`** and **`EventMarketRouter Proxy`** addresses.

Also complete the LPVault wiring the deploy script prints (upgrade LPVault to the new impl and grant
`EVENT_MARKET_ROLE` to the factory) so the factory can seed markets.

### 4.2 Allowlist the operator (custodial enable) — two steps

`script/EnableEventOperator.s.sol` performs both allowlist layers. It is idempotent (safe to re-run).

```bash
export EVENT_MARKET_FACTORY=0x...   # factory proxy from 4.1
export EVENT_MARKET_ROUTER=0x...    # router proxy from 4.1
export EVENT_OPERATOR=0x...         # engine operator SIGNER address
export DEPLOYER_PK=0x...            # MUST be the factory + router `governance` key
export BASE_SEPOLIA_RPC_URL=https://sepolia.base.org

# STEP 1 — propose (layer i: router->factory, layer ii: operator->router)
forge script script/EnableEventOperator.s.sol:EnableEventOperator \
  --sig "propose()" --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast

# ...wait TIMELOCK_DELAY seconds (1 hour with the router floor)...

# STEP 2 — activate both
forge script script/EnableEventOperator.s.sol:EnableEventOperator \
  --sig "activate()" --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
```

`activate()` prints the final state and the three engine config values. Confirm:

```
factory.isOperator(router)  : true
router.isOperator(operator) : true
```

> The default entrypoint `run()` == `propose()` (STEP 1) if you omit `--sig`.

### 4.3 Create markets

`factory.createMarket(...)` (governance only) — or use `DeployWorldCupTest` for a fully isolated
stack (note: that stack is router-less; it is a separate dogfood path).

---

## 5. Verification

Local proof that the enable sequence yields a working custodial path:
`test/integration/EventDispatchE2E.t.sol` stands up the real factory + router behind proxies, runs
the exact propose → wait(1h) → activate flow, then asserts operator buy/sell credit + charge the
trader, and that non-operators / removed operators / a router removed from the factory all revert.

```bash
forge test --match-contract EventDispatchE2E -vv
```

---

## 6. Needs a human

- **Provision the `EVENT_OPERATOR` key** and hand its address to both the engine (as the operator
  signer) and this enable script. Testnet play-money: a single hot key is acceptable; no KMS.
- **Governance key** (`DEPLOYER_PK` / `GOVERNANCE`) must own both the factory and the router.
- Fund the operator key with Base Sepolia ETH for gas (it submits every relayed trade).
- On-chain broadcast is intentionally **not** performed here (no keys committed); the scripts
  compile and simulate, and the E2E test proves the on-chain effect.
