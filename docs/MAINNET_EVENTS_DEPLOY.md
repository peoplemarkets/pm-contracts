# Base Mainnet Event-Stack Deployment Runbook

Ceremony for deploying the event-market (CTF) layer on Base mainnet against the LIVE core suite,
then wiring it via governance timelocks. Related: issues #7 (Sepolia event-stack ops precedent) and
#14 (event-surplus vesting follow-up).

Script: `script/DeployBaseMainnetEvents.s.sol` (chain-id guarded: reverts unless `block.chainid == 8453`).

## 0. Context: what is already live

Deployed 2026-07-14 via `script/DeployBaseMainnet.s.sol` from commit `278fbbc`
(recorded in `broadcast/DeployBaseMainnet.s.sol/8453/run-latest.json`). The core deploy created
ZERO event contracts; this runbook adds them.

| Contract | Proxy address |
| --- | --- |
| LPVault | `0xBcbF7734DD05DeB67313e75578cF68AA322777Fb` |
| UMAAdapter | `0x5f5703C62009843ac869ddb40d133d7DEe3Edc1d` |
| FeedbackController | `0x296222DeE1Afcb12C685E85921137CBA65AF75Eb` |
| OracleRouter | `0x7343a5a45bcDC8a8d3C083cCeA900D8c032a6baf` |
| Governance (Safe) | `0x1dfF78ED621fD37E495C6b5ef39D75a3e244651A` |
| USDC (canonical Base) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

`TIMELOCK_DELAY = 3600` (1 hour) across the suite. The router enforces `MIN_TIMELOCK_DELAY = 1 hours`,
so 3600 is the floor and the configured value.

### No LPVault upgrade is needed

The live LPVault implementation (`0x7b904e341E14ae82e9Fa78a5CD2E856Bac56A3D5`) was deployed by
`DeployBaseMainnet` from commit `278fbbc`, and `src/core/LPVault.sol` at that commit already contains
the full event surface:

- `fundEventMarket` (src/core/LPVault.sol:578)
- `settleEventMarket` (:608)
- `proposeSetEventMarketFactory` / `activateSetEventMarketFactory` (:872 / :882)

Verified with `git show 278fbbc:src/core/LPVault.sol`. Only the timelocked wiring below is required.
If a future re-run of this ceremony ever DOES need a vault impl swap, model it on
`script/UpgradeEventStack.s.sol` `upgrade()` and its money-safety asserts (positionCollateral,
vault USDC balance, totalAssets and share price must not inflate).

## 1. Preconditions

1. FRESH DEPLOYER KEY. The previous mainnet deployer key is COMPROMISED and retired. Never reuse it.
   Generate a new key, fund it with a small amount of Base ETH for gas, and use it ONLY for this
   ceremony. The deployer holds no roles post-deploy: `GOVERNANCE` (the Safe) owns the factory and
   router from the moment their proxies initialize.
2. Governance Safe signers available: every wiring step is two Safe transactions (propose, then
   activate after the 1 hour timelock).
3. The engine EVENT_OPERATOR KMS signer address is known (must equal the engine's
   `chain.event_operator`).
4. `forge build` clean and full `forge test` green at the release commit.

## 2. Deploy (deployer key)

```bash
export GOVERNANCE=0x1dfF78ED621fD37E495C6b5ef39D75a3e244651A
export TIMELOCK_DELAY=3600
export LP_VAULT=0xBcbF7734DD05DeB67313e75578cF68AA322777Fb
export USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
export UMA_ADAPTER=0x5f5703C62009843ac869ddb40d133d7DEe3Edc1d
export FEEDBACK_CONTROLLER=0x296222DeE1Afcb12C685E85921137CBA65AF75Eb
export DEPLOYER_PK=<fresh key, never the retired one>

forge script script/DeployBaseMainnetEvents.s.sol:DeployBaseMainnetEvents \
  --rpc-url "$BASE_MAINNET_RPC_URL" --broadcast --verify
```

Record the three printed addresses:

```bash
export EVENT_MARKET_IMPL=<EventMarket impl>
export EVENT_MARKET_FACTORY=<EventMarketFactory proxy>
export EVENT_MARKET_ROUTER=<EventMarketRouter proxy>
```

Deploy-step verification:

