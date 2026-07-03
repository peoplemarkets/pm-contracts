# World Cup private-test runbook (Base Sepolia, play money)

Stand up a **closed, testnet, play-money** event-market dogfood. This uses a **fresh, isolated
event stack** wired to mocks — it does **not** touch the live perp deployment, and needs **no
engine, router, KMS, audit, or real USDC**.

> Resolution is by a **governance-only operator override** (`TestEventMarket.resolveForTest`).
> The real UMA path is intentionally not used on testnet (bond collateral friction). The
> operator key that deploys the stack **decides every market's outcome** — treat it as fully
> trusted for the test.

## 0. Prereqs
- Foundry installed; a Base Sepolia RPC URL; a deployer/governance key funded with Sepolia ETH.
- `export SEPOLIA=<your Base Sepolia RPC>` and `export PRIVATE_KEY=<deployer/governance key>`.

## 1. Deploy the stack + create markets
```bash
# LMSR_B MUST be 6-decimal USDC (guardrail). 2000e6 default → seed ≈ 1,386 USDC/market (cap = b·ln2).
LMSR_B=2000000000 \
VAULT_SEED_MINT=1000000000000 \        # play-USDC minted into the seed vault (1,000,000)
DEPLOYER_FAUCET=100000000000 \         # play-USDC minted to the deployer (100,000)
forge script script/DeployWorldCupTest.s.sol --rpc-url "$SEPOLIA" --broadcast
```
Record the printed addresses — you need **MockUSDC**, **EventMarketFactory**, and each **market**
address + eventId. (The default market list is in `DeployWorldCupTest.s.sol`; edit the `teams`
array to set your own World-Cup questions.)

## 2. Fund testers with play USDC
Mint MockUSDC to each friend's wallet (open mint):
```bash
cast send <MockUSDC> "mint(address,uint256)" <friendAddr> 100000000000 \
  --rpc-url "$SEPOLIA" --private-key "$PRIVATE_KEY"     # 100,000 play-USDC
```
(Or testers self-mint — `TradeEventMarket` mints first by default via `MINT_FIRST=true`.)

## 3. Testers trade (direct-wallet: approve → buy → [sell] → [redeem])
Each tester runs with **their own** `PRIVATE_KEY`:
```bash
MARKET=<market> USDC=<MockUSDC> SPEND=100000000 IS_YES=true \
forge script script/TradeEventMarket.s.sol --rpc-url "$SEPOLIA" --broadcast
```
Optional flags: `DO_SELL=true`, `DO_REDEEM=true` (after resolution), `MIN_SHARES=<slippage floor>`,
`MINT_FIRST=false`. Enforce a **minimum trade** in any UI — dust buys revert with "no shares generated".

## 4. Operator resolves a market (as matches finish)
Run by the **governance key**:
```bash
MARKET=<market> OUTCOME=1 \        # 1=YES, 2=NO, 3=VOID (VOID pays a flat 0.5/share, not a refund)
forge script script/ResolveWorldCupMarket.s.sol --rpc-url "$SEPOLIA" --broadcast
# or resolve by event id: FACTORY=<factory> EVENT_ID=0x.. OUTCOME=2 forge script ... --broadcast
```
Testers then redeem: `MARKET=<market> USDC=<MockUSDC> DO_REDEEM=true forge script script/TradeEventMarket.s.sol ...`.

## 5. Make it visible — repoint the indexer
Point **pm-indexer** at THIS stack so trades/positions/prices render:
- `.env(.vps)`: `EVENT_MARKET_FACTORY_ADDRESS=<new factory>` and
  `EVENT_MARKET_FACTORY_START_BLOCK=<deploy block>`; keep `PONDER_NETWORK=base_sepolia`.
- Restart the indexer. (The other perp `*_ADDRESS` vars can stay as-is; event markets index from the factory.)
- The indexer does **not** compute LMSR prices — the UI/client derives them from `totalYes/NoShares + lmsrB`
  (or use `EventMarket.priceOf`, now fixed to return correct 1e18-scaled implied prices).

## 6. Platform-API (only if you serve reads through it)
Run read-only in staging: `NODE_ENV=staging`, `KYC_ENABLED=false`, point `INDEXER_POSTGRES_URL` at the
indexer's Postgres **on schema `pmindexer_v2`**, don't gate the test on `/ready` (it needs the engine,
which this test doesn't), and **don't surface `POST /event-markets/:id/orders`** (engine-relayed, gated off).

## Guardrails (from the readiness audit)
- **`lmsrB` in 6-decimal USDC.** An `*e18` value bricks `createMarket` (seed becomes astronomical).
- **Vault seed ≥ Σ concurrent-market seeds + buffer.** Max vault loss per market is hard-capped at
  `b·ln2` (≈1,386 USDC at `b=2000e6`); it cannot be drained by trading.
- **The operator/governance key controls all outcomes** — the only >`b·ln2` "drain" path. Fine for a
  closed test; guard the key.
- Perps are **out of scope** for this test (need the relayer pushing marks + a committee).
