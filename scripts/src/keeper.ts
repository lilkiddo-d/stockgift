/**
 * Stockgift keeper
 *  - releases due ScheduledGifts installments (buying the stock with a QuoterV2-derived min output;
 *    the contract additionally enforces its oracle floor)
 *  - refunds expired, unclaimed gifts to their senders
 *  - syncs GroupPot refunds so contributors can withdraw
 *
 * Usage:  pnpm keeper            (loop)
 *         pnpm keeper --once     (single pass, e.g. from cron)
 * Env:    RPC_URL, DEPLOYMENT_NAME | DEPLOYMENT_FILE, KEEPER_PASSWORD_FILE (or KEEPER_UNLOCKED_ADDRESS on a fork),
 *         POLL_SECONDS=60, KEEPER_SLIPPAGE_BPS=100, LOG_CHUNK=50000, REFUND_EXPIRED=true
 */
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { type Address, type Hex } from "viem";
import { giftVaultAbi, groupPotAbi, scheduledGiftsAbi } from "./generated/abis.js";
import { addressOf, chunkedLogs, loadDeployment, log, publicClient, quoterAbi, signer } from "./lib.js";

const dexAbi = [
  { type: "function", name: "getRoute", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "bytes" }] },
] as const;

const d = loadDeployment();
const client = publicClient();
const once = process.argv.includes("--once");
const POLL = Number(process.env.POLL_SECONDS || 60) * 1000;
const SLIPPAGE = BigInt(process.env.KEEPER_SLIPPAGE_BPS || 100);
const CHUNK = BigInt(process.env.LOG_CHUNK || 50_000);
const REFUND = (process.env.REFUND_EXPIRED || "true") !== "false";
const statePath = join(dirname(fileURLToPath(import.meta.url)), "..", ".keeper-state.json");

type State = { cursor: string; schedules: string[]; gifts: Record<string, number>; pots: string[] };
let state: State = existsSync(statePath)
  ? JSON.parse(readFileSync(statePath, "utf8"))
  : { cursor: String(d.deployedAtBlock), schedules: [], gifts: {}, pots: [] };
const save = () => writeFileSync(statePath, JSON.stringify(state, null, 2));

async function scan() {
  const head = await client.getBlockNumber();
  const from = BigInt(state.cursor);
  if (from > head) return;
  const [sched, gifts, pots] = await Promise.all([
    chunkedLogs(from, head, CHUNK, (a, b) =>
      client.getContractEvents({ address: d.ScheduledGifts, abi: scheduledGiftsAbi, eventName: "ScheduleCreated", fromBlock: a, toBlock: b }),
    ),
    chunkedLogs(from, head, CHUNK, (a, b) =>
      client.getContractEvents({ address: d.GiftVault, abi: giftVaultAbi, eventName: "GiftCreated", fromBlock: a, toBlock: b }),
    ),
    chunkedLogs(from, head, CHUNK, (a, b) =>
      client.getContractEvents({ address: d.GroupPot, abi: groupPotAbi, eventName: "PotFinalized", fromBlock: a, toBlock: b }),
    ),
  ]);
  for (const l of sched) state.schedules.push(l.args.scheduleId!.toString());
  for (const l of gifts) state.gifts[l.args.giftId!.toString()] = Number(l.args.expiry);
  for (const l of pots) state.pots.push(l.args.potId!.toString());
  state.schedules = [...new Set(state.schedules)];
  state.pots = [...new Set(state.pots)];
  state.cursor = String(head + 1n);
  save();
}

async function minOutFor(tokenIn: Address, tokenOut: Address, amountIn: bigint): Promise<bigint> {
  if (tokenIn.toLowerCase() === tokenOut.toLowerCase()) return 0n;
  const dex = (await client.readContract({ address: d.GiftVault, abi: giftVaultAbi, functionName: "dex" })) as Address;
  const path = (await client.readContract({ address: dex, abi: dexAbi, functionName: "getRoute", args: [tokenIn, tokenOut] })) as Hex;
  const { result } = await client.simulateContract({ address: d.quoterV2, abi: quoterAbi, functionName: "quoteExactInput", args: [path, amountIn] });
  return (result[0] * (10_000n - SLIPPAGE)) / 10_000n;
}

