# Deploying Stockgift to Robinhood Chain mainnet

You run three commands. Nothing in this repo creates, stores or prints a private key: every
signature comes from your encrypted Foundry keystore, and Foundry asks you for its password.

**Prerequisites:** Foundry (`foundryup`), Node 20+ with pnpm, and `jq`. Fund the deployer with
**≥ 0.01 ETH on Robinhood Chain** (the estimated cost is ~0.0012 ETH at 0.02 gwei).

```bash
git clone <this repo> stockgift && cd stockgift
(cd contracts && forge install)   # if lib/ is empty
pnpm install
```

---

## (1) Import the deployer key into an encrypted keystore (one time)

```bash
cast wallet import stockgift-deployer --interactive
```

Paste the key when prompted and choose a password. The key is stored encrypted in
`~/.foundry/keystores/stockgift-deployer`. See its address with
`cast wallet address --account stockgift-deployer`.

## (2) Deploy, wire, hand admin to the Timelock, verify and write config: one command

```bash
cd contracts
forge script script/Deploy.s.sol \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account stockgift-deployer \
  --sender $(cast wallet address --account stockgift-deployer) \
  --broadcast --slow \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

This single run:
- deploys the Timelock (48h), TrustedForwarder, ComplianceRegistry (off), OracleAdapter, DexAdapter,
  ProjectTokenHooks, FeeCollector, GiftVault, GiftCardNFT, ScheduledGifts and GroupPot
- wires the oracle feeds (USDG with a depeg guard plus 12 curated stocks), Uniswap v3 routes (with USDG as the hub),
  fees (0.5%), the card NFT, compliance hooks and fee notifiers
- grants `DEFAULT_ADMIN_ROLE` to the Timelock and **renounces every deployer role**, then asserts it
- verifies every contract on Blockscout (no API key needed)
- writes `contracts/deployments/4663.json` and `app/src/config/generated/deployment.json`

Optional environment variables (set them before the command):

| Var | Default | Recommended |
|---|---|---|
| `GUARDIAN` | deployer | a monitoring multisig (can pause/unpause and edit the allowlist) |
| `TIMELOCK_PROPOSER` | deployer | a Safe multisig (proposes and executes Timelock actions) |
| `FEE_BPS` | 50 | protocol fee in bps (0.5%; contract cap 2%) |
| `PREMIUM_THRESHOLD` / `FEE_FREE_THRESHOLD` | 10_000e18 / 100_000e18 | $GIFT tiers (adjustable later via the Timelock) |

**Dry run first (recommended):** run the same command **without** `--broadcast --verify ...`. It
simulates the whole deployment against live mainnet state and sends nothing:

```bash
WRITE_DEPLOYMENT=false WRITE_FRONTEND=false forge script script/Deploy.s.sol \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account stockgift-deployer --sender $(cast wallet address --account stockgift-deployer)
```

**If Blockscout verification is rate-limited or challenged** (it sits behind Cloudflare), the
deployment still succeeds. Re-run verification only:

```bash
forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account stockgift-deployer --sender $(cast wallet address --account stockgift-deployer) \
  --resume --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

Commit `contracts/deployments/4663.json` and `app/src/config/generated/deployment.json`.

## (3) Later: connect the $GIFT token (two Timelock transactions, 48h apart)

```bash
export RPC=https://rpc.mainnet.chain.robinhood.com
export TIMELOCK=$(jq -r .Timelock contracts/deployments/4663.json)
export HOOKS=$(jq -r .ProjectTokenHooks contracts/deployments/4663.json)
export DATA=$(cast calldata "setProjectToken(address)" 0xYOUR_GIFT_TOKEN)
export Z=0x0000000000000000000000000000000000000000000000000000000000000000

cast send $TIMELOCK "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" $HOOKS 0 $DATA $Z $Z 172800 \
  --account stockgift-deployer --rpc-url $RPC
# ...48 hours later:
cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" $HOOKS 0 $DATA $Z $Z \
  --account stockgift-deployer --rpc-url $RPC
```

Use the account you set as `TIMELOCK_PROPOSER` (the deployer by default). Then set
`NEXT_PUBLIC_PROJECT_TOKEN` in Vercel. Details are in [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md).

---

## Keeper and relayer

Both services sign only with the Foundry keystore account **`stockgift-keeper`**. Use a separate,
low-balance key: it pays gas for keeper actions and gasless claims and is repaid from relayer fees.

```bash
cast wallet import stockgift-keeper --interactive
# store the keystore password in a file only you can read (the service reads it; nothing is printed)
printf '%s' 'your-keystore-password' > ~/.stockgift-keeper.pass && chmod 600 ~/.stockgift-keeper.pass
# fund the keeper address with ~0.005 ETH on Robinhood Chain
cast wallet address --account stockgift-keeper
```

Run them (any Node 20+ host, e.g. a small VM, Fly.io or Railway, behind HTTPS for the relayer):

```bash
export RPC_URL=https://rpc.mainnet.chain.robinhood.com   # better: a dedicated provider URL
export KEEPER_PASSWORD_FILE=~/.stockgift-keeper.pass
pnpm keeper                                    # loops every 60s; or `pnpm --filter @stockgift/scripts keeper --once` from cron
PORT=8787 ALLOWED_ORIGIN=https://your-app.vercel.app pnpm relayer
```

Keeper: releases due allowances, refunds expired gifts and syncs GroupPot refunds. Every action is
permissionless on-chain, so a keeper outage delays these actions but never locks funds.
Relayer knobs: `RELAYER_FEE_USD` (default 0.10), `MAX_TX_PER_HOUR` (300).

## Frontend on Vercel

1. Import the repo in Vercel and set **Root Directory = `app`**. Vercel detects Next.js and the pnpm
   workspace (from the root `pnpm-lock.yaml`) automatically. Keep the default install and build commands.
2. Environment variables:
   - `NEXT_PUBLIC_RPC_URL`: your RPC provider URL (the public RPC is rate-limited)
   - `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`: from https://cloud.reown.com (required for mobile wallets)
   - `NEXT_PUBLIC_APP_URL`: e.g. `https://stockgift.vercel.app` (used in share links)
   - `NEXT_PUBLIC_RELAYER_URL`: your relayer's HTTPS URL (empty = recipients pay their own gas)
   - `NEXT_PUBLIC_PROJECT_TOKEN`: leave **empty** until $GIFT is connected
   - `GEOBLOCK_COUNTRIES`: optional, e.g. `CU,IR,KP,SY`
   - **Do not** set `NEXT_PUBLIC_DEV_WALLET` in production.
3. Deploy. The app reads contract addresses from `app/src/config/generated/deployment.json` (committed in step 2).

## Local fork rehearsal (what was run to validate this repo)

```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --auto-impersonate --hardfork cancun --port 8545
# fund a keyless placeholder deployer on the fork, then deploy with --unlocked (no key involved)
cast rpc anvil_setBalance 0x5706100000000000000000000000000000000001 0x56BC75E2D63100000 --rpc-url http://127.0.0.1:8545
cd contracts && DEPLOYMENT_NAME=4663-fork forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 \
  --unlocked --sender 0x5706100000000000000000000000000000000001 --broadcast --slow
# app against the fork, with an impersonating dev wallet
cd ../app && NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8545 NEXT_PUBLIC_DEV_WALLET=0x<funded fork address> pnpm dev
```

`--hardfork cancun` is needed because anvil's Prague EIP-2935 system call needs historical state that
the public (non-archive) RPC doesn't serve.
