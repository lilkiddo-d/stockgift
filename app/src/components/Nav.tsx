"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useAccount, useConnect } from "wagmi";
import { devWalletAddress, tokenFeaturesEnabled } from "@/lib/config";

const links = [
  { href: "/create", label: "Send a gift" },
  { href: "/scheduled", label: "Allowances" },
  { href: "/pot/new", label: "Group gift" },
  ...(tokenFeaturesEnabled ? [{ href: "/stake", label: "$GIFT" }] : []),
];

export function Nav() {
  const path = usePathname();
  const { isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const dev = connectors.find((c) => c.type === "mock");
  return (
    <header className="nav">
      <div className="container navInner">
        <Link href="/" className="brand">
          <span className="logo" aria-hidden>
            ▣
          </span>
          Stockgift
        </Link>
        <nav className="links">
          {links.map((l) => (
            <Link key={l.href} href={l.href} className={path?.startsWith(l.href) ? "active" : ""}>
              {l.label}
            </Link>
          ))}
        </nav>
        <div className="wallet">
          {devWalletAddress && dev && !isConnected && (
            <button className="btn ghost small" onClick={() => connect({ connector: dev })}>
              Dev wallet (fork)
            </button>
          )}
          <ConnectButton showBalance={false} chainStatus="icon" accountStatus="address" />
        </div>
      </div>
    </header>
  );
}
