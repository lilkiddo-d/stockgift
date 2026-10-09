/**
 * Stockgift gasless-claim relayer (minimal HTTP service).
 *
 *   GET  /health                  -> { relayer, chainId }
 *   GET  /quote?giftId=N          -> { relayer, fee }  fee in the gift's deposit token (base units)
 *   POST /relay/claim             { giftId, claim, signature }      -> vault.claim(...)   (link / wallet gifts)
 *   POST /relay/forward           { request: ForwardRequestData }   -> forwarder.execute  (ERC-2771: claimDirect / card redeem)
 *
 * The relayer pays gas and is repaid from the gift through the `relayerFee` field, which the claimant
 * signs (EIP-712 claim or ERC-2771 ForwardRequest), so a relayer cannot raise its own fee. The vault
 * also caps the fee on-chain (maxRelayerFeeBps).
 *
 * Abuse controls: only our own address as relayer, minimum fee, target/selector allowlist, gas cap,
 * pre-flight simulation (no gas burned on reverts), per-IP rate limit, per-gift in-flight lock, and a
 * global hourly tx budget.
 *
 * Env: RPC_URL, PORT=8787, ALLOWED_ORIGIN=*, RELAYER_FEE_USD=0.10, MAX_TX_PER_HOUR=300,
 *      DEPLOYMENT_NAME | DEPLOYMENT_FILE, KEEPER_PASSWORD_FILE (or KEEPER_UNLOCKED_ADDRESS on a fork)
 */
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { decodeFunctionData, getAddress, type Address, type Hex } from "viem";
import { giftCardNFTAbi, giftVaultAbi, oracleAdapterAbi, trustedForwarderAbi } from "./generated/abis.js";
import { addressOf, loadDeployment, log, publicClient, signer } from "./lib.js";

const d = loadDeployment();
const client = publicClient();
const PORT = Number(process.env.PORT || 8787);
const ORIGIN = process.env.ALLOWED_ORIGIN || "*";
const FEE_USD_E18 = BigInt(Math.round(Number(process.env.RELAYER_FEE_USD || "0.10") * 1e6)) * 10n ** 12n;
const MAX_TX_PER_HOUR = Number(process.env.MAX_TX_PER_HOUR || 300);
const MAX_GAS = 900_000n;

const { wallet, account } = await signer();
const me = addressOf(account);

// ----------------------------------------------------------------- limits
const ipHits = new Map<string, number[]>();
function rateLimited(ip: string, limit = 10, windowMs = 60_000) {
  const now = Date.now();
  const hits = (ipHits.get(ip) || []).filter((t) => now - t < windowMs);
  hits.push(now);
  ipHits.set(ip, hits);
  return hits.length > limit;
}
const sent: number[] = [];
function budgetExceeded() {
  const now = Date.now();
  while (sent.length && now - sent[0] > 3_600_000) sent.shift();
  return sent.length >= MAX_TX_PER_HOUR;
}
const inFlight = new Set<string>();

// ------------------------------------------------------------------ fees
async function quoteFee(giftId: bigint) {
  const g = await client.readContract({ address: d.GiftVault, abi: giftVaultAbi, functionName: "getGift", args: [giftId] });
  if (g.status !== 1) throw new HttpError(404, "gift is not open");
  const [capBps, oracle] = await Promise.all([
    client.readContract({ address: d.GiftVault, abi: giftVaultAbi, functionName: "maxRelayerFeeBps" }),
    client.readContract({ address: d.GiftVault, abi: giftVaultAbi, functionName: "oracle" }),
  ]);
  const price = await client.readContract({ address: oracle as Address, abi: oracleAdapterAbi, functionName: "getPrice", args: [g.token] });
  const decimals = (await client.readContract({
    address: g.token,
    abi: [{ type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] }] as const,
    functionName: "decimals",
  })) as number;
  const fee = (FEE_USD_E18 * 10n ** BigInt(decimals)) / price;
  const cap = (g.amount * BigInt(capBps)) / 10_000n;
  return { fee: fee < cap ? fee : cap, gift: g };
}

class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

type ClaimJson = { recipient: string; tokenOut: string; minAmountOut: string; relayer: string; relayerFee: string; deadline: string };
const toClaim = (c: ClaimJson) => ({
  recipient: getAddress(c.recipient),
  tokenOut: getAddress(c.tokenOut),
  minAmountOut: BigInt(c.minAmountOut),
  relayer: getAddress(c.relayer),
  relayerFee: BigInt(c.relayerFee),
  deadline: BigInt(c.deadline),
});

async function checkFee(giftId: bigint, relayer: Address, relayerFee: bigint) {
  if (relayer !== me) throw new HttpError(400, "relayer field must be this relayer");
  const { fee } = await quoteFee(giftId);
  if (relayerFee * 10n < fee * 9n) throw new HttpError(400, `relayer fee too low (min ${fee})`);
}

