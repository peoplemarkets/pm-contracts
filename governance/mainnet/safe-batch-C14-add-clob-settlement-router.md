# C14 — register the engine operator as a PerpEngine router (CLOB settlement)

`proposeAddRouter(0x4cFA24dDf33c9e17c1f5e93EE90416AB801f8599)` then, one hour later,
`activateAddRouter(...)` on the mainnet PerpEngine proxy
`0x24b84FAA257d811213f488d48A7BB276cdCf9D9F` (Base, chainId 8453), executed from the
governance Safe `0x1dfF78ED621fD37E495C6b5ef39D75a3e244651A`.

Batch files: `safe-batch-C14-add-clob-settlement-router.json` (propose, execute now) and
`safe-batch-C14b-activate-clob-settlement-router.json` (activate, execute after 1h).

The address is the mainnet perp operator/settlement signer from
`pm-infra/registry/registry.json` (`governance.base-mainnet.operator`) — an AWS KMS key that is
already a mark-writer on this same PerpEngine (batches 1/2, `writer` field) and the KYC writer on
SubjectRegistry.

## Why the timelock pair

Router registration mirrors the mark-writer pattern (`src/core/PerpEngine.sol:825-869`):

- `proposeAddRouter(address)` — `onlyGovernance`, records
  `pendingRouterActivatesAt[router] = block.timestamp + timelockDelay`. Mainnet
  `timelockDelay` is 3600s.
- `activateAddRouter(address)` — **no modifier**; anyone may call once the delay has elapsed.
  It is kept in the Safe so the activation lands in the same audit trail as the proposal.
- `cancelAddRouter(address)` — `onlyGovernance`, drops a pending proposal before activation.
- `removeRouter(address)` — `onlyGovernance`, **immediate, no timelock**.

Selectors derived from source with `cast sig`, not guessed:

```
proposeAddRouter(address)   0x41cb796e
activateAddRouter(address)  0xc3acebea
cancelAddRouter(address)    0xd7f30022
removeRouter(address)       0x6ae0b154
isRouter(address)           0xf3d7d282
pendingRouterActivatesAt(address) 0xf915ec73
```

Calldata for the two transactions in this pair:

```
C14   0x41cb796e0000000000000000000000004cfa24ddf33c9e17c1f5e93ee90416ab801f8599
C14b  0xc3acebea0000000000000000000000004cfa24ddf33c9e17c1f5e93ee90416ab801f8599
```

## What the change permits

Flagging an address in `PerpStorage.routers` unlocks exactly the four `onlyRouter` entrypoints
(`PerpEngine.sol:144-146`):

| function | line | effect |
|---|---|---|
| `openPositionFor(address trader, OpenParams)` | 172 | open a position **owned by `trader`** |
| `closePositionFor(address trader, CloseParams)` | 303 | close/partially close `trader`'s position |
| `addCollateralFor(address trader, bytes32, uint256)` | 480 | top up `trader`'s collateral |
| `removeCollateralFor(address trader, bytes32, uint256)` | 510 | withdraw `trader`'s collateral |

The router never holds funds. `openPositionFor` passes `trader` to
`ILPVault.openPositionFlow`, which does `safeTransferFrom(trader, address(this), collateral + fee)`
(`src/core/LPVault.sol:307`); payouts on close go to `trader`. So the trader still needs a USDC
allowance to the **LPVault** `0xBcbF7734DD05DeB67313e75578cF68AA322777Fb` — the same approval the
self-custody path already requires. No new approval UX, and no allowance to the router.

## Why it is needed

`openPositionFor` is `onlyRouter` and the operator is not a router, so today the CLOB settlement
path (`pm-engine crates/matching/src/submitter.rs:150`) calls the self-custody `openPosition`,
which `PerpEngine.sol:163-164` attributes to `msg.sender` — the operator signer. Every CLOB fill
would open a position owned by the operator rather than the trader, and the second fill on the
same subject would revert `PositionAlreadyOpen` because one address holds one position per
subject. The failure is swallowed at `submitter.rs:467`, so the book would show fills the chain
never settled. Blast radius today is zero only because the CLOB has never had a counterparty.

The two routers already registered on this engine do not help: `PairTradeRouter`
`0x56b2C7aBA47e16f886af84d7aeD83D436E587335` and `BatchRouter`
`0x843464d27f7bFe37981bB42aE26d9E3483aB8501` (batches 1/2) both forward `msg.sender` as the
trader, so routing the operator through them reproduces the same bug. A new trusted address is
required.

## Two things to decide before signing

**1. This registration is necessary but not sufficient.** PerpEngine has no size-increase path.
`_openPositionFor` — the shared body behind both `openPosition` and `openPositionFor` — reverts
`PositionAlreadyOpen(trader, subjectId)` unconditionally when the trader already holds a position
on that subject (`PerpEngine.sol:204-207`), and the revert is side-agnostic. Registering the
router moves the collision from "operator collides with itself on every fill after the first" to
"each trader collides with themselves on their own second fill". The settlement path still needs
a three-way branch (no position → `openPositionFor`; opposite side → `closePositionFor` with a
bps fraction computed from the live `Position.size`; same side → no contract path exists), or
PerpEngine needs an `increasePosition`. Signing C14/C14b does not by itself make PR #22 safe to
un-draft.

