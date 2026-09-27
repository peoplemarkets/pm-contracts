# Base Sepolia deployment (Foundry)

This guide deploys the core People Markets contracts using `script/DeployBaseSepolia.s.sol`.

## Required environment variables

```text
DEPLOYER_PK=...                        # private key used to broadcast (or use PRIVATE_KEY)
PRIVATE_KEY=...                        # optional alias for Foundry CLI
BASE_SEPOLIA_RPC_URL=...               # RPC endpoint for Base Sepolia
GOVERNANCE=0x...                        # PerpEngine + LPVault governance (timelocked)
OPERATOR=0x...                          # LPVault operator (fast lever)
ORACLE_GOVERNANCE=0x...                 # OracleRouter governance (timelocked)
ORACLE_OPERATOR=0x...                   # OracleRouter operator (fast lever)
SIGNED_FEED_GOVERNANCE=0x...            # SignedFeedAdapter governance
SIGNED_FEED_OPERATOR=0x...              # SignedFeedAdapter operator (pause lever)
SIGNED_FEED_SIGNER_0=0x...
SIGNED_FEED_SIGNER_1=0x...
SIGNED_FEED_SIGNER_2=0x...
SIGNED_FEED_SIGNER_3=0x...
SIGNED_FEED_SIGNER_4=0x...
INSURANCE_GOVERNANCE=0x...              # InsuranceFund governance
UMA_OO=0x...                             # UMA OptimisticOracleV3 address
USDC=0x...                              # Base Sepolia USDC address
SUBJECT_ADMIN=0x...                     # initial SubjectRegistry subject admin
PAUSE_GUARDIAN=0x...                    # initial SubjectRegistry pause guardian
KYC_WRITER=0x...                        # initial SubjectRegistry KYC writer
TIMELOCK_DELAY=3600                     # seconds (min 1 hour)
LP_NAME="People Markets LP USDC"
LP_SYMBOL="pmUSDC"
```

## Deploy

```bash
forge script script/DeployBaseSepolia.s.sol:DeployBaseSepolia \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast \
  --verify
```

## After deploy (timelocked wiring)

The script logs the next steps (proposals) because timelocks can’t be bypassed on Base Sepolia.
You’ll need to:

- Propose + activate PerpEngine, MarginEngine, FundingEngine, LiquidationEngine, and FeedbackController wiring.
- Propose + activate routers on `PerpEngine`.
- Grant `SUBJECT_ADMIN` + `PAUSE_GUARDIAN` roles to the deployed `PauseGuardian`.
- Migrate the insurance fund on `LPVault` and call `approveInsuranceFund`.

> Tip: run the same script against a local Anvil chain to test the full flow with time-warping.

## Upgrading an existing PerpEngine proxy

`PerpEngine` calls the public `PerpInternals` library through a linked address.
The `Deploy*` scripts auto-link a fresh deployment, but they do not upgrade an
existing PerpEngine proxy. Use `script/UpgradePerpEngine.s.sol` and this
sequence. Every phase that does not deploy refuses `--broadcast`.

### Authority and timing

`PerpEngine._authorizeUpgrade` is `onlyGovernance` with no on-chain delay. The
upgrade takes effect in the block where the governance transaction executes.
`timelockDelay` (3,600 s on both Base deployments) gates only mark-writer and
router additions, engine-pointer rotations and governance transfer; upgrades,
`setGlobalHalt` and the parameter setters are immediate.

| Chain | PerpEngine proxy | Governance |
| --- | --- | --- |
| Base mainnet (8453) | `0x24b84FAA257d811213f488d48A7BB276cdCf9D9F` | Safe `0x1dfF78ED621fD37E495C6b5ef39D75a3e244651A` |
| Base Sepolia (84532) | `0xb365971aa02c2d1fc435ec7fbb1aed5bd8c3467d` | EOA `0x0183A2e2F30264ebB89995854e09Bab51Ca251bE` |

Read on chain on 2026-09-27, the mainnet Safe is version 1.4.1 with threshold 1
and a single owner, so one signature executes an upgrade immediately. Any
review or delay is therefore process, not code: propose the Safe transaction
with the exact `to` and `data` printed by `simulateUpgrade()`, have a second
person reproduce that calldata, the implementation and the library from the
reviewed commit (`simulateUpgrade()` does this byte-for-byte), and re-read
`getThreshold()` and `getOwners()` at signing time.

