export const metadata = { title: "Risk disclosure - Stockgift" };

export default function Risk() {
  return (
    <article className="card prose" style={{ maxWidth: 820, margin: "0 auto" }}>
      <h1>Risk disclosure</h1>
      <p className="muted">Please read this before sending or claiming a gift. Last updated: October 2026.</p>

      <h2>What Stockgift is, and isn&apos;t</h2>
      <p>
        Stockgift is open-source, non-custodial smart-contract software. Gifts are held by audited-pattern smart
        contracts, not by a company. Stockgift is independent and is not affiliated with, endorsed by, or sponsored by
        any issuer of tokenized stocks, any broker, or the operator of the blockchain network it runs on. Nothing on this
        site is investment, tax or legal advice, or a recommendation to buy any security.
      </p>

      <h2>Tokenized stocks are not the same as shares</h2>
      <ul>
        <li>
          A stock token is issued by a third party and is designed to track the price of an underlying share. Holding one
          may not give you shareholder rights such as voting, and dividends or splits are reflected through the
          issuer&apos;s token mechanics rather than paid like a brokerage account.
        </li>
        <li>You rely on the issuer&apos;s solvency, custody of the underlying assets, and continued operation.</li>
        <li>
          Stock tokens and stablecoins may be unavailable, restricted, or illegal to hold in some jurisdictions. You are
          responsible for complying with the laws that apply to you.
        </li>
      </ul>

      <h2>Market risk</h2>
      <ul>
        <li>The value of a stock gift goes up and down. A gift can be worth less when it is claimed than when it was sent.</li>
        <li>
          When a gift is funded in dollars and converted at claim time, the number of shares received depends on the price
          at that moment. Conversions happen on decentralized exchanges and may receive a worse price than quoted, within
          the slippage limit the sender chose.
        </li>
        <li>
          Outside market hours, on weekends and holidays, prices can be stale or liquidity thin. Conversions may be
          blocked; you can always take the gift in the token it was funded with instead.
        </li>
      </ul>

      <h2>Smart-contract and technical risk</h2>
      <ul>
        <li>Smart contracts can contain bugs. Admin changes are delayed by a 48-hour timelock, and a guardian can pause the protocol in an emergency, which can temporarily stop claims and refunds.</li>
        <li>Price data comes from third-party oracles that can fail or be delayed; conversions halt when the data is stale.</li>
        <li>The blockchain network can experience downtime, congestion or reorganizations.</li>
      </ul>

      <h2>Claim links</h2>
      <ul>
        <li>A claim link works like cash: anyone who has it can claim the gift. Share it privately.</li>
        <li>If a link leaks, the sender can cancel an unclaimed gift and send a new one.</li>
        <li>Unclaimed gifts return to the sender after the expiry date. Gift cards (NFTs) belong to whoever holds the card.</li>
        <li>Lost wallets cannot be recovered by Stockgift. Keep your wallet backup safe.</li>
      </ul>

      <h2>Fees</h2>
      <p>
        A protocol fee (currently 0.5%, capped at 2% in the contracts) is deducted when a gift is funded. If you claim
        without paying gas, a small network fee is deducted from the gift for the relayer, capped on-chain.
      </p>

      <h2>No guarantees</h2>
      <p>
        The software is provided &ldquo;as is&rdquo;, without warranty of any kind. By using it you accept these risks.
      </p>
    </article>
  );
}
