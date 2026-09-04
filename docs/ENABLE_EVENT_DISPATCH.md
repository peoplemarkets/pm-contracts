# Enable Wallet-Signed Event Dispatch — Base Sepolia

> Contracts side of the event-dispatch path. The engine relays an exact EIP-712 order authorized by
> the wallet that owns the USDC or outcome shares. The operator key cannot choose the trader,
> market, outcome, intent, quantity, slippage, nonce, deadline, or executor after signing.
>
> **This runbook is testnet-only.** Isolate and fund the relayer key only for this environment.
> Production requires managed signer custody, governance review, monitoring, and security approval.

---

## 1. What the path is

Three independent authorization layers:

- **Layer (i): the market trusts the router.** `EventMarketRouter` is allowlisted as an operator on
  `EventMarketFactory` (`factory.isOperator(router) == true`). Every market's `*For` entrypoints
  then accept the router as caller.
- **Layer (ii): the router trusts the engine operator key.** The engine's operator **signer**
  address (`EVENT_OPERATOR`) is allowlisted on the router (`router.isOperator(EVENT_OPERATOR) ==
  true`). Only that key can relay, and the signed `executor` must equal it.
- **Layer (iii): the wallet authorizes the order.** `executeOrder` validates an EIP-712 EOA or
  ERC-1271 signature over every execution-sensitive field and consumes a one-use trader nonce.

Net authority: the engine key can relay only a still-valid order that the wallet signed for that
exact key. An allowance by itself is not authorization. The legacy router `buyOutcomeFor` and
`sellOutcomeFor` selectors always revert `SignedOrderRequired`. Kill switch: `removeOperator` on
either the router (cut the key) or factory (cut the whole router) — both immediate.

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
market, and then sign each order. The same operator address must be exposed to clients as the
EIP-712 `executor`.

---

## 3. Timelock reality on Sepolia

The task brief mentions a "~225s" timelock. **The router hard-floors `timelockDelay` at
`MIN_TIMELOCK_DELAY = 1 hour`** in `initialize()` (`src/events/EventMarketRouter.sol`), so the
shortest achievable delay for the signed relay is **1 hour**. The factory alone would allow a
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

### 4.2 Allowlist the signed-order relayer — two steps

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

Also confirm that the proxy exposes the signed-order implementation:

```bash
cast call $EVENT_MARKET_ROUTER "EVENT_ORDER_TYPEHASH()(bytes32)" --rpc-url "$BASE_SEPOLIA_RPC_URL"
cast call $EVENT_MARKET_ROUTER "domainSeparator()(bytes32)" --rpc-url "$BASE_SEPOLIA_RPC_URL"
```

> The default entrypoint `run()` == `propose()` (STEP 1) if you omit `--sig`.

### 4.3 Create markets

`factory.createMarket(...)` (governance only) — or use `DeployWorldCupTest` for a fully isolated
stack (note: that stack is router-less; it is a separate dogfood path).

---

## 5. Wallet authorization contract

The EIP-712 domain is:

- name: `PeopleMarketsEventOrders`
- version: `1`
- chain id: the execution chain
- verifying contract: the `EventMarketRouter` proxy

The signed `EventOrder` fields, in order, are `trader`, `executor`, `market`, `isYes`, `intent`,
`amountIn`, `minAmountOut`, `nonce`, and `deadline`. `intent` is `BUY = 1` or `SELL = 2`;
`amountIn` is USDC for a buy and outcome shares for a sell. The deadline is valid through the exact
timestamp and invalid afterward. A `(trader, nonce)` can execute once. Wallets may call
`cancelOrder` for one nonce or `invalidateNoncesBelow` to invalidate a range.

```text
EventOrder(address trader,address executor,address market,bool isYes,uint8 intent,uint256 amountIn,uint256 minAmountOut,uint256 nonce,uint64 deadline)
```

The engine submits only `executeOrder(order, signature)`. It must not call or expose the deprecated
unsigned router selectors.

---

## 6. Verification

Local proof that the enable sequence yields a working signed path:
`test/integration/EventDispatchE2E.t.sol` stands up the real factory + router behind proxies, runs
the exact propose → wait(1h) → activate flow, then executes wallet-signed buys and sells. The unit
suite also covers EOA/ERC-1271 signatures, tampering, replay, cancellation, nonce floors, deadlines,
slippage rollback, factory validation, deprecated-selector failure, and proxy storage compatibility.

```bash
forge test --match-path test/events/EventMarket.t.sol --threads 1
forge test --match-path test/events/EventMarketRouterUpgrade.t.sol --threads 1
forge test --match-path test/integration/EventDispatchE2E.t.sol --threads 1
```

---

## 7. Needs a human

- **Provision the `EVENT_OPERATOR` key** and hand its address to the engine, client signing-domain
  response, and this enable script. Keep the testnet key isolated and monitored.
- **Client + API integration** must build the canonical payload, bind the authenticated wallet and
  configured executor server-side, and carry the signature unchanged to the engine.
- **Governance key** (`DEPLOYER_PK` / `GOVERNANCE`) must own both the factory and the router.
- Fund the operator key with Base Sepolia ETH for gas (it submits every relayed trade).
- On-chain broadcast is intentionally **not** performed here (no keys committed); the scripts
  compile and simulate, and the E2E test proves the on-chain effect.
