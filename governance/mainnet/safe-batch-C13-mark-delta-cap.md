# C13 — tighten PerpEngine mark max-delta cap to 5%

`setMarkMaxDeltaBps(500)` on the mainnet PerpEngine proxy
`0x24b84FAA257d811213f488d48A7BB276cdCf9D9F` (Base, chainId 8453), executed from the
governance Safe `0x1dfF78ED621fD37E495C6b5ef39D75a3e244651A`.

Batch file: `safe-batch-C13-mark-delta-cap.json`.

## What the change does

`PerpEngine.pushMark` bounds each mark-writer update against the previous mark
(`src/core/PerpEngine.sol:702`):

```
|newMark - oldMark| * 10_000 <= markMaxDeltaBps * oldMark
```

The value is currently the deploy-time default `DEFAULT_MARK_MAX_DELTA_BPS = 1_500`
(`PerpEngine.sol:69`, set in `initialize` at `PerpEngine.sol:106`), i.e. one push may move a
subject's mark by 15%. This proposal lowers it to 500 bps (5%).

The first push for a subject (`oldMark == 0`) stays uncapped — there is no reference point.
`applyImpulse` (FeedbackController path) is deliberately not covered by this cap and is
unaffected by the change.

## Arithmetic

Definitions taken from `src/libraries/PositionMath.sol`: notional is marked to market
(`|size| * mark`), equity is `collateral + size * (mark - entry)`, and margin ratio is
`max(equity, 0) * 10_000 / notional`. `MarginEngine.isLiquidatable` is `ratio < maintenanceMarginBps`
(`MarginEngine.sol:349`).

Mainnet margin params are the defaults: initial 2000 bps, maintenance 500 bps, max leverage
50000 bps (`MarginEngine.sol:102-105`). A max-leverage position posts collateral equal to
exactly 20% of notional — 5x.

Worked case, entry mark 100, size 1, collateral 20 (notional 100, leverage exactly 5x):

| cap | side | new mark | equity | notional | ratio | liquidatable? |
|-----|------|----------|--------|----------|-------|---------------|
| 1500 | long  | 85.00  | +5.00 | 85.00  | 588 bps  | no |
| 1500 | short | 115.00 | +5.00 | 115.00 | 434 bps  | **yes** |
| 500  | long  | 95.00  | +15.00 | 95.00  | 1578 bps | no |
| 500  | short | 105.00 | +15.00 | 105.00 | 1428 bps | no |

Long, one 15% adverse push: `equity = 20 - 15 = 5`, `notional = 1 * 85 = 85`,
`ratio = 5 * 10_000 / 85 = 588 bps >= 500` — it survives, with 88 bps of headroom.

Short, one 15% adverse push: `equity = 20 - 15 = 5`, but `notional = 1 * 115 = 115`, so
`ratio = 5 * 10_000 / 115 = 434 bps < 500` — **liquidatable**.

The original framing ("exactly 15% of room") holds only if notional is measured at entry. It is
not; it is marked to market. That makes the long marginally safer than the naive figure and the
short strictly worse, and the short is the binding case: today a single maximum-legal push from a
compromised mark-writer key liquidates every max-leverage short in the subject.

Pushes to liquidation for a fresh 5x position, adverse direction, repeated max-legal pushes:

| cap | long | short |
|-----|------|-------|
| 1500 bps | 2 | **1** |
| 500 bps  | 4 | 3 |

## Bounds check

`setMarkMaxDeltaBps` reverts with `MarkMaxDeltaBpsOutOfRange` outside
`[MIN_MARK_MAX_DELTA_BPS, MAX_MARK_MAX_DELTA_BPS] = [100, 5_000]`
(`PerpEngine.sol:70-71`, `903-906`). 500 is inside that range, so no substitute value is needed.
The setter is `onlyGovernance` and applies immediately — there is no propose/activate timelock
pair as there is for mark-writer changes, so this is a single transaction.

Calldata (selector derived from the built ABI, not guessed —
`cast sig "setMarkMaxDeltaBps(uint16)"` = `0xe1e77041`):

```
0xe1e7704100000000000000000000000000000000000000000000000000000000000001f4
```

## What breaks if this is wrong

- **Too tight for real volatility.** A legitimate move larger than 5% now needs several
  successive pushes across blocks. Between them the mark lags spot, so trades price off a stale
  reference. `markStaleAfter` is 30 seconds (`PerpEngine.sol:104`); if the composer cannot walk
  the mark in fast enough at 5% per push, `_readFreshMark` starts reverting and the subject stops
  trading until it catches up. The composer's own configured cap is already 5%, so it never
  emits a push this would reject today — but any future widening of the composer cap must be
  paired with a governance change here, or pushes will revert with `MarkDeltaTooLarge`.
- **Selector or argument wrong.** Would either revert (bad selector, no fallback on the proxy)
  or set a different parameter. Both are visible immediately — see verification below.
- **This is a backstop, not a fix.** `pushMark` has no per-writer cooldown or per-block limit; a
  compromised writer can push repeatedly in consecutive blocks and still walk the mark to
  liquidation (3 pushes instead of 1 for a 5x short). The cap only buys detection time. Key
  revocation via `proposeRemoveMarkWriter` remains the actual response to a compromise.
- **Does not change existing positions.** No storage other than `markMaxDeltaBps` is touched; no
  position is re-margined by this call.

## On-chain verification after execution

```sh
# 1. reads back 500
cast call 0x24b84FAA257d811213f488d48A7BB276cdCf9D9F "markMaxDeltaBps()(uint16)" --rpc-url "$BASE_RPC_URL"

# 2. the event records the old -> new transition (expect 1500 -> 500)
cast logs --rpc-url "$BASE_RPC_URL" \
  --address 0x24b84FAA257d811213f488d48A7BB276cdCf9D9F \
  "MarkMaxDeltaBpsSet(uint16,uint16)" --from-block <execution block>

# 3. margin params unchanged (2000 / 500 / 250 / 50000)
cast call <MarginEngine proxy> "initialMarginBps()(uint16)"      --rpc-url "$BASE_RPC_URL"
cast call <MarginEngine proxy> "maintenanceMarginBps()(uint16)"  --rpc-url "$BASE_RPC_URL"
```

Then confirm the composer keeps writing: watch for `MarkPushed` on at least one active subject
within a few minutes of execution, and check the indexer for any `MarkDeltaTooLarge` revert on
the mark-writer key. A revert there means a live subject moved more than 5% between pushes and
the cap needs revisiting.