async function send(request: Parameters<typeof wallet.writeContract>[0]) {
  if (budgetExceeded()) throw new HttpError(503, "relayer busy, try again later");
  const hash = await wallet.writeContract(request);
  sent.push(Date.now());
  return hash;
}

// --------------------------------------------------------------- handlers
async function relayClaim(body: { giftId: string; claim: ClaimJson; signature: Hex }) {
  const giftId = BigInt(body.giftId);
  const c = toClaim(body.claim);
  await checkFee(giftId, c.relayer, c.relayerFee);
  const key = `gift:${giftId}`;
  if (inFlight.has(key)) throw new HttpError(409, "claim already in flight");
  inFlight.add(key);
  try {
    const { request } = await client.simulateContract({
      account: me,
      address: d.GiftVault,
      abi: giftVaultAbi,
      functionName: "claim",
      args: [giftId, c, body.signature],
    });
    const hash = await send({ ...request, account: wallet.account ?? me, chain: wallet.chain } as never);
    log(`relayed claim gift=${giftId} -> ${c.recipient} tx=${hash}`);
    return { txHash: hash };
  } finally {
    setTimeout(() => inFlight.delete(key), 30_000);
  }
}

type ForwardJson = { from: string; to: string; value: string; gas: string; deadline: string; data: Hex; signature: Hex };
async function relayForward(body: { request: ForwardJson }) {
  const r = body.request;
  const req = {
    from: getAddress(r.from),
    to: getAddress(r.to),
    value: BigInt(r.value),
    gas: BigInt(r.gas),
    deadline: Number(r.deadline),
    data: r.data,
    signature: r.signature,
  };
  if (req.value !== 0n || req.gas > MAX_GAS) throw new HttpError(400, "bad value/gas");
  let giftId: bigint;
  let claim: ReturnType<typeof toClaim>;
  if (req.to === getAddress(d.GiftVault)) {
    const f = decodeFunctionData({ abi: giftVaultAbi, data: req.data });
    if (f.functionName !== "claimDirect") throw new HttpError(400, "function not allowed");
    giftId = f.args[0] as bigint;
    claim = f.args[1] as never;
  } else if (req.to === getAddress(d.GiftCardNFT)) {
    const f = decodeFunctionData({ abi: giftCardNFTAbi, data: req.data });
    if (f.functionName !== "redeem") throw new HttpError(400, "function not allowed");
    giftId = f.args[0] as bigint;
    claim = f.args[1] as never;
  } else throw new HttpError(400, "target not allowed");
  await checkFee(giftId, claim.relayer, claim.relayerFee);
  const ok = await client.readContract({ address: d.TrustedForwarder, abi: trustedForwarderAbi, functionName: "verify", args: [req] });
  if (!ok) throw new HttpError(400, "invalid forward request");
  const { request } = await client.simulateContract({
    account: me,
    address: d.TrustedForwarder,
    abi: trustedForwarderAbi,
    functionName: "execute",
    args: [req],
  });
  const hash = await send({ ...request, account: wallet.account ?? me, chain: wallet.chain } as never);
  log(`relayed forward ${req.from} -> ${req.to} gift=${giftId} tx=${hash}`);
  return { txHash: hash };
}

// ------------------------------------------------------------------ server
function json(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, {
    "content-type": "application/json",
    "access-control-allow-origin": ORIGIN,
    "access-control-allow-headers": "content-type",
    "access-control-allow-methods": "GET,POST,OPTIONS",
  });
  res.end(JSON.stringify(body, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
}

async function readBody(req: IncomingMessage) {
  let raw = "";
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > 20_000) throw new HttpError(413, "body too large");
  }
  return JSON.parse(raw || "{}");
}

createServer(async (req, res) => {
  const ip = (req.headers["x-forwarded-for"] as string)?.split(",")[0] || req.socket.remoteAddress || "?";
  try {
    if (req.method === "OPTIONS") return json(res, 204, {});
    const url = new URL(req.url || "/", "http://x");
    if (req.method === "GET" && url.pathname === "/health") return json(res, 200, { relayer: me, chainId: d.chainId });
    if (rateLimited(ip)) throw new HttpError(429, "too many requests");
    if (req.method === "GET" && url.pathname === "/quote") {
      const id = url.searchParams.get("giftId");
      if (!id || !/^\d+$/.test(id)) throw new HttpError(400, "giftId required");
      const { fee } = await quoteFee(BigInt(id));
      return json(res, 200, { relayer: me, fee: fee.toString() });
    }
    if (req.method === "POST" && url.pathname === "/relay/claim") return json(res, 200, await relayClaim(await readBody(req)));
    if (req.method === "POST" && url.pathname === "/relay/forward") return json(res, 200, await relayForward(await readBody(req)));
    throw new HttpError(404, "not found");
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 400;
    const msg = (e as Error).message?.split("\n")[0] ?? "error";
    if (!(e instanceof HttpError)) log(`request failed (${ip}):`, msg);
    json(res, status, { error: msg });
  }
}).listen(PORT, () => log(`relayer ${me} listening on :${PORT} (chain ${d.chainId})`));
