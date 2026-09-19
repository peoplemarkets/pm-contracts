# C15 — Finalize the BTS member delistings opened by C8

**Status:** prepared, unsigned
**Safe:** `0x1dfF78ED621fD37E495C6b5ef39D75a3e244651A` (Base mainnet, chainId 8453)
**File:** `safe-batch-C15-finalize-bts-delisting.json` — 14 transactions

## Why

C8 (2026-07-20) called `requestDelisting` on the 7 BTS members. That call only
**opens** the 7-day wind-down window — nothing closes it. `forceSettle` is the
transition to `DELISTED`, and it was never sent.

So all 7 have been sitting in `DELISTING` (status 6) for 41 days.

They were invisible on the board only by accident: the indexer's start block
(48915903) postdated their listing, so they had no `subjects` row at all.
Correcting it to the deploy block (48624399) on 2026-09-06 brought them back —
and `pm-platform-api` shows every status **except** `DELISTED`
(`subjects-service.ts:311`), so they rendered. The data became correct and
exposed the state that was already wrong.

Fixing this in the UI filter instead would be the wrong call: hiding a subject
the contract still treats as live makes the site and the chain disagree, and
closes are deliberately permitted during wind-down. Make the state correct, and
the display follows.

## What it does

**Phase 1 — tx 1-7.** `SubjectRegistry.forceSettle(subjectId)` → `DELISTED`.
Permissionless, and the window elapsed **2026-07-27 12:53 UTC**
(`delistingForceSettleAt = 1785161599`, 41 days ago). Batched here purely to
guarantee it is ordered before phase 2.

**Phase 2 — tx 8-14.** `PerpEngine.forceSettleSubject(subjectId, settlementMark)`
captures the mark a position holder would settle at, enabling
`closeAtForcedSettlement`. `onlyGovernance`, and requires `DELISTED` — hence the
ordering.

| # | Subject | ID | Settlement mark |
|---|---------|-----|-----------------|
| 1 | RM | `0xf475c0d8…` | 5.62 |
| 2 | Jin | `0xd9aab5d0…` | 29.93 |
| 3 | SUGA | `0xd10f8d6b…` | 17.76 |
| 4 | j-hope | `0x4f78156d…` | 35.69 |
| 5 | Jimin | `0xe028da78…` | 42.12 |
| 6 | V | `0x1faca8bd…` | 31.30 |
| 7 | Jung Kook | `0xbd94e7b1…` | 65.45 |

## On the settlement marks

Read from `PerpEngine.markOf` at build time. They are **stale** — the oracle has
not pushed since early August — but every subject has **zero open interest**
(`longOI = 0, shortOI = 0`, verified on chain), so phase 2 settles nothing today.
It exists so no `DELISTED` subject is left without a settlement mark, which is
the same class of half-finished state that caused this. All values sit inside
`[MIN_MARK = 1, MAX_MARK = 1e36]`.

If OI were non-zero, these marks would be the wrong basis and this batch should
not be signed as-is.

## Verification performed

- All 7 read `status = 6` (`DELISTING`) via `statusOf`.
- `delistingForceSettleAt = 1785161599` (2026-07-27 12:53 UTC); now is 41 days past.
- All 7 `forceSettle` calls **simulated against live state without reverting** —
  so neither `WindowNotElapsed` (`0x2b2423ab`) nor `NotInDelisting` (`0x9b1f012b`).
- Phase 2 simulated standalone reverts with exactly
  `SubjectNotDelisted(0xf475c0d8…)` (`0x05f32bcf`) — proving it fails **only** on
  status and not on access control, since the Safe already satisfies
  `onlyGovernance`.

**Not** simulated: the full 14-transaction sequence atomically, which would need
state overrides. Phase 2's success is an inference — sound, because the only
failing precondition is the one phase 1 sets — but it is an inference, not a
simulation. Verify with the Safe's own simulation before signing.

## Identification

The seven IDs are copied verbatim from `safe-batch-C8-delist-bts-members.json`,
so no transcription risk. Two independent sources confirm the set: C2's
description ("List 7 BTS members (k-pop)") and the per-ID comments in
`pm-platform-api/loadtest/markets-load.js`, which agree on ordering.

Note these IDs are **not** `keccak256(display name)` — `keccak("RM")` is
`0x8a7f8f…`, not `0xf475c0d8…`. That convention holds for C9-era subjects
(`keccak("BTS")` = `0x3792295b…`, which matches C9) but not for the original C2
cohort. The per-name labels above therefore rest on those comments. This does not
affect correctness — the batch treats all seven identically — but do not rely on
the name↔ID mapping elsewhere without checking the metadata table.

## Irreversible

`DELISTED` is terminal, and `forceSettleSubject` reverts on a second call
(`SubjectAlreadyForceSettled`). There is no undo.

## After execution

The 7 drop off the board with no code change, because the list already filters
`DELISTED`. Open platform-api issue #62 (DELISTING vs DELISTED visibility) is
still worth closing on its own merits — the board and the index currently apply
different rules (`markets-service.ts:417` filters `ACTIVE`, while
`subjects-service.ts:311` excludes only `DELISTED`).
