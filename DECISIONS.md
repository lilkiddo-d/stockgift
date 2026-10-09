# Decisions

One line of reasoning per decision. Newest decisions at the bottom of each section.

## Chain and integrations
- **Target Robinhood Chain mainnet, chain ID 4663, ETH gas.** Confirmed in the official docs and with `eth_chainId` on `https://rpc.mainnet.chain.robinhood.com`.
- **USDG is the stablecoin.** It is the only stablecoin on the official token contracts page (`0x5fc5…d1168`, 6 decimals, checked on-chain). USDC isn't listed, so it isn't used.
- **Stock token addresses come from Robinhood's `/rhj/assets` API plus the docs.** The docs table is rendered client-side, so I used the official machine-readable endpoint. Every address was checked with `symbol()`/`decimals()`.
- **Chainlink is the oracle.** Robinhood's docs name Chainlink per-asset feeds as the source of truth. Addresses come from Chainlink's own feed directory (`feeds-robinhood-mainnet.json`) and are never guessed.
- **Uniswap v3 SwapRouter02 is the swap venue.** It has official deployments on 4663 and direct USDG/stock pools with real depth. RFQ venues need off-chain signed quotes, so they aren't composable at claim time.
- **The launch list has 12 curated stocks.** These are the tickers that have both a Chainlink feed and a USDG pool with ≥$50k of USDG depth when I checked (AAPL, TSLA, NVDA, MSFT, AMZN, GOOGL, META, SPY, QQQ, AMD, PLTR, SPCX). Thinner pools would make the oracle floor revert often.
- **Each route uses the deepest USDG pool's fee tier.** I measured the USDG balance in every tier for every ticker and picked the deepest.
- **No sequencer-uptime feed (documented gap).** Chainlink hasn't published one for 4663. `OracleAdapter` supports one as an optional setting the Timelock can switch on later.
- **Equity feeds tolerate 4 days of staleness; USDG tolerates 25 hours.** Equity feeds run 24/5 with a 24h heartbeat, so a weekend plus a holiday needs more than 72h. Conversions are still bounded by slippage, and the cash fallback always works.
- **USDG has a depeg guard of [0.97, 1.03].** Converting at a depegged stablecoin price would misprice every claim.
- **Contracts compile for `evm_version = cancun`.** That's safe on Nitro. It also lets the local anvil fork run, because anvil's Prague EIP-2935 system call needs archive state the public RPC doesn't serve.
- **`deployedAtBlock` comes from `eth_blockNumber`, not `block.number`.** On Arbitrum Orbit chains, `block.number` is the L1 estimate (about 26M) while logs are indexed by L2 height (about 83M).
- **Contracts are verified on Blockscout with no API key**, using the official command from Robinhood's deploy docs.

## Protocol design
- **The link secret is an ephemeral secp256k1 key, and the vault stores its address.** The address is the keccak hash of the public key. The link signs an EIP-712 `Claim` with no extra secret-handling code, and the same path works for EOA and ERC-1271 wallet gifts.
- **The secret lives in the URL fragment (`#k=`).** Browsers never send the fragment to servers, and the claim page strips it from the address bar after reading it.
- **The `Claim` struct binds recipient, tokenOut, minOut, relayer, relayerFee and deadline.** A front-runner can't redirect funds or change any economic field. The gift ID plus the domain separator (chainId and vault address) stop cross-gift and cross-chain replay.
- **One claim function handles link, wallet and card modes.** `claimKey` is just an address: an ephemeral key, the recipient's wallet, or the GiftCardNFT contract. That gives one code path to audit.
- **The recipient can always take the deposited token (cash fallback).** Otherwise gifts could be stuck when markets are closed, an oracle is stale or a pool is thin. The sender's chosen stock is still the default in the UI.
- **The conversion floor is max(recipient minOut, oracle quote × (1 − sender slippage)).** The oracle bounds the DEX execution price: that's the deviation check, and it defeats sandwiches even if a malicious frontend signs `minOut = 0`.
- **The vault checks the recipient's balance delta after a swap and doesn't trust the adapter's return value.** That keeps the DexAdapter swappable without being trusted.
- **The protocol fee is 0.5% (hard cap 2%), taken at funding time.** It's simple to reason about and refunds return the net amount. Scheduled gifts charge the fee on top, so every installment is exactly the advertised amount.
- **The relayer fee is paid in the gift token and capped on-chain (3% default, 10% hard cap).** The relayer can't overcharge, even if it's compromised.
- **Expiry runs from 1 hour to 10 years and is chosen by the sender.** Refunds are permissionless after expiry, so keepers or anyone can return funds.
- **Senders can `cancel` and `rekey` link and wallet gifts.** This is the mitigation for leaked links. Card gifts can't be cancelled, because the card holder owns the claim right.
- **Cards are minted with `_mint`, not `_safeMint`.** That avoids a receiver callback while the vault is mid-transaction. A card sent to a contract that can't move it is the sender's choice.
- **Card artwork is fully on-chain SVG.** Messages are XML-escaped and wrapped without splitting UTF-8 code points, with a 280-byte cap so every loop is bounded.
- **GroupPot finalizes into a normal GiftVault gift.** It reuses the audited claim, refund and cancel paths. Refunds come back to the pot, and contributors pull their pro-rata share (no loops).
- **ScheduledGifts releases one installment per call and anyone can call it.** No unbounded loops, and liveness doesn't depend on our keeper. The recipient can also take an installment as USDG.
- **Weekly is 7 days and monthly is 30 days.** Calendar months need off-chain date logic, and a fixed interval is predictable and testable.
- **Stock-to-stock conversions route through USDG.** `DexAdapter.setHub(USDG)` builds paths from the configured USDG routes, so it needs no N² route table.
- **Every admin role sits behind the Timelock with a 48h minimum delay enforced in its constructor.** It's self-administered (no extra admin), and the deployer renounces all roles inside the deploy script.
- **A guardian can pause and unpause instantly.** Incident response can't wait 48h. The guardian has no power over funds.
- **ComplianceRegistry is a separate hook and is off by default.** Turning it on needs the Timelock (48h notice). Allowlist edits sit with an operator role (the guardian by default) so day-to-day onboarding is practical.
- **Fee-on-transfer tokens are rejected with a balance-delta check.** The rule "vault balance = sum of open gifts" has to hold exactly.

