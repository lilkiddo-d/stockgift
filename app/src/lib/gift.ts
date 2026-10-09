import {
  encodePacked,
  formatUnits,
  parseUnits,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { addresses, chain, deployedAtBlock, tokenMeta } from "./config";
import { giftVaultAbi } from "@/config/generated/abis";

export type ClaimParams = {
  recipient: Address;
  tokenOut: Address;
  minAmountOut: bigint;
  relayer: Address;
  relayerFee: bigint;
  deadline: bigint;
};

/**
 * A claim link carries a fresh one-time key in the URL *fragment* (#...), which browsers never send
 * to servers. The vault stores only the key's address.
 */
export function newClaimKey() {
  const pk = generatePrivateKey();
  return { pk, address: privateKeyToAccount(pk).address };
}

export function buildClaimLink(base: string, kind: "g" | "p", id: bigint | number, pk: Hex) {
  return `${base}/claim#${kind}=${id.toString()}&k=${pk.slice(2)}`;
}

export function parseClaimFragment(hash: string): { kind: "g" | "p"; id: bigint; pk: Hex } | undefined {
  const params = new URLSearchParams(hash.replace(/^#/, ""));
  const k = params.get("k");
  const g = params.get("g");
  const p = params.get("p");
  if (!k || !/^[0-9a-fA-F]{64}$/.test(k)) return undefined;
  if (g && /^\d+$/.test(g)) return { kind: "g", id: BigInt(g), pk: `0x${k}` };
  if (p && /^\d+$/.test(p)) return { kind: "p", id: BigInt(p), pk: `0x${k}` };
  return undefined;
}

export const claimTypes = {
  Claim: [
    { name: "giftId", type: "uint256" },
    { name: "recipient", type: "address" },
    { name: "tokenOut", type: "address" },
    { name: "minAmountOut", type: "uint256" },
    { name: "relayer", type: "address" },
    { name: "relayerFee", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export async function signClaim(pk: Hex, giftId: bigint, c: ClaimParams): Promise<Hex> {
  const account = privateKeyToAccount(pk);
  return account.signTypedData({
    domain: { name: "Stockgift", version: "1", chainId: chain.id, verifyingContract: addresses.vault },
    types: claimTypes,
    primaryType: "Claim",
    message: { giftId, ...c },
  });
}

export function fmt(amount: bigint | undefined, token?: string, maxFrac = 4) {
  if (amount === undefined) return "-";
  const m = tokenMeta(token);
  const s = formatUnits(amount, m?.decimals ?? 18);
  const [w, f = ""] = s.split(".");
  const frac = f.slice(0, maxFrac).replace(/0+$/, "");
  return `${Number(w).toLocaleString()}${frac ? "." + frac : ""}${m ? " " + m.symbol : ""}`;
}

export function parseAmount(v: string, token: string) {
  return parseUnits(v || "0", tokenMeta(token)?.decimals ?? 18);
}

const quoterAbi = [
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

/** Live Uniswap quote for tokenIn -> tokenOut through the USDG pool (simulated via eth_call). */
export async function quoteSwap(client: PublicClient, tokenIn: Address, tokenOut: Address, amountIn: bigint) {
  if (tokenIn.toLowerCase() === tokenOut.toLowerCase()) return amountIn;
  const usdg = addresses.usdg;
  const feeOf = (t: Address) => tokenMeta(t)?.poolFee ?? 3000;
  let path: Hex;
  if (tokenIn.toLowerCase() === usdg.toLowerCase()) {
    path = encodePacked(["address", "uint24", "address"], [tokenIn, feeOf(tokenOut), tokenOut]);
  } else if (tokenOut.toLowerCase() === usdg.toLowerCase()) {
    path = encodePacked(["address", "uint24", "address"], [tokenIn, feeOf(tokenIn), tokenOut]);
  } else {
    path = encodePacked(
      ["address", "uint24", "address", "uint24", "address"],
      [tokenIn, feeOf(tokenIn), usdg, feeOf(tokenOut), tokenOut],
    );
  }
  const { result } = await client.simulateContract({
    address: addresses.quoterV2,
    abi: quoterAbi,
    functionName: "quoteExactInput",
    args: [path, amountIn],
  });
  return result[0];
}

/** Message + creation details from the GiftCreated event (messages are kept in logs, not storage). */
export async function fetchGiftCreated(client: PublicClient, giftId: bigint) {
  const logs = await client.getContractEvents({
    address: addresses.vault,
    abi: giftVaultAbi,
    eventName: "GiftCreated",
    args: { giftId },
    fromBlock: deployedAtBlock,
  });
  return logs[0]?.args;
}