### Zero-position gate (mandatory)

This release has no legacy opening-notional fallback: a position opened before
`positionOpeningNotional` existed has no stored value and would release no OI
when it closes. The upgrade is only valid on an engine with no open positions.

State read on 2026-09-27 (eth_call / eth_getStorageAt only):

| Chain | Block | `nextPositionNonce` | `LPVault.positionCollateral()` | Live implementation |
| --- | --- | --- | --- | --- |
| Base mainnet | 51,856,159 | 0 | 0 | `0xb50B2e84766e2eeF511bfc8b7f64599e006d229C` |
| Base Sepolia | 47,366,698 | 0 | 0 | `0xb341f8b9b5391b84c04ecaff1a385ffe7ca2ccf4` |

`nextPositionNonce` 0 means no position has ever been opened on either engine,
so both are empty. This is a snapshot: it must be re-checked in the same
session as the governance transaction, with opens halted:

1. Governance calls `setGlobalHalt(true)` on the proxy (no timelock). While
   halted every open path reverts (source-checked for this release and for the
   mainnet implementation at `278fbbc`), so no position can appear between the
   gate and the upgrade.
2. Run the gate. It must print `ZERO-POSITION GATE PASSED`:

   ```bash
   export PERP_ENGINE=<proxy from the table>
   forge script script/UpgradePerpEngine.s.sol:UpgradePerpEngine --sig "preflight()" \
     --rpc-url "$BASE_RPC_URL"
   ```

   It requires `LPVault.positionCollateral() == 0` (every open position locks
   non-zero collateral) and either `nextPositionNonce == 0` or zero long and
   short OI on every subject in `SUBJECT_IDS`. If positions were ever opened,
   build `SUBJECT_IDS` with `script/inventory-perp-positions.py` (read-only log
   scan; it also checks every position id it finds and exits non-zero on any
   live position or OI). If the gate fails, stop.
3. Upgrade (sequence below), run `verify()`, then governance calls
   `setGlobalHalt(false)`.

### Router trust after this upgrade (mandatory)

This release adds `openPositionForMatched` / `closePositionForMatched`. Any
address with the PerpEngine router role can call them for **any trader**, at an
execution price it chooses within its own `maxMarkDivergenceBps`, spending that
trader's LPVault allowance. The divergence is measured against the execution
price, not the mark (`|mark - price| * 10_000 <= bps * price`), so 5,000 bps
admits anything from 2/3 of mark to 2x mark and 10,000 bps admits anything from
mark/2 up to `MAX_MARK` (1e36): there is no effective upper bound. Before this upgrade a router
could only trade at the mark. The role must therefore be held only by contracts
that verify trader signatures (`MatchedFillRouter`) or that never call these
entrypoints (`PairTradeRouter`, `BatchRouter`), never by a key.

On 2026-09-27 the mainnet operator key `0x4cFA24dDf33c9e17c1f5e93EE90416AB801f8599`
and mark writers `0x97E7e52Fd2acbcd252f0ee8fbDbcdDcb4d0c7B62` and
`0x048C9e7415e1a78672f81371326decb1d31A3baF` were not routers. The engine
repo's Safe batch C14 proposes making that operator key a router; do not
execute it on an engine running this release. Pass every key that could hold
the role, for example:

```bash
export ROUTER_CANDIDATES=0x4cFA24dDf33c9e17c1f5e93EE90416AB801f8599,0x97E7e52Fd2acbcd252f0ee8fbDbcdDcb4d0c7B62,0x048C9e7415e1a78672f81371326decb1d31A3baF
```

`preflight()`, `simulateUpgrade()`, `upgradeWithKey()` and `verify()` fail if
any of those addresses without code is a router or a pending router. The role
cannot be enumerated on chain, so this list must be complete.

### Sequence

1. At the exact reviewed commit run `forge fmt --check`, `forge build --sizes`,
   the full `forge test`, and the storage-layout check against the commit that
   built the live implementation:

   ```bash
   python3 script/check-storage-layout.py --base <implementation commit>
   ```

   For Base mainnet that commit is `278fbbc` (the script default): its build
   is byte-identical to the live implementation and library above, with only
   the link references and immutables differing (checked 2026-09-27). The
   Base Sepolia implementation (24,404 bytes) does not match `278fbbc`; find
   its commit the same way before a Sepolia upgrade.
