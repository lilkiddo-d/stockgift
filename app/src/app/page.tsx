import Link from "next/link";
import { CardPreview } from "@/components/ui";

export default function Home() {
  return (
    <>
      <section className="hero">
        <div>
          <h1>Give a piece of the companies they love.</h1>
          <p>
            Send tokenized stocks by link, QR code or wallet address. The recipient doesn&apos;t need a wallet or gas to
            start — they open the link, pick where to receive it, and claim.
          </p>
          <div className="row" style={{ marginTop: 20 }}>
            <Link className="btn" href="/create">
              Send a gift
            </Link>
            <Link className="btn ghost" href="/pot/new">
              Start a group gift
            </Link>
          </div>
          <p className="small muted" style={{ marginTop: 16 }}>
            Tokenized stocks carry market risk and may not be available everywhere.{" "}
            <Link href="/risk">Read the risk disclosure.</Link>
          </p>
        </div>
        <CardPreview design={1} ticker="NVDA" amount="$50.00 of stock" message={"Happy birthday!\nYour first share of the future."} />
      </section>

      <section className="grid three" style={{ marginTop: 40 }}>
        <div className="card">
          <h3>Link &amp; QR gifts</h3>
          <p className="muted small">
            Deposit stablecoin or stock tokens. The link carries a one-time secret; the claim is bound to the
            recipient&apos;s address so nobody can intercept it on-chain.
          </p>
        </div>
        <div className="card">
          <h3>Cash that becomes stock</h3>
          <p className="muted small">
            Gift dollars that convert into the stock you chose at claim time — or let the recipient pick from a curated
            list. Swaps are bounded by an oracle price check.
          </p>
        </div>
        <div className="card">
          <h3>Allowances</h3>
          <p className="muted small">
            &ldquo;$20 of a stock every month for a year&rdquo;: pre-funded, released on schedule by keepers.
          </p>
        </div>
        <div className="card">
          <h3>Group gifts</h3>
          <p className="muted small">Friends chip into one pot for a birthday or wedding; the recipient gets one link.</p>
        </div>
        <div className="card">
          <h3>Gift cards as NFTs</h3>
          <p className="muted small">An on-chain card with artwork holds the gift. Burning it claims the stock.</p>
        </div>
        <div className="card">
          <h3>Unclaimed? It comes back</h3>
          <p className="muted small">Every gift has an expiry. Unclaimed gifts return to the sender automatically.</p>
        </div>
      </section>

      <section className="card" style={{ marginTop: 24 }}>
        <h2 style={{ marginTop: 0 }}>How it works</h2>
        <ol className="steps">
          <li>Choose an amount, a stock (or let them choose), a message and a card design.</li>
          <li>Approve and fund the gift. Your browser creates a one-time claim key; only its fingerprint goes on-chain.</li>
          <li>Share the link or QR code. Keep it private — anyone with the link can claim.</li>
          <li>The recipient opens it, connects or creates a wallet, and claims — gas can be covered from a small fee in the gift.</li>
        </ol>
      </section>
    </>
  );
}
