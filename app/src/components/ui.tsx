"use client";

import { useState } from "react";
import { usePublicClient, useWriteContract } from "wagmi";
import { BaseError, type TransactionReceipt } from "viem";
import { CARD_DESIGNS } from "@/lib/config";

export function errMsg(e: unknown): string {
  if (e instanceof BaseError) return e.shortMessage || e.message;
  if (e instanceof Error) return e.message;
  return String(e);
}

/** writeContract + wait for receipt, with status text for the UI. */
export function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const [status, setStatus] = useState<string>("");
  const [error, setError] = useState<string>("");
  const [busy, setBusy] = useState(false);

  async function send(args: Parameters<typeof writeContractAsync>[0], label: string): Promise<TransactionReceipt | undefined> {
    setError("");
    setBusy(true);
    try {
      setStatus(`${label}: confirm in your wallet…`);
      const hash = await writeContractAsync(args);
      setStatus(`${label}: waiting for confirmation…`);
      const receipt = await client!.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error(`${label} reverted`);
      setStatus(`${label}: done`);
      return receipt;
    } catch (e) {
      setError(errMsg(e));
      setStatus("");
      return undefined;
    } finally {
      setBusy(false);
    }
  }
  return { send, status, error, busy, setError };
}

export function Status({ status, error }: { status?: string; error?: string }) {
  if (error) return <div className="notice error" style={{ marginTop: 12 }}>{error}</div>;
  if (status) return <div className="notice" style={{ marginTop: 12 }}>{status}</div>;
  return null;
}

export function CardPreview({
  design,
  ticker,
  amount,
  message,
}: {
  design: number;
  ticker: string;
  amount: string;
  message: string;
}) {
  const d = CARD_DESIGNS[design] ?? CARD_DESIGNS[0];
  return (
    <div className="giftcard" style={{ background: `linear-gradient(135deg, ${d.from}, ${d.to})`, color: d.fg }}>
      <div className="spread">
        <strong>STOCKGIFT</strong>
        <span className="small">{d.name}</span>
      </div>
      <div>
        <div className="big">{ticker || "—"}</div>
        <div>{amount}</div>
      </div>
      <div style={{ whiteSpace: "pre-wrap", fontSize: "0.9rem", opacity: 0.95 }}>{message}</div>
    </div>
  );
}
