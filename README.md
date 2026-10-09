# Stockgift

A gifting protocol for tokenized stocks on Robinhood Chain (chain 4663). Send stocks by **link**,
**QR code** or **wallet address**. Supports scheduled allowances, group gifts and NFT gift cards.

- **Link gifts:** the sender deposits USDG or stock tokens into `GiftVault` and gets a claim link. The link
  carries a one-time key in the URL fragment, and the vault stores only the key's address. Claims are
  EIP-712 signatures bound to the recipient, so they can't be front-run or redirected.
- **Stock choice:** gift dollars that convert into a chosen stock at claim time (via Uniswap v3,
  bounded by a Chainlink-derived floor), or let the recipient pick from a curated list. The recipient can always
  take the deposited token instead.
- **Expiry:** unclaimed gifts are refundable to the sender after a period the sender chooses (keepers do this automatically).
- **Scheduled gifts:** pre-funded weekly or monthly allowances, released by keepers (or anyone).
- **Group gifts:** many contributors fill one pot, which becomes a single claim link.
- **Gift cards:** an optional ERC-721 with on-chain SVG art that holds the claim right. Burning it claims the gift.
- **Gasless claims:** a relayer submits claims (or ERC-2771 forward requests) and is repaid from a small,
  claimant-signed fee inside the gift, capped on-chain.
- **$GIFT hooks:** zero fees and premium designs for stakers, plus fee sharing. These stay off until the
  separately launched token is connected through the Timelock. No token is deployed here.

## Repository

```
contracts/   Foundry, Solidity 0.8.28, OpenZeppelin v5.4
  src/       GiftVault, ClaimVerifier, ScheduledGifts, GroupPot, GiftCardNFT, DexAdapter, OracleAdapter,
             TrustedForwarder, FeeCollector, ProjectTokenHooks, ComplianceRegistry, Timelock
  script/    Deploy.s.sol: deploys and wires everything, hands admin to the Timelock, writes config
  test/      unit, fuzz, invariant (test/invariant) and mainnet-fork (test/fork) tests
  config/    4663.json: verified addresses used by the deploy script
app/         Next.js 16 + wagmi + RainbowKit: create, claim, allowances, group pot, $GIFT, risk pages
scripts/     keeper (allowances, refunds) + relayer (gasless claims); sign with the Foundry keystore only
config/      chains.ts: chain + token + feed + DEX addresses with source links
docs/        Slither output, fork deploy evidence
```

## Contracts

| Contract | Role |
|---|---|
| `GiftVault` | Escrow, create/claim/claimDirect/refund/cancel/rekey; ERC-2771 aware |
| `ClaimVerifier` | EIP-712 `Claim` hashing and verification (EOA + ERC-1271) |
| `ScheduledGifts` | Pre-funded recurring installments, one release per call |
| `GroupPot` | Contributions → one vault gift; pro-rata pull refunds |
| `GiftCardNFT` | ERC-721 card with on-chain SVG; `redeem` burns the card and claims |
| `DexAdapter` | Uniswap v3 SwapRouter02 routes, USDG hub routing, deadline enforced |
| `OracleAdapter` | Chainlink feeds with staleness, round, bounds and optional sequencer checks (swappable) |
| `TrustedForwarder` | OZ ERC2771Forwarder for gasless calls |
| `FeeCollector` | Fee sink, $GIFT staking and fee sharing, Timelock treasury |
| `ProjectTokenHooks` | Set-once $GIFT address and tier gates |
| `ComplianceRegistry` | Optional allowlist hook (off by default) |
| `Timelock` | OZ TimelockController, minimum delay 48h, admin of everything |

## Quality gates (all green)

```bash
cd contracts
forge test                                             # unit + fuzz + invariant (fork tests skip without RPC)
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/fork/*"
forge coverage --no-match-coverage "(test|script)" --report summary
slither .                                              # 0 high / 0 medium
```

- **Tests:** 95 unit/fuzz/invariant tests plus 7 mainnet-fork tests (real USDG, stock tokens, Chainlink, Uniswap).
- **Coverage:** 100% of lines across `src/` (99% of statements, 95% of branches).
- **Invariants:** vault balance == sum of open gifts. Each gift is claimed or refunded exactly once. Schedules hold exactly their unreleased installments.
- **Slither:** 0 high, 0 medium (one justified false-positive suppression). See [THREAT_MODEL.md](THREAT_MODEL.md).

## Run locally against a mainnet fork

```bash
pnpm install
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --auto-impersonate --hardfork cancun
# deploy to the fork (no keys: anvil impersonation), see DEPLOY.md "Local fork rehearsal"
cd app && NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8545 NEXT_PUBLIC_DEV_WALLET=0x... pnpm dev
```

## Docs
- [DEPLOY.md](DEPLOY.md): the exact commands to deploy, verify, run the keeper/relayer and ship the app
- [DECISIONS.md](DECISIONS.md): every design and tooling decision with its reasoning
- [THREAT_MODEL.md](THREAT_MODEL.md): risks (front-running, replay, leaked links, relayer abuse, …) and mitigations
- [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md): how $GIFT plugs in later

## Compliance
Stockgift is independent and is not affiliated with any stock-token issuer, broker or network operator.
Its branding doesn't use their names or logos. The app includes a risk disclosure (`/risk`), an optional
geoblock (`GEOBLOCK_COUNTRIES`), and a pluggable on-chain allowlist (`ComplianceRegistry`, off by default).
Nothing here is investment advice. The contracts haven't had a third-party audit yet.
