"use client";

import { Suspense, useEffect, useMemo, useRef, useState } from "react";
import { useSearchParams } from "next/navigation";
import { useAccount, usePublicClient, useSignTypedData } from "wagmi";
import { encodeFunctionData, isAddress, zeroAddress, type Address, type Hex } from "viem";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { giftCardNFTAbi, giftVaultAbi, groupPotAbi, trustedForwarderAbi } from "@/config/generated/abis";
import { addresses, chain, relayerUrl, STOCKS, tokenMeta } from "@/lib/config";
import { claimTypes, fetchGiftCreated, fmt, parseClaimFragment, quoteSwap, signClaim, type ClaimParams } from "@/lib/gift";
import { CardPreview, errMsg, Status, useTx } from "@/components/ui";

type Gift = {
  sender: Address;
  expiry: bigint;
  maxSlippageBps: number;
  status: number;
  recipientChooses: boolean;
  isCard: boolean;
  token: Address;
  claimKey: Address;
  targetToken: Address;
  amount: bigint;
};

const STATUS = ["Unknown", "Ready to claim", "Claimed", "Returned to sender"];

function ClaimInner() {
  const search = useSearchParams();
  const client = usePublicClient();
  const { address } = useAccount();
  const { signTypedDataAsync } = useSignTypedData();
  const tx = useTx();

  const [frag, setFrag] = useState<ReturnType<typeof parseClaimFragment>>();
  const [giftId, setGiftId] = useState<bigint>();
  const [gift, setGift] = useState<Gift>();
  const [message, setMessage] = useState<string>("");
  const [loadErr, setLoadErr] = useState("");
  const [recipient, setRecipient] = useState("");
  const [tokenOut, setTokenOut] = useState<Address>();
  const [quote, setQuote] = useState<bigint>();
  const [quoteErr, setQuoteErr] = useState("");
  const [relayQuote, setRelayQuote] = useState<{ relayer: Address; fee: string }>();
  const [done, setDone] = useState<string>("");

  const fragRef = useRef<ReturnType<typeof parseClaimFragment> | null>(null);
  const cardParam = search.get("card");
  const walletGiftParam = search.get("gift");

  // 1. figure out which gift we are looking at
  useEffect(() => {
    // Read the secret exactly once (effects can re-run), then strip it from the address bar;
    // it stays in memory only.
    if (fragRef.current === null) {
      fragRef.current = parseClaimFragment(window.location.hash);
      if (fragRef.current) history.replaceState(null, "", window.location.pathname + window.location.search);
    }
    const f = fragRef.current;
    setFrag(f);
    (async () => {
      try {
        if (f?.kind === "g") setGiftId(f.id);
        else if (f?.kind === "p" && client) {
          const pot = await client.readContract({ address: addresses.groupPot, abi: groupPotAbi, functionName: "getPot", args: [f.id] });
          if (pot.status !== 2 && pot.status !== 4) {
            setLoadErr("This group gift is still collecting contributions. Check back once the organizer finalizes it.");
            return;
          }
          setGiftId(pot.giftId);
        } else if (cardParam) setGiftId(BigInt(cardParam));
        else if (walletGiftParam) setGiftId(BigInt(walletGiftParam));
        else setLoadErr("This link is incomplete. Ask the sender to share it again.");
      } catch (e) {
        setLoadErr(errMsg(e));
      }
    })();
  }, [client, cardParam, walletGiftParam]);

  // 2. load the gift
  useEffect(() => {
    if (giftId === undefined || !client) return;
    (async () => {
      try {
        const g = (await client.readContract({ address: addresses.vault, abi: giftVaultAbi, functionName: "getGift", args: [giftId] })) as Gift;
        if (g.status === 0) throw new Error("Gift not found");
        setGift(g);
        setTokenOut(g.targetToken !== zeroAddress ? g.targetToken : g.token);
        const created = await fetchGiftCreated(client, giftId).catch(() => undefined);
        setMessage(created?.message ?? "");
      } catch (e) {
        setLoadErr(errMsg(e));
      }
    })();
  }, [giftId, client]);

  useEffect(() => {
    if (address && !recipient) setRecipient(address);
  }, [address, recipient]);

  const options = useMemo(() => {
    if (!gift) return [];
    const set = new Map<string, Address>();
    if (gift.targetToken !== zeroAddress) set.set(gift.targetToken.toLowerCase(), gift.targetToken);
    if (gift.recipientChooses) STOCKS.forEach((s) => set.set(s.address.toLowerCase(), s.address));
    set.set(gift.token.toLowerCase(), gift.token);
    return [...set.values()];
  }, [gift]);

  // 3. relayer quote (gasless)
  useEffect(() => {
    if (!relayerUrl || giftId === undefined || !gift) return;
    fetch(`${relayerUrl}/quote?giftId=${giftId}`)
      .then((r) => (r.ok ? r.json() : undefined))
      .then((q) => q && setRelayQuote(q))
      .catch(() => {});
  }, [giftId, gift]);

  const relayerFee = relayQuote ? BigInt(relayQuote.fee) : 0n;
  const amountIn = gift ? gift.amount - relayerFee : 0n;

  // 4. live swap quote
  useEffect(() => {
    if (!gift || !tokenOut || !client) return;
    setQuote(undefined);
    setQuoteErr("");
    quoteSwap(client, gift.token, tokenOut, amountIn)
      .then(setQuote)
      .catch(() => setQuoteErr("No live quote right now (market closed or low liquidity). You can take the gift as dollars instead."));
  }, [gift, tokenOut, client, amountIn]);

  function claimParams(relayer: Address, fee: bigint): ClaimParams {
    const minOut = quote && tokenOut !== gift!.token ? (quote * 99n) / 100n : 0n;
    return {
      recipient: recipient as Address,
      tokenOut: tokenOut!,
      minAmountOut: minOut,
      relayer,
      relayerFee: fee,
      deadline: BigInt(Math.floor(Date.now() / 1000) + 20 * 60),
    };
  }

  async function relay(path: string, body: unknown) {
    const res = await fetch(`${relayerUrl}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body, (_, v) => (typeof v === "bigint" ? v.toString() : v)),
    });
    const j = await res.json();
    if (!res.ok) throw new Error(j.error || "Relayer error");
    await client!.waitForTransactionReceipt({ hash: j.txHash as Hex });
    return j.txHash as string;
  }

  async function claim() {
    if (!gift || giftId === undefined || !tokenOut) return;
    tx.setError("");
    try {
      if (gift.isCard && relayQuote && address) {
        // gasless card redeem: holder signs an ERC-2771 ForwardRequest, relayer executes it
        const c = claimParams(relayQuote.relayer, relayerFee);
        const data = encodeFunctionData({ abi: giftCardNFTAbi, functionName: "redeem", args: [giftId, c] });
        const nonce = await client!.readContract({ address: addresses.forwarder, abi: trustedForwarderAbi, functionName: "nonces", args: [address] });
        const request = { from: address, to: addresses.cardNFT, value: 0n, gas: 800_000n, nonce, deadline: Number(c.deadline), data };
        const signature = await signTypedDataAsync({
          domain: { name: "Stockgift Forwarder", version: "1", chainId: chain.id, verifyingContract: addresses.forwarder },
          types: {
            ForwardRequest: [
              { name: "from", type: "address" },
              { name: "to", type: "address" },
              { name: "value", type: "uint256" },
              { name: "gas", type: "uint256" },
              { name: "nonce", type: "uint256" },
              { name: "deadline", type: "uint48" },
              { name: "data", type: "bytes" },
            ],
          },
          primaryType: "ForwardRequest",
          message: request,
        });
        const { nonce: _n, ...rest } = request;
        void _n;
        setDone(await relay("/relay/forward", { request: { ...rest, signature } }));
        return;
      }
      if (gift.isCard) {
        const r = await tx.send(
          { address: addresses.cardNFT, abi: giftCardNFTAbi, functionName: "redeem", args: [giftId, claimParams(zeroAddress, 0n)] },
          "Redeem card",
        );
        if (r) setDone(r.transactionHash);
        return;
      }
      const useRelayer = !!relayQuote;
      const c = useRelayer ? claimParams(relayQuote!.relayer, relayerFee) : claimParams(zeroAddress, 0n);
      let signature: Hex;
      if (frag?.pk) {
        signature = await signClaim(frag.pk, giftId, c); // link key signs, binding the recipient
      } else {
        // wallet gift: the recipient wallet itself is the claim key
        signature = await signTypedDataAsync({
          domain: { name: "Stockgift", version: "1", chainId: chain.id, verifyingContract: addresses.vault },
          types: claimTypes,
          primaryType: "Claim",
          message: { giftId, ...c },
        });
      }
      if (useRelayer) {
        const hash = await relay("/relay/claim", { giftId: giftId.toString(), claim: c, signature });
        setDone(hash);
      } else {
        const r = await tx.send({ address: addresses.vault, abi: giftVaultAbi, functionName: "claim", args: [giftId, c, signature] }, "Claim");
        if (r) setDone(r.transactionHash);
      }
    } catch (e) {
      tx.setError(errMsg(e));
    }
  }

  async function cancel() {
    if (giftId === undefined) return;
    const r = await tx.send({ address: addresses.vault, abi: giftVaultAbi, functionName: "cancel", args: [giftId] }, "Cancel gift");
    if (r) setGift({ ...gift!, status: 3 });
  }

  if (loadErr) return <div className="card narrow notice error">{loadErr}</div>;
  if (!gift) return <div className="card narrow">Loading your gift…</div>;

  const outMeta = tokenMeta(tokenOut);
  const ticker = gift.targetToken !== zeroAddress ? tokenMeta(gift.targetToken)?.symbol : gift.recipientChooses ? "Your pick" : tokenMeta(gift.token)?.symbol;
  const expired = Number(gift.expiry) * 1000 < Date.now();
  const isSender = address && address.toLowerCase() === gift.sender.toLowerCase();
  const canClaim = gift.status === 1 && !expired && isAddress(recipient);
  const needsWallet = gift.isCard || (!frag && !relayQuote);

  if (done) {
    return (
      <div className="card narrow">
        <h1>It&apos;s yours 🎉</h1>
        <p>
          The gift was delivered to <span className="mono">{recipient}</span>.
        </p>
        <a href={`${chain.blockExplorers.default.url}/tx/${done}`} target="_blank" rel="noreferrer">
          View transaction
        </a>
        <p className="muted small" style={{ marginTop: 16 }}>
          Tokenized stocks track the price of the underlying share and can go down as well as up. See the{" "}
          <a href="/risk">risk disclosure</a>.
        </p>
      </div>
    );
  }

  return (
    <div className="grid two">
      <div>
        <CardPreview design={1} ticker={ticker ?? ""} amount={fmt(gift.amount, gift.token, 2)} message={message} />
        <div className="card small">
          <div className="spread">
            <span className="muted">Status</span>
            <strong>{expired && gift.status === 1 ? "Expired — returning to sender" : STATUS[gift.status]}</strong>
          </div>
          <div className="spread">
            <span className="muted">Claim by</span>
            <span>{new Date(Number(gift.expiry) * 1000).toLocaleDateString()}</span>
          </div>
        </div>
      </div>

      <div className="card">
        <h1>You&apos;ve received a gift</h1>
        {gift.status !== 1 ? (
          <p className="muted">This gift is no longer claimable.</p>
        ) : (
          <>
            <label>1. Where should we send it?</label>
            <div className="row">
              <ConnectButton label="Connect or create a wallet" showBalance={false} />
            </div>
            <input
              style={{ marginTop: 10 }}
              placeholder="…or paste your wallet address (0x…)"
              value={recipient}
              onChange={(e) => setRecipient(e.target.value.trim())}
            />
            <div className="hint">
              New to this? Choose <strong>Coinbase Smart Wallet</strong> to create a wallet with a passkey — no app or seed phrase.
              {relayQuote ? " You won't need any ETH for gas." : ""}
            </div>

            <label>2. Receive as</label>
            <div className="chips">
              {options.map((o) => (
                <button key={o} className={`chip ${tokenOut === o ? "on" : ""}`} onClick={() => setTokenOut(o)}>
                  {tokenMeta(o)?.symbol ?? o.slice(0, 8)}
                  {o.toLowerCase() === gift.token.toLowerCase() && gift.targetToken !== zeroAddress ? " (as is)" : ""}
                </button>
              ))}
            </div>
            <div className="hint">
              {tokenOut?.toLowerCase() === gift.token.toLowerCase()
                ? `You'll receive ${fmt(amountIn, gift.token)}.`
                : quote
                  ? `≈ ${fmt(quote, tokenOut)} at today's price (at least ${fmt((quote * 99n) / 100n, tokenOut)}).`
                  : quoteErr || "Getting a live price…"}
              {relayerFee > 0n ? ` Includes a ${fmt(relayerFee, gift.token)} network fee.` : ""}
            </div>

            <button className="btn block" disabled={!canClaim || tx.busy || (needsWallet && !address)} onClick={claim}>
              {tx.busy ? "Claiming…" : `Claim ${outMeta?.symbol ?? ""}`}
            </button>
            {needsWallet && !address && <div className="hint">Connect the wallet that holds this gift to claim it.</div>}
            <Status status={tx.status} error={tx.error} />
          </>
        )}
        {isSender && gift.status === 1 && !gift.isCard && (
          <div style={{ marginTop: 24 }}>
            <h3>You sent this gift</h3>
            <p className="muted small">Link leaked or sent to the wrong person? Cancel it and the funds return to you.</p>
            <button className="btn danger small" disabled={tx.busy} onClick={cancel}>
              Cancel gift
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

export default function ClaimPage() {
  return (
    <Suspense fallback={<div className="card narrow">Loading…</div>}>
      <ClaimInner />
    </Suspense>
  );
}
