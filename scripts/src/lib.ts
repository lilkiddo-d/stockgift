/**
 * Shared plumbing for the keeper and relayer.
 *
 * Signing: the services sign ONLY with the Foundry keystore account `stockgift-keeper`
 * (created by the operator with `cast wallet import stockgift-keeper --interactive`). The encrypted
 * keystore is decrypted in memory with the password read from KEEPER_PASSWORD_FILE. Nothing here
 * creates, prints or persists a private key.
 *
 * Local fork mode: set KEEPER_UNLOCKED_ADDRESS to an address on an `anvil --auto-impersonate` node;
 * transactions are then sent with eth_sendTransaction and no key is involved at all.
 */
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Wallet } from "ethers";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  getAddress,
  http,
  type Account,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { robinhoodChain } from "@stockgift/config";

export type Deployment = {
  chainId: number;
  deployedAtBlock: number;
  GiftVault: Address;
  GiftCardNFT: Address;
  ScheduledGifts: Address;
  GroupPot: Address;
  TrustedForwarder: Address;
  OracleAdapter: Address;
  usdg: Address;
  quoterV2: Address;
  stockTokens: Address[];
  stockPoolFees: number[];
};

const here = dirname(fileURLToPath(import.meta.url));

export function loadDeployment(): Deployment {
  const name = process.env.DEPLOYMENT_NAME || "4663";
  const path = process.env.DEPLOYMENT_FILE || join(here, "..", "..", "contracts", "deployments", `${name}.json`);
  return JSON.parse(readFileSync(path, "utf8"));
}

export const rpcUrl = process.env.RPC_URL || robinhoodChain.rpcUrls.default.http[0];
export const chain = defineChain({ ...robinhoodChain, rpcUrls: { default: { http: [rpcUrl] } } });

export function publicClient(): PublicClient {
  return createPublicClient({ chain, transport: http(rpcUrl, { retryCount: 3, timeout: 60_000 }) }) as PublicClient;
}

export async function signer(): Promise<{ wallet: WalletClient; account: Account | Address }> {
  const unlocked = process.env.KEEPER_UNLOCKED_ADDRESS;
  if (unlocked) {
    const address = getAddress(unlocked);
    return { wallet: createWalletClient({ chain, transport: http(rpcUrl), account: address }), account: address };
  }
  const name = process.env.KEEPER_ACCOUNT || "stockgift-keeper";
  const keystoreDir = process.env.FOUNDRY_KEYSTORE_DIR || join(homedir(), ".foundry", "keystores");
  const passwordFile = process.env.KEEPER_PASSWORD_FILE;
  if (!passwordFile) throw new Error("Set KEEPER_PASSWORD_FILE to a file containing the stockgift-keeper keystore password");
  const json = readFileSync(join(keystoreDir, name), "utf8");
  const password = readFileSync(passwordFile, "utf8").trim();
  const w = await Wallet.fromEncryptedJson(json, password);
  const account = privateKeyToAccount(w.privateKey as Hex);
  return { wallet: createWalletClient({ chain, transport: http(rpcUrl), account }), account };
}

export function addressOf(account: Account | Address): Address {
  return typeof account === "string" ? account : account.address;
}

export function log(...args: unknown[]) {
  console.log(new Date().toISOString(), ...args);
}

/** eth_getLogs in chunks (public RPCs cap the block range). */
export async function chunkedLogs<T>(
  from: bigint,
  to: bigint,
  step: bigint,
  fetch: (from: bigint, to: bigint) => Promise<T[]>,
): Promise<T[]> {
  const out: T[] = [];
  for (let start = from; start <= to; start += step) {
    const end = start + step - 1n > to ? to : start + step - 1n;
    out.push(...(await fetch(start, end)));
  }
  return out;
}

export const quoterAbi = [
  {
    type: "function",
    name: "quoteExactInput",
    stateMutability: "nonpayable",
    inputs: [
      { name: "path", type: "bytes" },
      { name: "amountIn", type: "uint256" },
    ],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "sqrtPriceX96AfterList", type: "uint160[]" },
      { name: "initializedTicksCrossedList", type: "uint32[]" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
] as const;
