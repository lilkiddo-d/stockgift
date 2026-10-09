"use client";

import { use, useCallback, useEffect, useMemo, useState } from "react";
import { useAccount, usePublicClient, useReadContract } from "wagmi";
import { erc20Abi, maxUint256, zeroAddress, type Address } from "viem";
import { groupPotAbi } from "@/config/generated/abis";
import { addresses, deployedAtBlock, tokenMeta, USDG } from "@/lib/config";
import { fmt, parseAmount } from "@/lib/gift";
import { Status, useTx } from "@/components/ui";

const STATUS = ["", "Collecting", "Sent to recipient", "Cancelled", "Returned to contributors"];

export default function PotPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const potId = BigInt(/^\d+$/.test(id) ? id : "0");
  const { address } = useAccount();
  const client = usePublicClient();
  const tx = useTx();
  const [amount, setAmount] = useState("10");
  const [note, setNote] = useState("");
  const [contribs, setContribs] = useState<{ who: Address; amount: bigint; message: string }[]>([]);

  const { data: pot, refetch } = useReadContract({ address: addresses.groupPot, abi: groupPotAbi, functionName: "getPot", args: [potId] });
  const { data: title } = useReadContract({ address: addresses.groupPot, abi: groupPotAbi, functionName: "potTitle", args: [potId] });
  const { data: mine, refetch: refetchMine } = useReadContract({
    address: addresses.groupPot,
    abi: groupPotAbi,
    functionName: "contributions",
    args: address ? [potId, address] : undefined,
    query: { enabled: !!address },
  });
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: USDG.address,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, addresses.groupPot] : undefined,
    query: { enabled: !!address },
  });

  const load = useCallback(async () => {
    if (!client) return;
    const logs = await client.getContractEvents({
      address: addresses.groupPot,
      abi: groupPotAbi,
      eventName: "Contributed",
      args: { potId },
      fromBlock: deployedAtBlock,
    });
    setContribs(logs.map((l) => ({ who: l.args.contributor!, amount: l.args.amount!, message: l.args.message ?? "" })));
  }, [client, potId]);

  useEffect(() => {
    load().catch(() => {});
  }, [load]);

  const amt = useMemo(() => {
    try {
      return parseAmount(amount, USDG.address);
    } catch {
      return 0n;
    }
  }, [amount]);

  if (!pot || pot.status === 0) return <div className="card narrow">Loading group gift…</div>;

  const refresh = () => {
    refetch();
    refetchMine();
    load();
  };
  const isOrganizer = address?.toLowerCase() === pot.organizer.toLowerCase();
  const open = pot.status === 1 && Number(pot.closesAt) * 1000 > Date.now();

  async function contribute() {
    if ((allowance ?? 0n) < amt) {
      const ok = await tx.send(
        { address: USDG.address, abi: erc20Abi, functionName: "approve", args: [addresses.groupPot, maxUint256] },
        "Approve",
      );
      if (!ok) return;
      await refetchAllowance();
    }
    const r = await tx.send(
      { address: addresses.groupPot, abi: groupPotAbi, functionName: "contribute", args: [potId, amt, note] },
      "Contribute",
    );
    if (r) refresh();
  }

  async function act(fn: "finalize" | "cancelPot" | "withdraw" | "syncRefund" | "cancelGift", label: string) {
    const r = await tx.send({ address: addresses.groupPot, abi: groupPotAbi, functionName: fn, args: [potId] }, label);
    if (r) refresh();
  }

  return (
    <div className="grid two">
      <div className="card">
        <span className="muted small">Group gift #{id}</span>
        <h1>{title || "Group gift"}</h1>
        <div className="spread">
          <span className="muted">Raised</span>
          <strong style={{ fontSize: "1.6rem" }}>{fmt(pot.total, pot.token, 2)}</strong>
        </div>
        <div className="spread small">
          <span className="muted">Gift</span>
          <span>{pot.recipientChooses ? "Recipient picks a stock" : (tokenMeta(pot.targetToken)?.symbol ?? "Dollars")}</span>
        </div>
        <div className="spread small">
          <span className="muted">Status</span>
          <span>{STATUS[pot.status]}</span>
        </div>
        <div className="spread small">
          <span className="muted">Closes</span>
          <span>{new Date(Number(pot.closesAt) * 1000).toLocaleString()}</span>
        </div>

        {open && (
          <>
            <label>Your contribution (USDG)</label>
            <input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
            <label>Add a note</label>
            <input maxLength={280} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Congrats!" />
            <button className="btn block" disabled={!address || amt === 0n || tx.busy} onClick={contribute}>
              {address ? "Chip in" : "Connect a wallet"}
            </button>
          </>
        )}

        {isOrganizer && pot.status === 1 && (
          <div className="row" style={{ marginTop: 18 }}>
            <button className="btn" disabled={tx.busy || pot.total === 0n} onClick={() => act("finalize", "Finalize")}>
              Finalize and send
            </button>
            <button className="btn ghost" disabled={tx.busy} onClick={() => act("cancelPot", "Cancel")}>
              Cancel and refund everyone
            </button>
          </div>
        )}
        {isOrganizer && pot.status === 2 && (
          <div className="small" style={{ marginTop: 18 }}>
            <p>Sent! Share the private claim link you saved when creating the pot.</p>
            <button className="btn ghost small" disabled={tx.busy} onClick={() => act("cancelGift", "Cancel gift")}>
              Link leaked? Cancel the gift
            </button>
          </div>
        )}
        {pot.status === 2 && (
          <button className="btn ghost small" style={{ marginTop: 12 }} disabled={tx.busy} onClick={() => act("syncRefund", "Check refund")}>
            Gift expired unclaimed? Return funds
          </button>
        )}
        {(pot.status === 3 || pot.status === 4) && (mine ?? 0n) > 0n && (
          <button className="btn block" disabled={tx.busy} onClick={() => act("withdraw", "Withdraw")}>
            Withdraw my share
          </button>
        )}
        <Status status={tx.status} error={tx.error} />
      </div>

      <div className="card">
        <h2 style={{ marginTop: 0 }}>Contributors</h2>
        {contribs.length === 0 && <p className="muted">Be the first to chip in.</p>}
        {contribs.map((c, i) => (
          <div key={i} className="spread" style={{ borderBottom: "1px solid var(--line)", padding: "8px 0" }}>
            <div>
              <div className="mono small">
                {c.who.slice(0, 8)}…{c.who.slice(-4)}
              </div>
              {c.message && <div className="small">{c.message}</div>}
            </div>
            <strong>{fmt(c.amount, pot.token, 2)}</strong>
          </div>
        ))}
        {pot.targetToken === zeroAddress && !pot.recipientChooses && <p className="hint">Delivered as dollars.</p>}
      </div>
    </div>
  );
}