2. Halt and run the gate (above). Record the current ERC-1967 implementation.
3. Deploy the library. The run prints its address:

   ```bash
   forge script script/UpgradePerpEngine.s.sol:DeployPerpInternals \
     --rpc-url "$BASE_RPC_URL" --broadcast
   export PERP_INTERNALS_LIBRARY=<printed address>
   forge verify-contract "$PERP_INTERNALS_LIBRARY" \
     src/libraries/PerpInternals.sol:PerpInternals --chain base --watch
   ```

   `DeployPerpInternals` is a separate contract so forge does not auto-deploy
   a second library. It compares the deployed runtime with this commit's
   artifact.
4. Deploy the implementation linked to exactly that library:

   ```bash
   forge script script/UpgradePerpEngine.s.sol:UpgradePerpEngine --sig "deployImplementation()" \
     --libraries src/libraries/PerpInternals.sol:PerpInternals:$PERP_INTERNALS_LIBRARY \
     --rpc-url "$BASE_RPC_URL" --broadcast --verify
   export NEW_PERP_ENGINE_IMPL=<printed address>
   ```

   Before anything is sent, forge's local simulation compares the new runtime
   byte-for-byte with this commit's artifact: every link reference must hold
   `PERP_INTERNALS_LIBRARY` and every immutable the implementation's own
   address. Without the matching `--libraries` flag it reverts.
5. Simulate the governance transaction on a fork and print its payload:

   ```bash
   forge script script/UpgradePerpEngine.s.sol:UpgradePerpEngine --sig "simulateUpgrade()" \
     --rpc-url "$BASE_RPC_URL"
   ```

   It repeats the bytecode checks and the gate, executes
   `upgradeToAndCall(impl, "")` as governance on the fork, and requires
   unchanged wiring, parameters, `nextPositionNonce`, marks and OI of the
   listed subjects, `positionCollateral`, vault USDC and `totalAssets`, plus
   the new matched-fill entrypoints (`OnlyRouter` for a non-router).
   `simulateCeremony()` runs the whole sequence on a fork with a simulated
   library; it passed on both chains on 2026-09-27.
6. Governance executes `upgradeToAndCall(<NEW_PERP_ENGINE_IMPL>, "")` on the
   **proxy** (mainnet: the Safe transaction; Sepolia EOA governance:
   `--sig "upgradeWithKey()" --broadcast`, which refuses a contract
   governance). No initializer.
7. Run `verify()` against the live chain, then unhalt. Check API and indexer
   ABI parity before registering any router.
8. Only after step 7: deploy the MatchedFillRouter with
   `script/DeployMatchedFillRouter.s.sol` (its simulation refuses an engine
   without the matched-fill surface) and register it through the timelocked
   `proposeAddRouter` / `activateAddRouter` pair.

### Other contracts changed in this release

This runbook upgrades only PerpEngine (plus the library) and deploys the
MatchedFillRouter. The same release also changes MarginEngine,
LiquidationEngine, FundingEngine, PauseGuardian, UMAAdapter, EventMarket and
EventMarketRouter, and no runbook here covers them yet. Their order is fixed
by the calls they make:

- PerpEngine first. The new MarginEngine (`MarginEngine.sol:629`) and
  LiquidationEngine call `PerpEngine.fundingDebtOf`, and the new FundingEngine
  calls `pushFundingQuoteIndex`, `cumulativeFundingQuoteIndex` and
  `lastQuoteFundingAt`; none of these exist on the deployed implementation
  (`278fbbc`). Upgrading PerpEngine alone is compatible with the live peers.
- MarginEngine and LiquidationEngine before FundingEngine enables quote
  funding, or liquidation eligibility ignores funding debt.
- Write and review an ordered plan for the remaining contracts before
  upgrading any of them.

### Rollback

Keep the previous implementation and library addresses. The previous
implementation neither writes nor clears `positionOpeningNotional`, so rolling
back and later re-upgrading leaves the value stale for any position opened,
reduced or closed while the old code ran; a stale value would release the
wrong OI. Treat a re-upgrade after a rollback as a new upgrade: halt and pass
the zero-position gate again first.

This is an upgrade runbook, not an automated upgrade or deployment approval.
