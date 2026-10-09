import Link from "next/link";

export default function Blocked() {
  return (
    <div className="card narrow">
      <h1>Not available in your region</h1>
      <p className="muted">
        Stockgift is not offered in your jurisdiction. Gifts you have already received remain claimable directly on-chain.
      </p>
      <Link href="/risk">Read the risk disclosure</Link>
    </div>
  );
}
