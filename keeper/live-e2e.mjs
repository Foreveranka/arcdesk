// Live cross-chain settlement test against the DEPLOYED testnet escrows:
// Base Sepolia (payment) <-> Arc testnet (liquidity), driven by the real keeper.
// Reads addresses from ../.env and the deployer key from ../.deployer.json.
//
//   node live-e2e.mjs
//
// One wallet plays maker/taker/keeper (testnet), so success is judged by the two
// escrow balances draining and the Arc USDC landing on a separate recipient address.
import { ethers } from "ethers";
import { readFileSync } from "fs";
import { Keeper } from "./keeper.mjs";
import { ERC20_ABI, ESCROW_ABI } from "./abis.mjs";

const env = Object.fromEntries(
  readFileSync(new URL("../.env", import.meta.url), "utf8")
    .split("\n").filter((l) => l.includes("=") && !l.startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()])
);
const PK = JSON.parse(readFileSync(new URL("../.deployer.json", import.meta.url)))[0].private_key;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ok = (c, m) => { if (!c) throw new Error("ASSERT FAIL: " + m); console.log("  ok  " + m); };
// Public RPCs are load-balanced and often lag a block right after a tx lands, so every
// on-chain assertion polls until it holds instead of reading once.
const until = async (fn, m, tries = 30, waitMs = 2000) => {
  for (let i = 0; i < tries; i++) {
    const v = await fn();
    if (v) { console.log("  ok  " + m); return v; }
    await sleep(waitMs);
  }
  throw new Error("ASSERT FAIL (timeout): " + m);
};
const fmt6 = (v) => (Number(v) / 1e6).toFixed(2);

// A throwaway recipient for the Arc leg so the delivery is visible on a distinct address.
const RECIPIENT = "0x00000000000000000000000000000000000BEEF1";
const TREASURY = env.TREASURY;

async function main() {
  const src = new ethers.JsonRpcProvider(env.SOURCE_RPC);
  const arc = new ethers.JsonRpcProvider(env.ARC_RPC);
  src.pollingInterval = 2000;
  arc.pollingInterval = 2000;
  const wSrc = new ethers.Wallet(PK, src);
  const wArc = new ethers.Wallet(PK, arc);
  console.log("wallet:", wSrc.address);

  const baseUsdc = new ethers.Contract(env.SOURCE_USDC, ERC20_ABI, wSrc);
  const arcUsdc = new ethers.Contract(env.ARC_USDC, ERC20_ABI, wArc);
  const payEsc = new ethers.Contract(env.SOURCE_ESCROW, ESCROW_ABI, wSrc);
  const liqEsc = new ethers.Contract(env.ARC_ESCROW, ESCROW_ABI, wArc);

  console.log("base USDC:", fmt6(await baseUsdc.balanceOf(wSrc.address)));
  console.log("arc  USDC:", fmt6(await arcUsdc.balanceOf(wArc.address)));

  // Trade: buy 2 Arc USDC at 8% premium -> 2.16 proceeds, 2% desk fee -> 0.0432
  const ARC_AMT = 2_000000n;
  const PROCEEDS = 2_160000n;
  const FEE = 43200n;
  const salt = Date.now().toString();
  const offerId = ethers.id("live-offer-" + salt);
  const orderId = ethers.id("live-order-" + salt);
  const secret = ethers.id("live-secret-" + salt);
  const hashlock = ethers.keccak256(ethers.solidityPacked(["bytes32"], [secret]));
  const nowArc = (await arc.getBlock("latest")).timestamp;
  const offerExpiry = nowArc + 7200;
  const resvDeadline = nowArc + 7200; // maker commits long (> MIN_RESERVATION_WINDOW)
  const nowSrc = (await src.getBlock("latest")).timestamp;
  const payDeadline = nowSrc + 1200; // taker pays short (< MAX_PAYMENT_WINDOW)

  // A load-balanced RPC can serve a node that has not seen the approve yet, which makes
  // the next call's gas estimate revert on allowance. Wait until the allowance is visible.
  const awaitAllowance = async (token, spender, needed) => {
    for (let i = 0; i < 30; i++) {
      if ((await token.allowance(wSrc.address, spender)) >= needed) return;
      await sleep(2000);
    }
    throw new Error("allowance never became visible for " + spender);
  };

  // 1) maker posts a time-limited offer on Arc
  console.log("\n[1] maker posts offer on Arc (2 USDC, 8%, 1h)");
  await (await arcUsdc.approve(env.ARC_ESCROW, ARC_AMT)).wait();
  await awaitAllowance(arcUsdc, env.ARC_ESCROW, ARC_AMT);
  await (await liqEsc.postOffer(offerId, ARC_AMT, 800, offerExpiry)).wait();
  await until(async () => (await arcUsdc.balanceOf(env.ARC_ESCROW)) >= ARC_AMT,
    "arc escrow holds the offer");

  // 2) keeper starts watching both chains
  console.log("[2] keeper online");
  const keeper = new Keeper({
    paymentSigner: wSrc, offerSigner: wArc,
    paymentAddr: env.SOURCE_ESCROW, offerAddr: env.ARC_ESCROW,
  });
  // The desk is the maker here, so it holds the preimage and claims the payment itself.
  keeper.registerOrder(orderId, {
    offerId, recipient: RECIPIENT, amount: ARC_AMT, hashlock, resvDeadline, secret,
    payer: wSrc.address, maker: wSrc.address, proceeds: PROCEEDS.toString(), fee: FEE.toString(),
  });
  await keeper.start();

  // Maker commits first, before the taker sends any money.
  console.log("[2b] keeper reserves maker liquidity on Arc");
  await keeper.reserveForOrder(orderId);
  await until(async () => (await liqEsc.reservations(orderId)).status === 1n,
    "reservation live on Arc before the taker pays");

  // 3) taker locks payment on Base Sepolia
  console.log("[3] taker locks payment on Base Sepolia (2.2032 USDC)");
  await (await baseUsdc.approve(env.SOURCE_ESCROW, PROCEEDS + FEE)).wait();
  await awaitAllowance(baseUsdc, env.SOURCE_ESCROW, PROCEEDS + FEE);
  await (await payEsc.lockPayment(orderId, wSrc.address, TREASURY, PROCEEDS, FEE, hashlock, payDeadline)).wait();
  await until(async () => (await payEsc.paymentOf(orderId, wSrc.address)).status === 1n,
    "base escrow holds the payment (status Locked)");

  // 5) maker claims the payment, publishing the preimage
  console.log("[5] waiting for maker to claim the payment (reveals preimage)...");
  const before = await arcUsdc.balanceOf(RECIPIENT);
  await until(async () => (await payEsc.paymentOf(orderId, wSrc.address)).status === 2n,
    "maker claimed the payment on Base");

  // 6) keeper delivers on Arc for the taker, who never transacts there
  console.log("[6] waiting for keeper to deliver on Arc...");
  await until(async () => (await arcUsdc.balanceOf(RECIPIENT)) - before === ARC_AMT,
    `recipient received ${fmt6(ARC_AMT)} Arc USDC`);
  ok(await arc.getTransactionCount(RECIPIENT) === 0, "recipient sent zero Arc transactions");
  await until(async () => (await baseUsdc.balanceOf(TREASURY)) >= FEE,
    `desk fee landed in treasury (${fmt6(FEE)} USDC)`);

  await keeper.stop();
  console.log("\nLIVE E2E PASS: real cross-chain swap settled on Base Sepolia <-> Arc testnet.");
  process.exit(0);
}

main().catch((e) => { console.error("LIVE E2E FAIL:", e.shortMessage || e.message); process.exit(1); });
