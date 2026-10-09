"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { decodeEventLog, zeroAddress, type Address } from "viem";
import { groupPotAbi } from "@/config/generated/abis";
import { addresses, appUrl, STOCKS, USDG } from "@/lib/config";
import { buildClaimLink, newClaimKey } from "@/lib/gift";
import { Status, useTx } from "@/components/ui";
import { ShareLink } from "@/components/ShareLink";

export default function NewPot() {
  const { address } = useAccount();
  const tx = useTx();
  const [title, setTitle] = useState("");
  const [target, setTarget] = useState<Address>(STOCKS[0]?.address ?? zeroAddress);
  const [choose, setChoose] = useState(false);
  const [days, setDays] = useState(14);
  const [created, setCreated] = useState<{ id: bigint; claimLink: string; potLink: string }>();

  async function create() {
    const key = newClaimKey();
    const r = await tx.send(
      {
        address: addresses.groupPot,
        abi: groupPotAbi,
        functionName: "createPot",
        args: [
          USDG.address,
          key.address,
          choose ? zeroAddress : target,
          choose,
          300,
          BigInt(Math.floor(Date.now() / 1000) + days * 86400),
          BigInt(90 * 86400),
          title,
        ],
      },
      "Create group gift",
    );
    if (!r) return;
    for (const log of r.logs) {
      try {
        const ev = decodeEventLog({ abi: groupPotAbi, data: log.data, topics: log.topics });
        if (ev.eventName === "PotCreated") {
          const base = appUrl || window.location.origin;
          const id = ev.args.potId;
          const claimLink = buildClaimLink(base, "p", id, key.pk);
          try {
            const saved = JSON.parse(localStorage.getItem("stockgift:pots") || "{}");
            saved[id.toString()] = claimLink;
            localStorage.setItem("stockgift:pots", JSON.stringify(saved));
          } catch {}
          setCreated({ id, claimLink, potLink: `${base}/pot/${id}` });
        }
      } catch {}
    }
  }

  if (created) {
    return (
      <div className="card narrow">
        <h1>Group gift #{created.id.toString()} created</h1>
        <ShareLink link={created.potLink} title="1. Share with friends so they can chip in" />
        <hr style={{ margin: "24px 0", border: 0, borderTop: "1px solid var(--line)" }} />
        <ShareLink link={created.claimLink} title="2. Keep private: give this to the recipient after you finalize" />
      </div>
    );
  }

  return (
    <div className="card narrow">
      <h1>Start a group gift</h1>
      <p className="muted">
        Friends chip in dollars; the recipient gets one link with everything, converted into stock when they claim.
      </p>
      <label>What is it for?</label>
      <input maxLength={280} value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Sam and Alex's wedding" />
      <label>Gift</label>
      <div className="segmented">
        <button className={!choose ? "on" : ""} onClick={() => setChoose(false)}>
          A stock we choose
        </button>
        <button className={choose ? "on" : ""} onClick={() => setChoose(true)}>
          They pick
        </button>
      </div>
      {!choose && (
        <div className="chips" style={{ marginTop: 10 }}>
          {STOCKS.map((s) => (
            <button key={s.address} className={`chip ${target === s.address ? "on" : ""}`} onClick={() => setTarget(s.address)}>
              {s.symbol}
            </button>
          ))}
        </div>
      )}
      <label>Contributions close in</label>
      <select value={days} onChange={(e) => setDays(Number(e.target.value))}>
        {[3, 7, 14, 30, 60].map((d) => (
          <option key={d} value={d}>
            {d} days
          </option>
        ))}
      </select>
      <button className="btn block" disabled={!address || !title || tx.busy} onClick={create}>
        {address ? "Create group gift" : "Connect a wallet"}
      </button>
      <Status status={tx.status} error={tx.error} />
    </div>
  );
}