```bash
cast call $EVENT_MARKET_FACTORY "governance()(address)"            --rpc-url "$BASE_MAINNET_RPC_URL"  # Safe
cast call $EVENT_MARKET_FACTORY "lpVault()(address)"               --rpc-url "$BASE_MAINNET_RPC_URL"  # LPVault proxy
cast call $EVENT_MARKET_FACTORY "umaAdapter()(address)"            --rpc-url "$BASE_MAINNET_RPC_URL"
cast call $EVENT_MARKET_FACTORY "usdc()(address)"                  --rpc-url "$BASE_MAINNET_RPC_URL"
cast call $EVENT_MARKET_FACTORY "marketImplementation()(address)"  --rpc-url "$BASE_MAINNET_RPC_URL"  # EventMarket impl
cast call $EVENT_MARKET_FACTORY "timelockDelay()(uint32)"          --rpc-url "$BASE_MAINNET_RPC_URL"  # 3600
cast call $EVENT_MARKET_ROUTER  "governance()(address)"            --rpc-url "$BASE_MAINNET_RPC_URL"  # Safe
cast call $EVENT_MARKET_ROUTER  "factory()(address)"               --rpc-url "$BASE_MAINNET_RPC_URL"  # factory proxy
cast call $EVENT_MARKET_ROUTER  "usdc()(address)"                  --rpc-url "$BASE_MAINNET_RPC_URL"
cast call $EVENT_MARKET_ROUTER  "timelockDelay()(uint32)"          --rpc-url "$BASE_MAINNET_RPC_URL"  # 3600
```

## 3. Governance timelock choreography (Safe batches)

Governance is the Safe, so every call below is a Safe transaction (Transaction Builder or
`cast calldata` pasted into the Safe UI). `script/EnableEventOperator.s.sol` encodes the same
batch (b)+(c) logic for key-based governance; on mainnet use it as the calldata reference only.
Batches (a), (b) and (c) are independent proposals — their proposes can share one Safe batch, and
their activates another, as long as 1 hour elapses between the two.

### Batch (a): wire the factory into the vault

Propose:

```bash
cast calldata "proposeSetEventMarketFactory(address)" $EVENT_MARKET_FACTORY   # to: LP_VAULT
```

Wait 1 hour (timelock), then activate:

```bash
cast calldata "activateSetEventMarketFactory()"                               # to: LP_VAULT
```

Verify:

```bash
cast call $LP_VAULT "eventMarketFactory()(address)" --rpc-url "$BASE_MAINNET_RPC_URL"  # == factory proxy
```

### Batch (b): router as factory operator

Propose:

```bash
cast calldata "proposeAddOperator(address)" $EVENT_MARKET_ROUTER              # to: EVENT_MARKET_FACTORY
```

Wait 1 hour, then activate:

```bash
cast calldata "activateAddOperator(address)" $EVENT_MARKET_ROUTER             # to: EVENT_MARKET_FACTORY
```

Verify:

```bash
cast call $EVENT_MARKET_FACTORY "isOperator(address)(bool)" $EVENT_MARKET_ROUTER --rpc-url "$BASE_MAINNET_RPC_URL"  # true
```

### Batch (c): engine KMS signer as router operator

```bash
export EVENT_OPERATOR=<engine KMS EVENT_OPERATOR signer address>
```

Propose:

```bash
cast calldata "proposeAddOperator(address)" $EVENT_OPERATOR                   # to: EVENT_MARKET_ROUTER
```

Wait 1 hour, then activate:

```bash
cast calldata "activateAddOperator(address)" $EVENT_OPERATOR                  # to: EVENT_MARKET_ROUTER
```

Verify:

```bash
cast call $EVENT_MARKET_ROUTER "isOperator(address)(bool)" $EVENT_OPERATOR --rpc-url "$BASE_MAINNET_RPC_URL"  # true
```

### Batch (d): register the UMA metric for EACH event (before createMarket)

`eventId` IS the UMA metricId. Bounds: bond >= `MIN_BOND` (1e6 = 1 USDC), liveness in
[`MIN_LIVENESS` = 60s, `MAX_LIVENESS` = 7 days]. `script/RegisterEventMetric.s.sol` is the calldata
reference. The UMAAdapter's governance may differ from the core Safe (it was initialized with
`ORACLE_GOVERNANCE`); confirm the signer first:

