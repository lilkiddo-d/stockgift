"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useAccount, usePublicClient, useReadContract } from "wagmi";
import { erc20Abi, isAddress, maxUint256, zeroAddress, type Address } from "viem";
import { scheduledGiftsAbi } from "@/config/generated/abis";
import { addresses, deployedAtBlock, STOCKS, USDG } from "@/lib/config";
import { fmt, parseAmount } from "@/lib/gift";
import { Status, useTx } from "@/components/ui";

type Row = {
  id: bigint;
  sender: Address;
  recipient: Address;
  token: Address;
  targetToken: Address;
  amountPerRelease: bigint;
  releasesLeft: number;
  nextReleaseAt: bigint;
  interval: bigint;
  active: boolean;
};

export default function Scheduled() {
  const { address } = useAccount();
  const client = usePublicClient();
  const tx = useTx();

  const [recipient, setRecipient] = useState("");
  const [amount, setAmount] = useState("20");
  const [releases, setReleases] = useState(12);
  const [cadence, setCadence] = useState<"weekly" | "monthly">("monthly");
  const [target, setTarget] = useState<Address>(STOCKS[0]?.address ?? zeroAddress);
  const [message, setMessage] = useState("");
  const [rows, setRows] = useState<Row[]>([]);

  const per = useMemo(() => {
    try {
      return parseAmount(amount, USDG.address);
    } catch {
      return 0n;
    }
  }, [amount]);
  const total = per * BigInt(releases);
  const { data: feeBps } = useReadContract({ address: addresses.scheduled, abi: scheduledGiftsAbi, functionName: "feeBps" });
  const fee = (total * BigInt(feeBps ?? 0)) / 10_000n;
  const { data: allowance, refetch } = useReadContract({
    address: USDG.address,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, addresses.scheduled] : undefined,
    query: { enabled: !!address },
  });

  const load = useCallback(async () => {
    if (!client || !address) return;
    const [asSender, asRecipient] = await Promise.all([
      client.getContractEvents({ address: addresses.scheduled, abi: scheduledGiftsAbi, eventName: "ScheduleCreated", args: { sender: address }, fromBlock: deployedAtBlock }),
      client.getContractEvents({ address: addresses.scheduled, abi: scheduledGiftsAbi, eventName: "ScheduleCreated", args: { recipient: address }, fromBlock: deployedAtBlock }),
    ]);
    const ids = [...new Set([...asSender, ...asRecipient].map((l) => l.args.scheduleId!))];
    const out: Row[] = [];
    for (const id of ids) {
      const s = await client.readContract({ address: addresses.scheduled, abi: scheduledGiftsAbi, functionName: "getSchedule", args: [id] });
      out.push({ id, ...s, amountPerRelease: BigInt(s.amountPerRelease) } as Row);
    }
    setRows(out.sort((a, b) => Number(b.id - a.id)));
  }, [client, address]);

  useEffect(() => {
    load().catch(() => {});
  }, [load]);

  async function create() {
    if ((allowance ?? 0n) < total + fee) {
      const ok = await tx.send({ address: USDG.address, abi: erc20Abi, functionName: "approve", args: [addresses.scheduled, maxUint256] }, "Approve");
      if (!ok) return;
      await refetch();
    }
    const interval = BigInt(cadence === "weekly" ? 7 * 86400 : 30 * 86400);
    const r = await tx.send(
      {
        address: addresses.scheduled,
        abi: scheduledGiftsAbi,
        functionName: "createSchedule",
        args: [
          {
            recipient: recipient as Address,
            token: USDG.address,
            targetToken: target,
            amountPerRelease: per,
            releases,
            interval,
            firstReleaseAt: BigInt(Math.floor(Date.now() / 1000) + 60),
            maxSlippageBps: 300,
            message,
          },
        ],
      },
      "Create allowance",
    );
    if (r) load();
  }

  async function cancel(id: bigint) {
    const r = await tx.send({ address: addresses.scheduled, abi: scheduledGiftsAbi, functionName: "cancelSchedule", args: [id] }, "Cancel allowance");
    if (r) load();
  }
  async function takeCash(id: bigint) {
    const r = await tx.send({ address: addresses.scheduled, abi: scheduledGiftsAbi, functionName: "releaseAsDeposit", args: [id] }, "Release");
    if (r) load();
  }

  const now = BigInt(Math.floor(Date.now() / 1000));
  return (
    <div className="grid">
      <div className="card">
        <h1>Allowances</h1>
        <p className="muted">
          Pre-fund a weekly or monthly gift. Each installment is bought at the market price on release day and sent to the
          recipient&apos;s wallet. Cancel any time to get the unreleased amount back.
        </p>
        <div className="grid two">
          <div>
            <label>Recipient wallet</label>
            <input placeholder="0x…" value={recipient} onChange={(e) => setRecipient(e.target.value.trim())} />
          </div>
          <div>
            <label>Stock</label>
            <select value={target} onChange={(e) => setTarget(e.target.value as Address)}>
              {STOCKS.map((s) => (
                <option key={s.address} value={s.address}>
                  {s.symbol} — {s.name}
                </option>
              ))}
              <option value={zeroAddress}>Dollars (USDG)</option>
            </select>
          </div>
          <div>
            <label>Amount per installment (USDG)</label>
            <input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
          </div>
          <div>
            <label>Schedule</label>
            <div className="row">
              <select value={cadence} onChange={(e) => setCadence(e.target.value as "weekly" | "monthly")} style={{ flex: 1 }}>
                <option value="weekly">Every week</option>
                <option value="monthly">Every month (30 days)</option>
              </select>
              <select value={releases} onChange={(e) => setReleases(Number(e.target.value))} style={{ flex: 1 }}>
                {[4, 6, 12, 24, 52].map((n) => (
                  <option key={n} value={n}>
                    {n} times
                  </option>
                ))}
              </select>
            </div>
          </div>
        </div>
        <label>Message</label>
        <input maxLength={280} value={message} onChange={(e) => setMessage(e.target.value)} placeholder="A little something every month" />
        <p className="hint">
          Total funded now: {fmt(total, USDG.address)} + fee {fmt(fee, USDG.address)}
        </p>
        <button className="btn" disabled={!address || !isAddress(recipient) || per === 0n || tx.busy} onClick={create}>
          {address ? "Fund allowance" : "Connect a wallet"}
        </button>
        <Status status={tx.status} error={tx.error} />
      </div>

      <div className="card">
        <div className="spread">
          <h2 style={{ margin: 0 }}>Your allowances</h2>
          <button className="btn ghost small" onClick={() => load()}>
            Refresh
          </button>
        </div>
        {rows.length === 0 ? (
          <p className="muted">Nothing yet.</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>To / From</th>
                <th>Each</th>
                <th>Left</th>
                <th>Next</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => {
                const mine = r.sender.toLowerCase() === address?.toLowerCase();
                const due = r.active && r.nextReleaseAt <= now;
                return (
                  <tr key={r.id.toString()}>
                    <td>{r.id.toString()}</td>
                    <td className="mono small">{mine ? `→ ${r.recipient.slice(0, 10)}…` : `← ${r.sender.slice(0, 10)}…`}</td>
                    <td>
                      {fmt(r.amountPerRelease, r.token, 2)} → {r.targetToken === zeroAddress ? "USDG" : STOCKS.find((s) => s.address === r.targetToken)?.symbol}
                    </td>
                    <td>{r.active ? r.releasesLeft : "done"}</td>
                    <td>{r.active ? (due ? "due now" : new Date(Number(r.nextReleaseAt) * 1000).toLocaleDateString()) : "—"}</td>
                    <td>
                      {mine && r.active && (
                        <button className="btn ghost small" disabled={tx.busy} onClick={() => cancel(r.id)}>
                          Cancel
                        </button>
                      )}
                      {!mine && due && (
                        <button className="btn ghost small" disabled={tx.busy} onClick={() => takeCash(r.id)} title="Take this installment as dollars">
                          Take as USDG
                        </button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
        <p className="hint">Installments are released automatically by keepers when due.</p>
      </div>
    </div>
  );
}
