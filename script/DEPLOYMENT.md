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
existing PerpEngine proxy. For a UUPS upgrade, use this explicit sequence:

1. At the exact proposed source commit, run the tests, CI-profile size build,
   and `script/check-storage-layout.py`. Record the proxy's current ERC-1967
   implementation address and reconcile live positions, per-subject OI, and
   vault collateral. If positions predate `positionOpeningNotional`, resolve
   their legacy OI accounting before the upgrade; layout compatibility alone
   does not establish exact historical OI.
2. Deploy `src/libraries/PerpInternals.sol:PerpInternals` on the target chain
   and verify its source. Record its address and deployed code hash. Deploy the
   new `src/core/PerpEngine.sol:PerpEngine` implementation with
   `--libraries src/libraries/PerpInternals.sol:PerpInternals:<LIBRARY_ADDRESS>`.
   Verify the implementation with the same library address, compiler settings,
   and source commit; confirm its runtime link points to that deployed library.
   Do not rely on a script's auto-linked library address for a separately
   deployed upgrade implementation.
3. Have the configured governance address call
   `upgradeToAndCall(<VERIFIED_IMPLEMENTATION>, "")` on the **proxy**, with no
   initializer. Confirm the ERC-1967 implementation slot changed to the
   verified implementation, then repeat the recorded position, OI, and vault
   collateral reads and an authorized close/open smoke. Check API and indexer
   ABI parity before enabling trading. Keep the previous implementation and
   exact linked library addresses in the rollback record.

This is an upgrade checklist, not an automated upgrade or deployment approval.
