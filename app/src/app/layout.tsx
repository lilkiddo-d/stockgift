import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";
import { Providers } from "./providers";
import { Nav } from "@/components/Nav";

export const metadata: Metadata = {
  title: "Stockgift - send stocks by link",
  description: "Gift tokenized stocks by link, QR code or wallet address. Scheduled allowances, group gifts and NFT gift cards.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Nav />
          <main className="container">{children}</main>
          <footer className="footer container">
            <span>Stockgift is an independent, non-custodial protocol. Not investment advice.</span>
            <Link href="/risk">Risk disclosure</Link>
          </footer>
        </Providers>
      </body>
    </html>
  );
}
