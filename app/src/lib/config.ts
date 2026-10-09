import { defineChain, getAddress, zeroAddress, type Address } from "viem";
import { ROBINHOOD_MAINNET, robinhoodChain, type StockToken } from "@stockgift/config";
import deployment from "@/config/generated/deployment.json";

/** Chain definition; RPC can be overridden (e.g. http://127.0.0.1:8545 for a local anvil fork). */
export const chain = defineChain({
  ...robinhoodChain,
  rpcUrls: { default: { http: [process.env.NEXT_PUBLIC_RPC_URL || robinhoodChain.rpcUrls.default.http[0]] } },
});

type Deployment = typeof deployment & { deployedAtBlock?: number };
const d = deployment as Deployment;

export const addresses = {
  vault: getAddress(d.GiftVault),
  cardNFT: getAddress(d.GiftCardNFT),
  scheduled: getAddress(d.ScheduledGifts),
  groupPot: getAddress(d.GroupPot),
  feeCollector: getAddress(d.FeeCollector),
  hooks: getAddress(d.ProjectTokenHooks),
  forwarder: getAddress(d.TrustedForwarder),
  oracle: getAddress(d.OracleAdapter),
  usdg: getAddress(d.usdg),
  quoterV2: getAddress(d.quoterV2),
} as const;

export const deployedAtBlock = BigInt(d.deployedAtBlock ?? 0);
export const isDeployed = addresses.vault !== zeroAddress;

export const USDG = { symbol: "USDG", name: "Global Dollar", address: addresses.usdg, decimals: 6 } as const;

/** Curated stocks enabled by the deployment (falls back to the full researched list before deploy). */
const enabled = new Set((d.stockTokens as string[]).map((a) => a.toLowerCase()));
export const STOCKS: StockToken[] = ROBINHOOD_MAINNET.stocks.filter(
  (s) => enabled.size === 0 || enabled.has(s.address.toLowerCase()),
);

export function tokenMeta(address?: string) {
  if (!address) return undefined;
  const a = address.toLowerCase();
  if (a === USDG.address.toLowerCase()) return { symbol: USDG.symbol, decimals: USDG.decimals, name: USDG.name };
  const s = ROBINHOOD_MAINNET.stocks.find((x) => x.address.toLowerCase() === a);
  return s ? { symbol: s.symbol, decimals: s.decimals, name: s.name, poolFee: s.poolFee } : undefined;
}

export const appUrl = process.env.NEXT_PUBLIC_APP_URL || (typeof window !== "undefined" ? window.location.origin : "");
export const relayerUrl = process.env.NEXT_PUBLIC_RELAYER_URL || "";

/** $GIFT token address from env. Empty => every token feature is hidden. */
export const projectToken: Address | undefined = process.env.NEXT_PUBLIC_PROJECT_TOKEN
  ? getAddress(process.env.NEXT_PUBLIC_PROJECT_TOKEN)
  : undefined;
export const tokenFeaturesEnabled = projectToken !== undefined;

export const devWalletAddress: Address | undefined = process.env.NEXT_PUBLIC_DEV_WALLET
  ? getAddress(process.env.NEXT_PUBLIC_DEV_WALLET)
  : undefined;

export const FIRST_PREMIUM_DESIGN = 4;
export const CARD_DESIGNS = [
  { id: 0, name: "Evergreen", from: "#0f5132", to: "#1fa463", fg: "#ffffff" },
  { id: 1, name: "Birthday", from: "#ff7a59", to: "#ffcf56", fg: "#1b1b1b" },
  { id: 2, name: "Classic", from: "#2b2d42", to: "#8d99ae", fg: "#ffffff" },
  { id: 3, name: "Celebration", from: "#3a0ca3", to: "#4cc9f0", fg: "#ffffff" },
  { id: 4, name: "Gold", from: "#111111", to: "#b8860b", fg: "#f5e6b3", premium: true },
  { id: 5, name: "Onyx", from: "#0b0c10", to: "#45a29e", fg: "#c5c6c7", premium: true },
  { id: 6, name: "Platinum", from: "#e0e0e0", to: "#ffffff", fg: "#222222", premium: true },
  { id: 7, name: "Ruby", from: "#590d22", to: "#c9184a", fg: "#fff0f3", premium: true },
] as const;
