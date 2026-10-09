# Threat model

## Assets
- Escrowed funds: USDG and stock tokens held by `GiftVault`, `ScheduledGifts` and `GroupPot` (between contribution and finalize).
- Protocol fees and staked $GIFT held by `FeeCollector`.
- Claim rights: link secrets, wallet claim keys and GiftCardNFTs.
- Admin powers: the Timelock (admin of everything) and the guardian (pause).

## Actors and trust
| Actor | Trust | Powers |
|---|---|---|
| Sender | untrusted | creates, cancels or rekeys their own non-card gifts |
| Recipient / link holder | untrusted | claims to an address they choose |
| Relayer | untrusted, semi-honest | submits claims; paid only the fee the claimant signed |
| Keeper | untrusted | releases due installments, refunds expired gifts (both permissionless) |
| DEX pools / MEV searchers | adversarial | can move pool prices around a swap |
| Oracle (Chainlink) | trusted with checks | price feeds; bounded by staleness, sanity and depeg checks |
| DexAdapter | swappable, **not trusted** | the vault checks the recipient's actual balance delta |
| Guardian | trusted for liveness only | pause/unpause; no access to funds |
| Timelock proposers | trusted, delayed 48h | every admin setter, `setProjectToken`, treasury withdrawal |

## Top risks and mitigations

### 1. Claim front-running (mempool or sequencer observers)
*Attack:* a watcher sees a claim transaction and resubmits it with their own address as the recipient.
*Mitigations:*
- The claim is an EIP-712 signature by the link key over `(giftId, recipient, tokenOut, minAmountOut, relayer, relayerFee, deadline)`. Change any field and `SignatureChecker` fails (`test_frontrun_cannotRedirect`, `test_frontrun_cannotChangeAnySignedField`, `testFuzz_signatureBoundToRecipient`).
- The worst a copier can do is submit the honest claim early, which still pays the signed recipient and relayer.
- `minAmountOut` is signed and floored by the oracle, so sandwiching the swap is bounded by the sender's `maxSlippageBps` (hard cap 10%).

### 2. Signature replay
*Attack:* reuse a claim signature on another gift, contract or chain, or on the same gift twice.
*Mitigations:*
- `giftId` is in the struct, and the EIP-712 domain binds `chainId` and the vault address (`test_replay_otherGiftSameKey`, `test_replay_otherVaultDomain`).
- A gift moves `Open → Claimed/Refunded` exactly once, enforced by the status check before any transfer (`test_replay_sameGift`, plus the invariant `invariant_claimedOrRefundedExactlyOnce` with a `replayClaim` handler).
- OZ ECDSA rejects malleable high-s signatures. The `deadline` limits how long a signature stays valid.
- ERC-2771 forward requests carry per-signer nonces and deadlines (OZ `ERC2771Forwarder`), and a replay reverts (`test_claimDirect_viaTrustedForwarder_gasless`).

### 3. Leaked links
*Attack:* a link is forwarded, logged or screenshotted, and someone else claims it.
*Mitigations:*
- The secret sits in the URL fragment, which browsers never send to servers. The claim page removes it from the address bar right after reading it, and the app sets `Referrer-Policy: no-referrer`.
- The vault stores only the key's address, never the secret.
- Senders can `cancel` (refund) or `rekey` (issue a new link) any open link or wallet gift. GroupPot organizers can do the same for pot gifts (`test_rekey_leakedLink`, `test_cancelGift_and_rekey`).
- Every gift has an expiry, and unclaimed funds return to the sender.
- The UI says "treat this link like cash" wherever a link is shown.
- Residual risk: a leaked link claimed before the sender reacts is lost. For high-value gifts, use the wallet-address mode.

### 4. Relayer abuse
*Attacks:* a relayer overcharges, redirects funds, burns its own gas on reverting transactions, or gets spammed (DoS / gas drain).
*Mitigations (on-chain):*
- The relayer address and fee are inside the claimant's signature, so the relayer can't change them.
- The vault caps the fee at `maxRelayerFeeBps` (default 3%, hard cap 10%) (`test_relayerFee_capped`).
- A non-zero fee requires a non-zero relayer address.