async function pass() {
  await scan();
  const { wallet, account } = await signer();
  const from = addressOf(account);
  const now = BigInt(Math.floor(Date.now() / 1000));
  const block = await client.getBlock();
  const chainNow = block.timestamp > now ? block.timestamp : now;

  // 1. scheduled installments
  for (const idStr of state.schedules) {
    const id = BigInt(idStr);
    try {
      const s = await client.readContract({ address: d.ScheduledGifts, abi: scheduledGiftsAbi, functionName: "getSchedule", args: [id] });
      if (!s.active) {
        state.schedules = state.schedules.filter((x) => x !== idStr);
        continue;
      }
      if (s.nextReleaseAt > block.timestamp) continue;
      const tokenOut = s.targetToken === "0x0000000000000000000000000000000000000000" ? s.token : s.targetToken;
      const minOut = await minOutFor(s.token, tokenOut, BigInt(s.amountPerRelease));
      const { request } = await client.simulateContract({
        account: from,
        address: d.ScheduledGifts,
        abi: scheduledGiftsAbi,
        functionName: "release",
        args: [id, minOut, chainNow + 600n],
      });
      const hash = await wallet.writeContract({ ...request, account: wallet.account ?? from, chain: wallet.chain });
      await client.waitForTransactionReceipt({ hash });
      log(`released schedule ${id} (minOut ${minOut}) tx ${hash}`);
    } catch (e) {
      log(`schedule ${id}: skipped -`, (e as Error).message.split("\n")[0]);
    }
  }

  // 2. expired gifts -> refund to sender
  if (REFUND) {
    for (const [idStr, expiry] of Object.entries(state.gifts)) {
      if (BigInt(expiry) >= block.timestamp) continue;
      const id = BigInt(idStr);
      try {
        const status = await client.readContract({ address: d.GiftVault, abi: giftVaultAbi, functionName: "giftStatus", args: [id] });
        if (status !== 1) {
          delete state.gifts[idStr];
          continue;
        }
        const { request } = await client.simulateContract({ account: from, address: d.GiftVault, abi: giftVaultAbi, functionName: "refund", args: [id] });
        const hash = await wallet.writeContract({ ...request, account: wallet.account ?? from, chain: wallet.chain });
        await client.waitForTransactionReceipt({ hash });
        delete state.gifts[idStr];
        log(`refunded expired gift ${id} tx ${hash}`);
      } catch (e) {
        log(`gift ${id}: refund skipped -`, (e as Error).message.split("\n")[0]);
      }
    }
  }

  // 3. pots whose gift was refunded -> let contributors withdraw
  for (const idStr of state.pots) {
    const id = BigInt(idStr);
    try {
      const p = await client.readContract({ address: d.GroupPot, abi: groupPotAbi, functionName: "getPot", args: [id] });
      if (p.status !== 2) {
        state.pots = state.pots.filter((x) => x !== idStr);
        continue;
      }
      const st = await client.readContract({ address: d.GiftVault, abi: giftVaultAbi, functionName: "giftStatus", args: [p.giftId] });
      if (st !== 3) continue;
      const { request } = await client.simulateContract({ account: from, address: d.GroupPot, abi: groupPotAbi, functionName: "syncRefund", args: [id] });
      const hash = await wallet.writeContract({ ...request, account: wallet.account ?? from, chain: wallet.chain });
      await client.waitForTransactionReceipt({ hash });
      log(`synced refund for pot ${id} tx ${hash}`);
    } catch (e) {
      log(`pot ${id}: skipped -`, (e as Error).message.split("\n")[0]);
    }
  }
  save();
}

async function main() {
  log(`keeper starting on chain ${d.chainId}, vault ${d.GiftVault}`);
  do {
    try {
      await pass();
    } catch (e) {
      log("pass failed:", (e as Error).message);
    }
    if (!once) await new Promise((r) => setTimeout(r, POLL));
  } while (!once);
}

main();