```bash
cast call $UMA_ADAPTER "governance()(address)" --rpc-url "$BASE_MAINNET_RPC_URL"
```

Propose (per event):

```bash
cast calldata "proposeRegisterMetric(bytes32,uint256,uint64,bytes32,address)" \
  $EVENT_ID $BOND $LIVENESS $(cast --format-bytes32-string "ASSERT_TRUTH") $USDC   # to: UMA_ADAPTER
```

Wait 1 hour, then activate:

```bash
cast calldata "activateRegisterMetric(bytes32)" $EVENT_ID                     # to: UMA_ADAPTER
```

Verify:

```bash
cast call $UMA_ADAPTER "metricOf(bytes32)((bool,uint256,uint64,bytes32,address))" $EVENT_ID \
  --rpc-url "$BASE_MAINNET_RPC_URL"   # registered == true, bond/liveness/currency as proposed
```

### Batch (e): create markets (governance)

Ordering gates, both hard:

1. The #17 readiness gate: `createMarket` reverts `MetricNotReady(eventId)` unless batch (d) has
   REGISTERED the metric for that `eventId` first.
2. Capital: creation pulls the LMSR seed from the vault via `fundEventMarket`, which reverts
   `InsufficientFreeAssets` unless `LPVault.freeAssets() >= LMSRMath.cost(0,0,b) = b*ln2`
   (per market, cumulative across a batch).

Capital sizing (`lmsrB` is 6-decimal USDC; seed = b*ln2, ln2 = 0.6931):

| lmsrB | seed pulled from vault |
| --- | --- |
| `500e6` (500 USDC) | 346.574 USDC |
| `1000e6` (1,000 USDC) | 693.147 USDC |
| `2000e6` (2,000 USDC) | 1,386.294 USDC |

Pre-check:

```bash
cast call $LP_VAULT "freeAssets()(uint256)" --rpc-url "$BASE_MAINNET_RPC_URL"  # >= sum of seeds
```

Create (per market, Safe transaction to EVENT_MARKET_FACTORY):

```bash
cast calldata "createMarket(bytes32,bytes32,uint8,string,uint64,uint256,uint256)" \
  $SUBJECT_ID $EVENT_ID $EVENT_CLASS "$QUESTION" $RESOLUTION_DEADLINE 0 $LMSR_B
```

(For OracleRouter-resolved objective markets use `createMarketWithResolution` with an explicit
`ResolutionConfig`; the metric must be registered/active on the OracleRouter instead.)

Verify:

```bash
cast call $EVENT_MARKET_FACTORY "markets(bytes32)(address)" $EVENT_ID --rpc-url "$BASE_MAINNET_RPC_URL"  # != 0x0
cast call $LP_VAULT "freeAssets()(uint256)" --rpc-url "$BASE_MAINNET_RPC_URL"   # decreased by ~b*ln2
```

### Batch (f): running verification checklist

After each batch, re-run its verify block above. Full end-state:

```bash
cast call $LP_VAULT             "eventMarketFactory()(address)"                  --rpc-url "$BASE_MAINNET_RPC_URL"
cast call $EVENT_MARKET_FACTORY "isOperator(address)(bool)" $EVENT_MARKET_ROUTER --rpc-url "$BASE_MAINNET_RPC_URL"
cast call $EVENT_MARKET_ROUTER  "isOperator(address)(bool)" $EVENT_OPERATOR      --rpc-url "$BASE_MAINNET_RPC_URL"
```

Then hand the addresses to the engine config (see `docs/ENABLE_EVENT_DISPATCH.md`):

```
chain.event_market_router = $EVENT_MARKET_ROUTER
event_market_factory      = $EVENT_MARKET_FACTORY
chain.event_operator      = $EVENT_OPERATOR
```

## 4. Kill switch reality

There is NO pause path on the factory, the router, or the markets. The ONLY way to stop trading on
the custodial path is the immediate (non-timelocked) governance `removeOperator`:

- `EventMarketRouter.removeOperator(EVENT_OPERATOR)` cuts off the engine relay instantly.
- `EventMarketFactory.removeOperator(EVENT_MARKET_ROUTER)` disables the router's `*For` calls on
  every market.

Direct (non-relayed) user trades against a market cannot be halted. Keep the Safe able to execute
`removeOperator` at short notice; re-enabling later requires the full 1 hour propose/activate
timelock again.
