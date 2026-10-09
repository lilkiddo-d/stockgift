import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import {
  coinbaseWallet,
  injectedWallet,
  metaMaskWallet,
  rainbowWallet,
  walletConnectWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { createConfig, http } from "wagmi";
import { mock } from "wagmi/connectors";
import { chain, devWalletAddress } from "./config";

const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID || "stockgift-dev";

const walletGroups = [
  {
    groupName: "New to crypto",
    // Coinbase Smart Wallet: passkey wallet created in-browser, no extension or seed phrase needed
    wallets: [coinbaseWallet],
  },
  {
    groupName: "Wallets",
    wallets: process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID
      ? [metaMaskWallet, rainbowWallet, walletConnectWallet, injectedWallet]
      : [metaMaskWallet, injectedWallet],
  },
];

const rkConnectors = connectorsForWallets(walletGroups, { appName: "Stockgift", projectId });

/**
 * Local-fork only: an impersonating connector that sends eth_sendTransaction as
 * NEXT_PUBLIC_DEV_WALLET to an `anvil --auto-impersonate` node. Never enabled in production builds
 * unless that env var is set explicitly.
 */
const devConnectors = devWalletAddress
  ? [mock({ accounts: [devWalletAddress], features: { defaultConnected: false, reconnect: true } })]
  : [];

export const wagmiConfig = createConfig({
  chains: [chain],
  connectors: [...rkConnectors, ...devConnectors],
  transports: { [chain.id]: http(chain.rpcUrls.default.http[0]) },
  ssr: true,
});
