"use client";

import { useMemo, useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { erc20Abi, formatUnits, maxUint256, parseUnits } from "viem";
import { feeCollectorAbi, projectTokenHooksAbi } from "@/config/generated/abis";
import { addresses, projectToken, tokenFeaturesEnabled, USDG } from "@/lib/config";
import { fmt } from "@/lib/gift";
import { Status, useTx } from "@/components/ui";

/** $GIFT staking: only rendered when NEXT_PUBLIC_PROJECT_TOKEN is set. */
export default function Stake() {
  const { address } = useAccount();
  const tx = useTx();
  const [amount, setAmount] = useState("");
  const enabled = tokenFeaturesEnabled && !!address;

  const { data: onchainToken } = useReadContract({ address: addresses.hooks, abi: projectTokenHooksAbi, functionName: "projectToken", query: { enabled: tokenFeaturesEnabled } });
  const { data: bal, refetch: rb } = useReadContract({ address: projectToken, abi: erc20Abi, functionName: "balanceOf", args: address ? [address] : undefined, query: { enabled } });
  const { data: allowance, refetch: ra } = useReadContract({ address: projectToken, abi: erc20Abi, functionName: "allowance", args: address ? [address, addresses.feeCollector] : undefined, query: { enabled } });
  const { data: staked, refetch: rs } = useReadContract({ address: addresses.feeCollector, abi: feeCollectorAbi, functionName: "stakedBalance", args: address ? [address] : undefined, query: { enabled } });
  const { data: earned, refetch: re } = useReadContract({ address: addresses.feeCollector, abi: feeCollectorAbi, functionName: "earned", args: address ? [address, USDG.address] : undefined, query: { enabled } });
  const { data: premium } = useReadContract({ address: addresses.hooks, abi: projectTokenHooksAbi, functionName: "premiumThreshold", query: { enabled: tokenFeaturesEnabled } });
  const { data: feeFree } = useReadContract({ address: addresses.hooks, abi: projectTokenHooksAbi, functionName: "feeFreeThreshold", query: { enabled: tokenFeaturesEnabled } });

  const amt = useMemo(() => {
    try {
      return parseUnits(amount || "0", 18);
    } catch {
      return 0n;
    }
  }, [amount]);
  const refresh = () => [rb, ra, rs, re].forEach((r) => r());

  if (!tokenFeaturesEnabled) return <div className="card narrow">Token features are not enabled.</div>;
  const live = onchainToken && onchainToken.toLowerCase() === projectToken!.toLowerCase();

  async function stake() {
    if ((allowance ?? 0n) < amt) {
      if (!(await tx.send({ address: projectToken!, abi: erc20Abi, functionName: "approve", args: [addresses.feeCollector, maxUint256] }, "Approve"))) return;
    }
    if (await tx.send({ address: addresses.feeCollector, abi: feeCollectorAbi, functionName: "stake", args: [amt] }, "Stake")) refresh();
  }
  async function unstake() {
    if (await tx.send({ address: addresses.feeCollector, abi: feeCollectorAbi, functionName: "unstake", args: [amt] }, "Unstake")) refresh();
  }
  async function claim() {
    if (await tx.send({ address: addresses.feeCollector, abi: feeCollectorAbi, functionName: "claimRewards" }, "Claim rewards")) refresh();
  }

  return (
    <div className="card narrow">
      <h1>$GIFT</h1>
      {!live && <div className="notice">The token has not been connected on-chain yet (pending Timelock).</div>}
      <p className="muted">
        Stake $GIFT to share protocol fees. Staked balances held for 24h unlock premium card designs (≥{" "}
        {premium !== undefined ? formatUnits(premium, 18) : "…"}) and zero gift fees (≥ {feeFree !== undefined ? formatUnits(feeFree, 18) : "…"}).
      </p>
      <div className="spread"><span className="muted">Wallet</span><strong>{bal !== undefined ? formatUnits(bal, 18) : "-"} GIFT</strong></div>
      <div className="spread"><span className="muted">Staked</span><strong>{staked !== undefined ? formatUnits(staked, 18) : "-"} GIFT</strong></div>
      <div className="spread"><span className="muted">Fee rewards</span><strong>{fmt(earned, USDG.address)}</strong></div>
      <label>Amount</label>
      <input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
      <div className="row" style={{ marginTop: 12 }}>
        <button className="btn" disabled={!live || !address || amt === 0n || tx.busy} onClick={stake}>Stake</button>
        <button className="btn ghost" disabled={!live || !address || amt === 0n || tx.busy} onClick={unstake}>Unstake</button>
        <button className="btn ghost" disabled={!live || !address || !earned || tx.busy} onClick={claim}>Claim rewards</button>
      </div>
      <Status status={tx.status} error={tx.error} />
    </div>
  );
}
