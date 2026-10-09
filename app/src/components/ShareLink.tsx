"use client";

import { useState } from "react";
import { QRCodeSVG } from "qrcode.react";

export function ShareLink({ link, title = "Claim link" }: { link: string; title?: string }) {
  const [copied, setCopied] = useState(false);
  const canShare = typeof navigator !== "undefined" && "share" in navigator;
  return (
    <div>
      <label>{title}</label>
      <div className="mono small card" style={{ padding: 12 }}>
        {link}
      </div>
      <div className="row" style={{ marginTop: 12 }}>
        <button
          className="btn small"
          onClick={async () => {
            await navigator.clipboard.writeText(link);
            setCopied(true);
            setTimeout(() => setCopied(false), 1500);
          }}
        >
          {copied ? "Copied" : "Copy link"}
        </button>
        {canShare && (
          <button className="btn ghost small" onClick={() => navigator.share({ title: "A gift for you", url: link }).catch(() => {})}>
            Share…
          </button>
        )}
      </div>
      <div style={{ marginTop: 16 }} className="qr">
        <QRCodeSVG value={link} size={196} level="M" />
      </div>
      <p className="notice small" style={{ marginTop: 12 }}>
        Treat this link like cash: anyone who has it can claim the gift. It is stored only in this browser — nothing
        secret was sent to a server.
      </p>
    </div>
  );
}
