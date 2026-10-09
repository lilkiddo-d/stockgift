"use client";

import { useMemo, useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { decodeEventLog, erc20Abi, isAddress, maxUint256, zeroAddress, type Address, type Hex } from "viem";
import { giftVaultAbi, projectTokenHooksAbi } from "@/config/generated/abis";
import {
  addresses,
  appUrl,
  CARD_DESIGNS,
  FIRST_PREMIUM_DESIGN,
  isDeployed,
  STOCKS,
  tokenFeaturesEnabled,
  USDG,
} from "@/lib/config";
import { buildClaimLink, fmt, newClaimKey, parseAmount } from "@/lib/gift";
import { CardPreview, Status, useTx } from "@/components/ui";
import { ShareLink } from "@/components/ShareLink";

type Mode = "link" | "wallet" | "card";
type StockMode = "fixed" | "choose" | "none";

export default function CreateGift() {
  const { address, isConnected } = useAccount();
  const [mode, setMode] = useState<Mode>("link");
  const [depositToken, setDepositToken] = useState<Address>(USDG.address);
  const [amount, setAmount] = useState("25");
  const [stockMode, setStockMode] = useState<StockMode>("fixed");
  const [target, setTarget] = useState<Address>(STOCKS[0]?.address ?? zeroAddress);
  const [message, setMessage] = useState("");
  const [design, setDesign] = useState(1);
  const [expiryDays, setExpiryDays] = useState(30);
  const [slippagePct, setSlippagePct] = useState("3");
  const [recipient, setRecipient] = useState("");
  const [result, setResult] = useState<{ id: bigint; link?: string; mode: Mode } | undefined>();
  const tx = useTx();

  const isCash = depositToken.toLowerCase() === USDG.address.toLowerCase();
  const amountWei = useMemo(() => {
    try {
      return parseAmount(amount, depositToken);
    } catch {
      return 0n;
    }
  }, [amount, depositToken]);

  const { data: balance } = useReadContract({
    address: depositToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: depositToken,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, addresses.vault] : undefined,
    query: { enabled: !!address },
  });
  const { data: feeBps } = useReadContract({ address: addresses.vault, abi: giftVaultAbi, functionName: "feeBps", query: { enabled: isDeployed } });
  const { data: feeExempt } = useReadContract({
    address: addresses.hooks,
    abi: projectTokenHooksAbi,
    functionName: "isFeeExempt",
    args: address ? [address] : undefined,
    query: { enabled: !!address && tokenFeaturesEnabled },
  });
  const { data: hasPremium } = useReadContract({
    address: addresses.hooks,
    abi: projectTokenHooksAbi,
    functionName: "hasPremium",
    args: address ? [address] : undefined,
    query: { enabled: !!address && tokenFeaturesEnabled },
  });

  const fee = feeExempt ? 0n : (amountWei * BigInt(feeBps ?? 0)) / 10_000n;
  const effectiveTarget: Address = !isCash || stockMode !== "fixed" ? zeroAddress : target;
  const ticker =
    stockMode === "choose" && isCash
      ? "Your pick"
      : (STOCKS.find((s) => s.address === (isCash ? target : depositToken))?.symbol ?? "USDG");
  const recipientOk = mode !== "wallet" || isAddress(recipient);
  const designs = CARD_DESIGNS.filter((d) => tokenFeaturesEnabled || d.id < FIRST_PREMIUM_DESIGN);

  async function create() {
    if (!address) return;
    if ((allowance ?? 0n) < amountWei) {
      const ok = await tx.send(
        { address: depositToken, abi: erc20Abi, functionName: "approve", args: [addresses.vault, maxUint256] },
        "Approve",
      );
      if (!ok) return;
      await refetchAllowance();
    }
    let pk: Hex | undefined;
    let claimKey: Address = zeroAddress;
    if (mode === "link") {
      const k = newClaimKey();
      pk = k.pk;
      claimKey = k.address;
    } else if (mode === "wallet") {
      claimKey = recipient as Address;
    }
    const params = {
      token: depositToken,
      amount: amountWei,
      claimKey,
      expiry: BigInt(Math.floor(Date.now() / 1000) + expiryDays * 86400),
      targetToken: effectiveTarget,
      recipientChooses: isCash && stockMode === "choose",
      maxSlippageBps: Math.round(Number(slippagePct) * 100),
      card: mode === "card",
      cardRecipient: mode === "card" ? (isAddress(recipient) ? (recipient as Address) : address) : zeroAddress,
      design,
      message,
    } as const;
    const receipt = await tx.send(
      { address: addresses.vault, abi: giftVaultAbi, functionName: "createGift", args: [params] },
      "Create gift",
    );
    if (!receipt) return;
    for (const log of receipt.logs) {
      try {
        const ev = decodeEventLog({ abi: giftVaultAbi, data: log.data, topics: log.topics });
        if (ev.eventName === "GiftCreated") {
          const id = ev.args.giftId;
          const link = pk ? buildClaimLink(appUrl || window.location.origin, "g", id, pk) : undefined;
          if (link) {
            try {
              const saved = JSON.parse(localStorage.getItem("stockgift:links") || "{}");
              saved[id.toString()] = link;
              localStorage.setItem("stockgift:links", JSON.stringify(saved));
            } catch {}
          }
          setResult({ id, link, mode });
        }
      } catch {}
    }
  }

  if (result) {
    return (
      <div className="card narrow">
        <h1>Gift #{result.id.toString()} is ready 🎁</h1>
        {result.link ? (
          <ShareLink link={result.link} />
        ) : result.mode === "card" ? (
          <p>The gift card NFT was minted. Its holder can burn it on the claim page to receive the gift.</p>
        ) : (
          <p>
            The gift is waiting for <span className="mono">{recipient}</span>. They can claim it on the claim page by
            connecting that wallet: <a href={`/claim?gift=${result.id}`}>/claim?gift={result.id.toString()}</a>
          </p>
        )}
        <button className="btn ghost block" onClick={() => setResult(undefined)}>
          Send another
        </button>
      </div>
    );
  }

  return (
    <div className="grid two">
      <div className="card">
        <h1>Send a gift</h1>
        {!isDeployed && <div className="notice">Contracts are not deployed for this build yet.</div>}

        <label>How will they receive it?</label>
        <div className="segmented">
          {(["link", "wallet", "card"] as Mode[]).map((m) => (
            <button key={m} className={mode === m ? "on" : ""} onClick={() => setMode(m)}>
              {m === "link" ? "Link / QR" : m === "wallet" ? "Wallet address" : "Gift card NFT"}
            </button>
          ))}
        </div>

        {mode !== "link" && (
          <>
            <label>{mode === "wallet" ? "Recipient wallet" : "Send the card to (default: you)"}</label>
            <input placeholder="0x…" value={recipient} onChange={(e) => setRecipient(e.target.value.trim())} />
            {recipient && !isAddress(recipient) && <div className="hint" style={{ color: "var(--danger)" }}>Not a valid address</div>}
          </>
        )}

        <label>Fund with</label>
        <select value={depositToken} onChange={(e) => setDepositToken(e.target.value as Address)}>
          <option value={USDG.address}>USDG (dollars)</option>
          {STOCKS.map((s) => (
            <option key={s.address} value={s.address}>
              {s.symbol} shares you hold
            </option>
          ))}
        </select>

        <label>Amount</label>
        <input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
        <div className="hint">
          Balance: {fmt(balance, depositToken)} · Protocol fee: {fmt(fee, depositToken)}
          {feeExempt ? " ($GIFT tier: no fee)" : ""}
        </div>

        {isCash && (
          <>
            <label>What do they get?</label>
            <div className="segmented">
              <button className={stockMode === "fixed" ? "on" : ""} onClick={() => setStockMode("fixed")}>
                A stock I choose
              </button>
              <button className={stockMode === "choose" ? "on" : ""} onClick={() => setStockMode("choose")}>
                They pick
              </button>
              <button className={stockMode === "none" ? "on" : ""} onClick={() => setStockMode("none")}>
                Dollars
              </button>
            </div>
            {stockMode === "fixed" && (
              <div className="chips" style={{ marginTop: 10 }}>
                {STOCKS.map((s) => (
                  <button key={s.address} className={`chip ${target === s.address ? "on" : ""}`} onClick={() => setTarget(s.address)}>
                    {s.symbol}
                  </button>
                ))}
              </div>
            )}
            <div className="hint">Dollars convert into the stock when the gift is claimed, at the market price then.</div>
          </>
        )}

        <label>Message</label>
        <textarea maxLength={280} value={message} onChange={(e) => setMessage(e.target.value)} placeholder="Happy birthday! 🎉" />

        <label>Card design</label>
        <div className="designs">
          {designs.map((d) => {
            const locked = !!(d as { premium?: boolean }).premium && !hasPremium;
            return (
              <div
                key={d.id}
                className={`design ${design === d.id ? "on" : ""} ${locked ? "locked" : ""}`}
                style={{ background: `linear-gradient(135deg, ${d.from}, ${d.to})`, color: d.fg }}
                onClick={() => !locked && setDesign(d.id)}
                title={locked ? "Premium design: requires the $GIFT holder tier" : d.name}
              >
                {d.name}
                {(d as { premium?: boolean }).premium ? " ★" : ""}
              </div>
            );
          })}
        </div>
        {mode !== "card" && <div className="hint">The design is used for the link preview; choose “Gift card NFT” to mint it on-chain.</div>}

        <div className="grid two">
          <div>
            <label>Unclaimed gift returns after</label>
            <select value={expiryDays} onChange={(e) => setExpiryDays(Number(e.target.value))}>
              {[7, 30, 90, 180, 365].map((d) => (
                <option key={d} value={d}>
                  {d} days
                </option>
              ))}
            </select>
          </div>
          <div>
            <label>Max price slippage</label>
            <select value={slippagePct} onChange={(e) => setSlippagePct(e.target.value)}>
              {["1", "2", "3", "5"].map((s) => (
                <option key={s} value={s}>
                  {s}%
                </option>
              ))}
            </select>
          </div>
        </div>

        <button
          className="btn block"
          disabled={!isConnected || tx.busy || amountWei === 0n || !recipientOk || (balance !== undefined && balance < amountWei)}
          onClick={create}
        >
          {!isConnected ? "Connect a wallet to continue" : tx.busy ? "Working…" : `Create gift`}
        </button>
        <Status status={tx.status} error={tx.error} />
      </div>

      <div>
        <CardPreview
          design={design}
          ticker={ticker}
          amount={amountWei ? fmt(amountWei - fee, depositToken, 2) : ""}
          message={message}
        />
        <div className="card small muted">
          <strong>Before you send:</strong> anyone with the link can claim the gift, so share it privately. You can cancel
          an unclaimed link gift at any time from the claim page. Stock prices move; the recipient receives what the
          gift buys at claim time.
        </div>
      </div>
    </div>
  );
}