*Mitigations (service, `scripts/src/relayer.ts`):*
- Only claims naming this relayer and paying at least the quoted fee are accepted.
- Targets and selectors are allowlisted (`claim`, `claimDirect`, `redeem` only), and forward requests have a gas cap.
- `forwarder.verify` runs before submission, and every transaction is simulated first so reverts cost nothing.
- Per-IP rate limit, a per-gift in-flight lock, an hourly transaction budget and a 20 KB body cap.
- The relayer key is a dedicated, low-balance keystore account (`stockgift-keeper`). Keep its float small and monitor it.

### 5. Oracle failure or manipulation
- Each read checks `answer > 0`, a valid round, `updatedAt` neither zero nor in the future, and age against a per-feed limit (25h for USDG, 4 days for equities).
- An optional L2 sequencer-uptime feed with a grace period is supported. None is published for chain 4663 yet, so this is a documented gap, ready to switch on through the Timelock.
- Optional min/max price bounds per feed. The USDG depeg guard of [0.97, 1.03] is enabled at deploy.
- The oracle is used only to set a floor on DEX execution. If the oracle fails, conversions halt and the cash fallback still works. If the oracle is wrong but fresh, losses are bounded by slippage tolerance against a manipulated pool.

### 6. Reentrancy and token weirdness
- Every state-changing entrypoint is `nonReentrant` and follows checks-effects-interactions. Status is set before any transfer, and GroupPot records the refund before calling the vault.
- SafeERC20 is used everywhere. Fee-on-transfer and rebasing tokens are rejected by a balance-delta check on deposit (`test_create_rejectsFeeOnTransfer`).
- Only allowlisted deposit and curated tokens are accepted. Stock tokens use `uiMultiplier` (no rebasing), which is compatible.
- `forceApprove` is reset to 0 after every swap, so the adapter keeps no lingering allowance.

### 7. Admin and governance risk
- `DEFAULT_ADMIN_ROLE` on every contract belongs to the Timelock (48h minimum enforced in the constructor). The deployer renounces its roles inside the deploy script, and the script asserts this.
- The guardian can only pause and unpause. While paused, claims and refunds also stop (a deliberate safety-over-liveness trade-off), so the guardian should be a multisig with a runbook.
- `setProjectToken` is one-time only, so a later compromised admin can't swap in a malicious token.
- Hard caps that no admin can exceed: fee ≤ 2%, slippage ≤ 10%, relayer fee ≤ 10%, reward tokens ≤ 10.

### 8. Accounting invariants (tested)
- `balanceOf(vault, token) == totalOpen[token] == Σ open gift amounts` (`invariant_vaultBalanceEqualsOpenGifts`).
- `balanceOf(scheduled) == Σ amountPerRelease × releasesLeft` (`invariant_scheduledBalanceEqualsCommitted`).
- Fee rewards paid ≤ fees notified (`testFuzz_rewardsConserved`). Pot payouts never exceed the pool (`testFuzz_proRataNeverExceedsPool`).

### 9. Frontend and compliance
- No secrets are sent to any backend, and the relayer never sees a link key (only signatures).
- Optional geoblock (`GEOBLOCK_COUNTRIES`), the ComplianceRegistry allowlist hook (off by default), and a risk-disclosure page.
- The wallet-SDK supply chain is guarded by pnpm's minimum-release-age policy.

## Known limitations
- Unlike the public Ethereum mempool, Robinhood Chain uses a centralized sequencer. Ordering attacks by the sequencer operator are out of scope.
- If a gift is claimed while pools are thin, it may revert on the oracle floor. That's by design, and the cash fallback is available.
- While the protocol is paused, refunds also pause.
- Static analysis: `slither .` reports no high or medium findings. One `reentrancy-balance` false positive is suppressed with a justification (see `src/base/ConversionBase.sol`). Low/informational findings are in `docs/slither-full.txt`.
- These contracts have not been audited by a third party. Get an independent audit before significant TVL.