## $GIFT project token
- **No ERC-20 is written or deployed.** `ProjectTokenHooks.setProjectToken` is callable once, by admin (the Timelock). A mock token exists only in tests.
- **Tier balance is staked $GIFT held for at least 24h.** That stops flash-loaned or just-bought balances from dodging fees or unlocking premium designs. Counting wallet balances is an optional switch the Timelock can turn on.
- **Stakers get 50% of fees in reward tokens (USDG at launch), and the rest goes to a treasury the Timelock withdraws.** It's a MasterChef-style accumulator, with reward tokens capped at 10 so loops stay bounded.
- **One `setProjectToken` call enables everything.** FeeCollector reads the token from the hooks contract, so there's no second setter that could disagree.
- **The default tiers are 10,000 staked for premium designs and 100,000 for zero fees (18-decimal units).** They're set at deploy (env-overridable) and can be changed through the Timelock once real supply is known.

## Tooling
- **OpenZeppelin is pinned to v5.4.0 and solc to 0.8.28.** It's the latest stable OZ v5 with ERC2771Forwarder and SignatureChecker. The spec asks for `^0.8.24`.
- **pnpm workspace with `/contracts` (Foundry), `/app` (Next.js 16, wagmi 2, RainbowKit 2), `/scripts` (keeper and relayer in TS, run with tsx) and `/config` (shared chain config).**
- **wagmi stays on 2.x and TypeScript on 5.9.** RainbowKit 2 requires wagmi ^2.9, and Next 16's type checks target TS 5.
- **The `@x402/*` packages are installed as app dependencies.** The Base Account SDK (pulled in by RainbowKit) imports them, and Turbopack fails without them.
- **pnpm's supply-chain policy (minimum release age) is kept on.** The lockfile was re-resolved instead of relaxing the policy.
- **The keeper and relayer sign only through the Foundry keystore `stockgift-keeper`, decrypted in memory from a password file.** On a local fork, `KEEPER_UNLOCKED_ADDRESS` uses anvil impersonation, so no key exists at all.
- **The local fork deploy uses `--unlocked` with a keyless placeholder sender on `anvil --auto-impersonate`.** That proves the script end to end without creating or handling any private key.
- **The app's "Dev wallet (fork)" uses wagmi's `mock` connector and only appears when `NEXT_PUBLIC_DEV_WALLET` is set.** It allows end-to-end UI testing against a fork without keys.
- **Long-lived local forks need an archive RPC.** The public RPC prunes old state, so a fork more than a few hours old starts failing reads (`historical state ... is not available`). Use a provider archive endpoint for long UI sessions on a fork.
- **I ran the anvil fork on port 8645 while developing.** Ports 8545 to 8549 were already taken by other local processes. The docs use 8545.
- **Slither's `reentrancy-balance` warning on `_deliver` is suppressed in a narrow scope with a justification comment.** The before/after balance delta is the defence, and every entrypoint is `nonReentrant`. All other medium findings were fixed in code.