**2. An EOA router is strictly more powerful than the two existing ones.** Both live routers can
only ever act for their own caller, which makes the router flag nearly inert. A key registered
directly can name **any** address that has a standing LPVault allowance and open loss-making
positions for it. If the operator KMS key is compromised, the blast radius is every user who has
approved the vault. The narrower option is a purpose-built settlement router contract that
constrains what the operator can submit, with the operator kept off the router set. That is a
larger change and is not what these batches do — sign C14 only if the team has accepted the EOA
posture for now and treats `removeRouter` as the kill switch.

## What breaks if the wrong address is registered

- **Wrong-but-live address (typo into another team EOA, or the sepolia operator
  `0xbFE20c727F50003C8DBa8CF5E0C297670FE2390E`).** Worst case here. It grants a key nobody is
  watching the ability to move other users' collateral out of their vault allowance. The engine
  meanwhile still cannot settle, so the symptom (fills not settling) does not point at the
  mistake. Compare the `router` field byte-for-byte against
  `registry.json > governance > base-mainnet > operator` before signing.
- **Wrong-but-dead address (zero, or an address with no key).** `proposeAddRouter` reverts
  `InvalidConfig()` on `address(0)`, so the zero case fails closed. Any other dead address
  registers harmlessly but does not fix settlement.
- **Right address, wrong engine.** `to` must be the PerpEngine proxy
  `0x24b84FAA257d811213f488d48A7BB276cdCf9D9F`. Any other target reverts (no matching selector,
  no fallback).
- **Already-registered / double proposal.** `proposeAddRouter` reverts `RouterAlreadySet` or
  `PendingRouterExists`; `activateAddRouter` reverts `NoPendingRouter` or
  `TimelockNotElapsed(readyAt)` if C14b is executed early. All fail closed.
- **Second-order effect on the trading path.** Once settlement switches to `openPositionFor`,
  `requireTradeable` and the KYC gate are evaluated against the real trader
  (`kycTierOf(trader) == 0` → `revert KycTierMissing(trader)`, `PerpEngine.sol:196-199`), not
  against the operator. Any filler without a KYC tier begins reverting where the operator's tier
  previously carried the call. Per-trader exposure caps move onto the real trader for the same
  reason.
- **Force-settled subjects.** `closeAtForcedSettlement` has no `For` variant (it hardcodes
  `msg.sender`) and `closePositionFor` reverts `SubjectIsForceSettled`. A router-opened position
  on a force-settled subject can only be unwound by the trader transacting themselves.

## On-chain verification after execution

```sh
ENGINE=0x24b84FAA257d811213f488d48A7BB276cdCf9D9F
OP=0x4cFA24dDf33c9e17c1f5e93EE90416AB801f8599

# after C14 — pending, non-zero, ~now+3600
cast call $ENGINE "pendingRouterActivatesAt(address)(uint64)" $OP --rpc-url "$BASE_RPC_URL"
cast call $ENGINE "isRouter(address)(bool)" $OP --rpc-url "$BASE_RPC_URL"   # expect false
cast call $ENGINE "timelockDelay()(uint32)" --rpc-url "$BASE_RPC_URL"       # expect 3600

# after C14b — active, pending cleared
cast call $ENGINE "isRouter(address)(bool)" $OP --rpc-url "$BASE_RPC_URL"   # expect true
cast call $ENGINE "pendingRouterActivatesAt(address)(uint64)" $OP --rpc-url "$BASE_RPC_URL"  # expect 0

# events
cast logs --address $ENGINE "RouterProposed(address,uint64)"  --from-block <C14 block>  --rpc-url "$BASE_RPC_URL"
cast logs --address $ENGINE "RouterActivated(address)"        --from-block <C14b block> --rpc-url "$BASE_RPC_URL"

# nothing else moved: the two pre-existing routers are still set
cast call $ENGINE "isRouter(address)(bool)" 0x56b2C7aBA47e16f886af84d7aeD83D436E587335 --rpc-url "$BASE_RPC_URL"
cast call $ENGINE "isRouter(address)(bool)" 0x843464d27f7bFe37981bB42aE26d9E3483aB8501 --rpc-url "$BASE_RPC_URL"
```

Registration alone changes no behaviour until the engine is redeployed with the
`openPositionFor` call path, so there is nothing to watch on the trading side between C14b and
that release.

## How to remove the router

`removeRouter(address)` is `onlyGovernance` and takes effect on execution — no timelock, no
waiting period. One Safe transaction to `0x24b84FAA257d811213f488d48A7BB276cdCf9D9F`:

```
0x6ae0b1540000000000000000000000004cfa24ddf33c9e17c1f5e93ee90416ab801f8599
```

Confirm with `isRouter(...)` returning `false` and a `RouterRemoved` log. Removal blocks all four
`For` entrypoints for that address immediately; positions it already opened are unaffected and
remain closable by their owners through the self-custody `closePosition`.

Before activation, the equivalent undo is `cancelAddRouter(address)` — also `onlyGovernance`,
also immediate:

```
0xd7f300220000000000000000000000004cfa24ddf33c9e17c1f5e93ee90416ab801f8599
```

Because removal has no delay, the operational response to a suspected compromise of this key is
one Safe batch carrying `removeRouter(...)` and `removeMarkWriter(...)` — both `onlyGovernance`
and both immediate (`PerpEngine.sol:818-823`, `864-869`). Revoking the same key's KYC-writer role
on SubjectRegistry is slower: `proposeRoleChange(account, Role.KYC_WRITER, false)` followed by
`activateRoleChange` after the delay (`src/registry/SubjectRegistry.sol:342-374`), so plan on the
engine-side roles going first.
