# $GIFT token integration

**This project never writes or deploys an ERC-20.** $GIFT launches separately on a launchpad. The
protocol is fully functional without it. Every token feature stays switched off until the token address
is connected once, through the 48-hour Timelock.

## What the token unlocks

| Feature | Rule | Where |
|---|---|---|
| Zero gift fees | tier balance ≥ `feeFreeThreshold` (default 100,000 $GIFT) | `ConversionBase._quoteFee` → `ProjectTokenHooks.isFeeExempt` |
| Premium card designs (ids 4 to 7: Gold, Onyx, Platinum, Ruby) | tier balance ≥ `premiumThreshold` (default 10,000 $GIFT) | `GiftVault._validateCreate` → `ProjectTokenHooks.hasPremium` |
| Fee sharing | stakers receive `stakerShareBps` (default 50%) of fees paid in reward tokens (USDG at launch), pro rata | `FeeCollector.notifyFee` / `stake` / `unstake` / `claimRewards` |

**Tier balance** is the amount of $GIFT staked in the `FeeCollector` once the latest stake is at least
`minStakeAge` (default 24h) old. A flash loan or a same-block purchase can't unlock a tier.
Optionally, the Timelock can also count raw wallet balances: `setTiers(premium, feeFree, minAge, true)`.

Before the token is set:
- `isFeeExempt` / `hasPremium` return `false` and `tierBalance` returns `0`.
- `FeeCollector.stake` reverts with `TokenNotSet()`, so 100% of fees accrue to the treasury.
- The frontend hides the $GIFT nav item, the staking page and the premium designs.

## Contracts involved
- `ProjectTokenHooks`: holds `projectToken` (set-once), the tier thresholds and `minStakeAge`.
- `FeeCollector`: staking plus the fee accumulator. It reads the staking token from `ProjectTokenHooks.projectToken()`, so one call wires everything.
- `GiftVault` / `ScheduledGifts`: consult the hooks for fee exemption and premium designs.

## Connecting the token (after it launches)

`setProjectToken(address)` can only be called **once**, by the admin. The admin is the Timelock, so
it takes two transactions 48 hours apart, both sent by a Timelock proposer/executor (the
`TIMELOCK_PROPOSER` you chose at deploy, the deployer by default).

```bash
export RPC=https://rpc.mainnet.chain.robinhood.com
export TIMELOCK=$(jq -r .Timelock contracts/deployments/4663.json)
export HOOKS=$(jq -r .ProjectTokenHooks contracts/deployments/4663.json)
export GIFT=0xYourLaunchpadTokenAddress
export DATA=$(cast calldata "setProjectToken(address)" $GIFT)

# 1) schedule (starts the 48h clock)
cast send $TIMELOCK "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $HOOKS 0 $DATA 0x0000000000000000000000000000000000000000000000000000000000000000 \
  0x0000000000000000000000000000000000000000000000000000000000000000 172800 \
  --account stockgift-deployer --rpc-url $RPC

# 2) after 48h: execute
cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" \
  $HOOKS 0 $DATA 0x0000000000000000000000000000000000000000000000000000000000000000 \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  --account stockgift-deployer --rpc-url $RPC

# verify
cast call $HOOKS "projectToken()(address)" --rpc-url $RPC
```

Requirements enforced on-chain: the address must have code, can't be zero, and can only be set once.
The token must not be a fee-on-transfer token (staking rejects those).

Then turn on the frontend features: set `NEXT_PUBLIC_PROJECT_TOKEN=<token address>` in Vercel and redeploy.
An empty value hides every token feature.

## Optional follow-ups (all through the Timelock)
- Adjust tiers to the real supply: `ProjectTokenHooks.setTiers(premiumWei, feeFreeWei, minStakeAgeSeconds, countWallet)`.
- Change the staker share: `FeeCollector.setStakerShareBps(bps)` (0 to 10,000).
- Add more reward tokens (≤ 10 total, never $GIFT itself): `FeeCollector.addRewardToken(token)`.
- Withdraw the treasury share: `FeeCollector.withdrawTreasury(token, to, amount)`.

## Tests
- Unit tests in `contracts/test/TokenFeatures.t.sol` use a **mock ERC-20 that exists only in tests**. They cover: everything disabled while unset, set-once rules, fee exemption after the minimum stake age, the optional wallet-balance tier, pro-rata fee sharing with stake changes, treasury accounting and fuzzed reward conservation.
- `contracts/test/fork/Fork.t.sol::test_fork_setProjectTokenThroughTimelock` runs the full schedule → 48h → execute flow on a mainnet fork, then checks staking and fee exemption.
