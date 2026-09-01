// Arcdesk order backend. One process: HTTP API + order book indexer + the settlement
// keeper. Zero external services — state lives in SQLite (node:sqlite), chain access goes
// through the same public RPCs as everything else.
//
//   node server.mjs           (reads ../.env and ../.deployer.json)
//
// Responsibilities:
//   - serve the live order book (offers indexed from the Arc escrow)
//   - create orders: pick an offer, quote premium+fee, generate the MAKER-side secret when
//     the desk is the maker, reserve liquidity on Arc BEFORE the taker pays
//   - watch both chains and drive settlement through the Keeper
//   - expose per-order status + per-address history for the frontend
//
// Trust notes: the maker's secret never leaves this process (only its hash goes on-chain),
// and the API never asks the taker for anything but addresses and amounts. The taker's
// money is protected by the escrow's timeout, not by this server behaving well.
import { createServer } from "http";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "fs";
import { ethers } from "ethers";
import { Keeper } from "../keeper/keeper.mjs";
import { ERC20_ABI, ESCROW_ABI } from "../keeper/abis.mjs";

// ---------------------------------------------------------------- config

const env = Object.fromEntries(
  readFileSync(new URL("../.env", import.meta.url), "utf8")
    .split("\n").filter((l) => l.includes("=") && !l.startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()])
);
const PK = JSON.parse(readFileSync(new URL("../.deployer.json", import.meta.url)))[0].private_key;
const PORT = Number(process.env.PORT || 8787);
const FEE_BPS = BigInt(env.FEE_BPS || 200);

// Arc's public RPCs are flaky (503s are common) — the competitor's outage was blamed on
// exactly this. Use every configured endpoint behind a FallbackProvider so a single sick
// node degrades latency instead of stopping settlement.
async function probe(url, chainId) {
  try {
    const r = await fetch(url, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
      signal: AbortSignal.timeout(6000),
    });
    const j = await r.json();
    return r.ok && parseInt(j.result, 16) === chainId;
  } catch { return false; }
}

// A dead endpoint in the pool is worse than no failover at all: ethers tries to parse its
// error body and the whole poll fails with "invalid numeric value". So every endpoint is
// probed first, and only the ones answering on the right chain are used.
async function provider(urls, chainId, label) {
  const candidates = urls.filter(Boolean);
  const live = [];
  for (const url of candidates) {
    if (await probe(url, chainId)) live.push(url);
    else console.log(`[rpc] ${label}: ${url} is not answering on chain ${chainId}, skipping`);
  }
  if (!live.length) throw new Error(`no working RPC for ${label} (tried ${candidates.length})`);
  console.log(`[rpc] ${label}: using ${live.length} endpoint(s) — ${live.join(", ")}`);
  if (live.length === 1) return new ethers.JsonRpcProvider(live[0], chainId, { staticNetwork: true });
  return new ethers.FallbackProvider(
    live.map((url, i) => ({
      provider: new ethers.JsonRpcProvider(url, chainId, { staticNetwork: true }),
      priority: i + 1, stallTimeout: 3000, weight: 1,
    })),
    chainId,
    { quorum: 1 }
  );
}
const src = await provider([env.SOURCE_RPC, env.SOURCE_RPC_2], Number(env.SOURCE_CHAIN_ID), "source");
const arc = await provider([env.ARC_RPC, env.ARC_RPC_2], Number(env.ARC_CHAIN_ID), "arc");
const wSrc = new ethers.Wallet(PK, src);
const wArc = new ethers.Wallet(PK, arc);
const srcEsc = new ethers.Contract(env.SOURCE_ESCROW, ESCROW_ABI, wSrc);
const arcEsc = new ethers.Contract(env.ARC_ESCROW, ESCROW_ABI, wArc);
const srcUsdc = new ethers.Contract(env.SOURCE_USDC, ERC20_ABI, src);

// ---------------------------------------------------------------- db

const db = new DatabaseSync(new URL("./arcdesk.db", import.meta.url).pathname);
db.exec(`
  CREATE TABLE IF NOT EXISTS offers (
    offerId TEXT PRIMARY KEY,
    maker TEXT NOT NULL,
    amount TEXT NOT NULL,          -- original size, 6dp string
    remaining TEXT NOT NULL,
    premiumBps INTEGER NOT NULL,
    expiry INTEGER NOT NULL,       -- 0 = open-ended
    active INTEGER NOT NULL,
    updatedBlock INTEGER NOT NULL DEFAULT 0
  );
  CREATE TABLE IF NOT EXISTS orders (
    orderId TEXT PRIMARY KEY,
    offerId TEXT NOT NULL,
    takerSource TEXT NOT NULL,     -- pays on the source chain
    recipientArc TEXT NOT NULL,    -- receives on Arc
    amount TEXT NOT NULL,          -- Arc USDC bought, 6dp
    proceeds TEXT NOT NULL,        -- maker leg on source chain, 6dp
    fee TEXT NOT NULL,
    hashlock TEXT NOT NULL,
    secret TEXT,                   -- present only when the desk is the maker
    resvDeadline INTEGER NOT NULL,
    payDeadline INTEGER NOT NULL,
    status TEXT NOT NULL,          -- quoted|reserved|paid|maker_paid|delivered|refunded|expired
    createdAt INTEGER NOT NULL,
    txReserve TEXT, txLock TEXT, txClaimPayment TEXT, txDeliver TEXT,
    lane TEXT NOT NULL DEFAULT 'ask'
  );
  CREATE INDEX IF NOT EXISTS idx_orders_taker ON orders(takerSource);
  CREATE TABLE IF NOT EXISTS bids (
    offerId TEXT PRIMARY KEY,      -- an offer posted on the SOURCE chain = a bid for Arc USDC
    bidder TEXT NOT NULL,
    amount TEXT NOT NULL,          -- source USDC escrowed by the bidder
    remaining TEXT NOT NULL,
    premiumBps INTEGER NOT NULL,   -- how much MORE the bidder pays vs the Arc USDC they want
    expiry INTEGER NOT NULL,
    active INTEGER NOT NULL,
    updatedBlock INTEGER NOT NULL DEFAULT 0
  );
  CREATE TABLE IF NOT EXISTS cursors (k TEXT PRIMARY KEY, v INTEGER NOT NULL);
`);

const getCursor = (k, dflt) => {
  const r = db.prepare("SELECT v FROM cursors WHERE k=?").get(k);
  return r ? r.v : dflt;
};
const setCursor = (k, v) => db.prepare(
  "INSERT INTO cursors(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v"
).run(k, v);

// ---------------------------------------------------------------- offer indexer (Arc)

async function pollRange(provider, contract, filter, cursorKey, handler) {
  const latest = await provider.getBlockNumber();
  let from = getCursor(cursorKey, latest - 500);
  if (from > latest) return;
  const to = Math.min(latest, from + 900);
  let logs;
  try {
    logs = await contract.queryFilter(filter, from, to);
  } catch {
    return; // transient RPC failure; retry next tick from the same cursor
  }
  for (const log of logs) await handler(log);
  setCursor(cursorKey, to + 1);
}

async function indexOffers() {
  await pollRange(arc, arcEsc, arcEsc.filters.OfferPosted(), "offerPosted", async (log) => {
    const { offerId, maker, amount, premiumBps, expiry } = log.args;
    db.prepare(`INSERT OR REPLACE INTO offers(offerId,maker,amount,remaining,premiumBps,expiry,active,updatedBlock)
      VALUES(?,?,?,?,?,?,1,?)`)
      .run(offerId, maker, amount.toString(), amount.toString(), Number(premiumBps), Number(expiry), log.blockNumber);
  });
  for (const [ev, key] of [["OfferCancelled", "offerCancel"], ["OfferExpired", "offerExpire"]]) {
    await pollRange(arc, arcEsc, arcEsc.filters[ev](), key, async (log) => {
      db.prepare("UPDATE offers SET active=0, remaining='0', updatedBlock=? WHERE offerId=?")
        .run(log.blockNumber, log.args.offerId);
    });
  }
  // Reservations & refunds change `remaining`; re-read affected offers from chain.
  for (const [ev, key] of [["Reserved", "resv"], ["ReservationRefunded", "resvRefund"]]) {
    await pollRange(arc, arcEsc, arcEsc.filters[ev](), key, async (log) => {
      const offerId = ev === "Reserved" ? log.args.offerId
        : db.prepare("SELECT offerId FROM orders WHERE orderId=?").get(log.args.orderId)?.offerId;
      if (!offerId) return;
      const o = await arcEsc.offers(offerId);
      db.prepare("UPDATE offers SET remaining=?, active=?, updatedBlock=? WHERE offerId=?")
        .run(o.remaining.toString(), o.active ? 1 : 0, log.blockNumber, offerId);
    });
  }
}

// Bids are offers posted on the SOURCE chain: someone escrows source USDC and wants Arc USDC
// back. Indexed with the same event shape as asks, from the other deployment.
async function indexBids() {
  await pollRange(src, srcEsc, srcEsc.filters.OfferPosted(), "bidPosted", async (log) => {
    const { offerId, maker, amount, premiumBps, expiry } = log.args;
    db.prepare(`INSERT OR REPLACE INTO bids(offerId,bidder,amount,remaining,premiumBps,expiry,active,updatedBlock)
      VALUES(?,?,?,?,?,?,1,?)`)
      .run(offerId, maker, amount.toString(), amount.toString(), Number(premiumBps), Number(expiry), log.blockNumber);
  });
  for (const [ev, key] of [["OfferCancelled", "bidCancel"], ["OfferExpired", "bidExpire"]]) {
    await pollRange(src, srcEsc, srcEsc.filters[ev](), key, async (log) => {
      db.prepare("UPDATE bids SET active=0, remaining='0', updatedBlock=? WHERE offerId=?")
        .run(log.blockNumber, log.args.offerId);
    });
  }
  for (const [ev, key] of [["Reserved", "bidResv"], ["ReservationRefunded", "bidResvRefund"]]) {
    await pollRange(src, srcEsc, srcEsc.filters[ev](), key, async (log) => {
      const offerId = ev === "Reserved" ? log.args.offerId
        : db.prepare("SELECT offerId FROM orders WHERE orderId=?").get(log.args.orderId)?.offerId;
      if (!offerId) return;
      const o = await srcEsc.offers(offerId);
      db.prepare("UPDATE bids SET remaining=?, active=?, updatedBlock=? WHERE offerId=?")
        .run(o.remaining.toString(), o.active ? 1 : 0, log.blockNumber, offerId);
    });
  }
}

// ---------------------------------------------------------------- order status tracker

async function trackOrders() {
  const open = db.prepare(
    "SELECT orderId,status,takerSource,lane FROM orders WHERE status IN ('reserved','paid','maker_paid')"
  ).all();
  for (const row of open) {
    try {
      // The two lanes put the payment and the reservation on opposite chains.
      const isBid = row.lane === "bid";
      const payEsc = isBid ? arcEsc : srcEsc;
      const offEsc = isBid ? srcEsc : arcEsc;
      const p = await payEsc.paymentOf(row.orderId, row.takerSource);
      const r = await offEsc.reservations(row.orderId);
      let status = row.status;
      if (r.status === 2n) status = "delivered";
      else if (p.status === 2n) status = "maker_paid";
      else if (p.status === 3n) status = "refunded";
      else if (p.status === 1n) status = "paid";
      if (status !== row.status) {
        db.prepare("UPDATE orders SET status=? WHERE orderId=?").run(status, row.orderId);
        console.log(`[orders] ${row.orderId.slice(0, 10)}… -> ${status}`);
      }
    } catch { /* transient RPC failure; retry next tick */ }
  }
}

// ---------------------------------------------------------------- keeper

// Two lanes over the same symmetric escrow:
//   ask — someone sells Arc USDC: liquidity sits on Arc, the buyer pays on the source chain
//   bid — someone wants Arc USDC: their funds sit on the source chain, the seller delivers on Arc
// Nothing in the contract distinguishes them; only which chain holds the posted liquidity.
const keeper = new Keeper({
  lane: "ask",
  paymentSigner: wSrc, offerSigner: wArc,
  paymentAddr: env.SOURCE_ESCROW, offerAddr: env.ARC_ESCROW,
});
const bidKeeper = new Keeper({
  lane: "bid",
  paymentSigner: wArc, offerSigner: wSrc,
  paymentAddr: env.ARC_ESCROW, offerAddr: env.SOURCE_ESCROW,
});

// Re-register unfinished orders after a restart so settlement resumes.
for (const o of db.prepare("SELECT * FROM orders WHERE status IN ('reserved','paid','maker_paid')").all()) {
  (o.lane === "bid" ? bidKeeper : keeper).registerOrder(o.orderId, {
    offerId: o.offerId, recipient: o.recipientArc, amount: BigInt(o.amount),
    hashlock: o.hashlock, resvDeadline: o.resvDeadline, secret: o.secret || undefined,
    payer: o.takerSource, maker: wSrc.address, proceeds: o.proceeds, fee: o.fee,
  });
}

// ---------------------------------------------------------------- quoting & orders

const MIN_RESV_WINDOW = 90 * 60; // mirrors MIN_RESERVATION_WINDOW
const PAY_WINDOW = 20 * 60; // < MAX_PAYMENT_WINDOW

function quoteFor(offer, amount6) {
  const amount = BigInt(amount6);
  const proceeds = (amount * (10000n + BigInt(offer.premiumBps))) / 10000n;
  const fee = (proceeds * FEE_BPS) / 10000n;
  return { amount, proceeds, fee, totalPay: proceeds + fee };
}

// per-offer cap on reserved-but-unpaid orders: an anonymous caller cannot lock more than a
// small slice of a maker's liquidity without paying, bounding the griefing surface.
const MAX_PENDING_PER_OFFER = 3;

async function createOrder({ offerId, amount6, takerSource, recipientArc }) {
  if (typeof offerId !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(offerId)) throw httpErr(400, "bad offerId");
  if (typeof amount6 !== "string" || !/^[0-9]{1,18}$/.test(amount6) || BigInt(amount6) <= 0n) throw httpErr(400, "bad amount");
  const offer = db.prepare("SELECT * FROM offers WHERE offerId=? AND active=1").get(offerId);
  if (!offer) throw httpErr(404, "offer not found or inactive");
  if (offer.expiry !== 0 && offer.expiry <= Math.floor(Date.now() / 1000)) throw httpErr(410, "offer expired");
  if (BigInt(offer.remaining) < BigInt(amount6)) throw httpErr(409, "not enough liquidity in offer");
  if (!ethers.isAddress(takerSource) || !ethers.isAddress(recipientArc)) throw httpErr(400, "bad address");
  const pending = db.prepare(
    "SELECT COUNT(*) n FROM orders WHERE offerId=? AND status='reserved'"
  ).get(offerId).n;
  if (pending >= MAX_PENDING_PER_OFFER) throw httpErr(429, "too many unpaid reservations on this offer, try again shortly");

  const q = quoteFor(offer, amount6);
  const orderId = ethers.id(`arcdesk-${offerId}-${takerSource}-${Date.now()}-${Math.random()}`);

  // The desk is currently the only maker, so it generates the secret. Third-party makers
  // will bring their own hashlock through the maker API (next iteration).
  const secret = ethers.hexlify(ethers.randomBytes(32));
  const hashlock = ethers.keccak256(ethers.solidityPacked(["bytes32"], [secret]));

  const nowArc = (await arc.getBlock("latest")).timestamp;
  const resvDeadline = nowArc + MIN_RESV_WINDOW + 120; // contract minimum + small buffer, so unpaid liquidity frees fast
  const nowSrc = (await src.getBlock("latest")).timestamp;
  const payDeadline = nowSrc + PAY_WINDOW;

  db.prepare(`INSERT INTO orders(orderId,offerId,takerSource,recipientArc,amount,proceeds,fee,hashlock,secret,
    resvDeadline,payDeadline,status,createdAt) VALUES(?,?,?,?,?,?,?,?,?,?,?,'quoted',?)`)
    .run(orderId, offerId, takerSource, recipientArc, q.amount.toString(), q.proceeds.toString(),
      q.fee.toString(), hashlock, secret, resvDeadline, payDeadline, Math.floor(Date.now() / 1000));

  keeper.registerOrder(orderId, {
    offerId, recipient: recipientArc, amount: q.amount, hashlock, resvDeadline, secret,
    payer: takerSource, maker: wSrc.address, proceeds: q.proceeds.toString(), fee: q.fee.toString(),
  });

  // Maker commits FIRST: reserve on Arc before asking the taker to pay anything.
  const txReserve = await keeper.reserveForOrder(orderId);
  db.prepare("UPDATE orders SET status='reserved', txReserve=? WHERE orderId=?").run(txReserve, orderId);

  return {
    orderId,
    escrow: env.SOURCE_ESCROW,
    usdc: env.SOURCE_USDC,
    // exact args for the taker's single transaction: approve + lockPayment on the source chain
    lockPayment: {
      orderId,
      maker: wSrc.address,
      treasury: env.TREASURY,
      proceeds: q.proceeds.toString(),
      fee: q.fee.toString(),
      hashlock,
      deadline: payDeadline,
    },
    totalPay: q.totalPay.toString(),
    payDeadline,
    resvDeadline,
  };
}

// Return griefed / abandoned reservations to their maker as soon as the contract allows,
// so an unpaid reservation never ties up liquidity longer than necessary.
async function sweepStaleReservations() {
  const now = Math.floor(Date.now() / 1000);
  const stale = db.prepare(
    "SELECT orderId,resvDeadline,status,lane FROM orders WHERE status IN ('quoted','reserved') AND resvDeadline < ?"
  ).all(now);
  for (const o of stale) {
    try {
      // A bid's liquidity sits on the source chain, an ask's on Arc.
      const offEsc = o.lane === "bid" ? srcEsc : arcEsc;
      const r = await offEsc.reservations(o.orderId);
      if (r.status === 1n) { // still Reserved -> refund it back to the offer
        await (await offEsc.refundReservation(o.orderId)).wait();
        console.log(`[sweeper] refunded stale reservation ${o.orderId.slice(0, 10)}…`);
      }
      db.prepare("UPDATE orders SET status='expired' WHERE orderId=?").run(o.orderId);
    } catch { /* retry next tick */ }
  }
}

/// Fill a bid: the seller has Arc USDC and wants the source USDC a bidder escrowed. Mirror of
/// createOrder — the bid's source-chain liquidity is reserved for the seller FIRST, then the
/// seller escrows their Arc USDC. The seller only ever transacts on Arc, where they already
/// hold funds (and therefore gas).
async function fillBid({ offerId, amount6, sellerArc, recipientSource }) {
  if (typeof offerId !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(offerId)) throw httpErr(400, "bad offerId");
  if (typeof amount6 !== "string" || !/^[0-9]{1,18}$/.test(amount6) || BigInt(amount6) <= 0n) throw httpErr(400, "bad amount");
  const bid = db.prepare("SELECT * FROM bids WHERE offerId=? AND active=1").get(offerId);
  if (!bid) throw httpErr(404, "bid not found or inactive");
  if (bid.expiry !== 0 && bid.expiry <= Math.floor(Date.now() / 1000)) throw httpErr(410, "bid expired");
  if (!ethers.isAddress(sellerArc) || !ethers.isAddress(recipientSource)) throw httpErr(400, "bad address");

  // The seller delivers `amount6` Arc USDC; the bid pays out proportionally from its escrow.
  const payout = (BigInt(amount6) * (10000n + BigInt(bid.premiumBps))) / 10000n;
  const fee = (payout * FEE_BPS) / 10000n;
  if (BigInt(bid.remaining) < payout + fee) throw httpErr(409, "bid cannot cover this size");
  const pending = db.prepare("SELECT COUNT(*) n FROM orders WHERE offerId=? AND status='reserved'").get(offerId).n;
  if (pending >= MAX_PENDING_PER_OFFER) throw httpErr(429, "too many unpaid fills on this bid, try again shortly");

  const orderId = ethers.id(`arcdesk-bid-${offerId}-${sellerArc}-${Date.now()}-${Math.random()}`);
  const secret = ethers.hexlify(ethers.randomBytes(32));
  const hashlock = ethers.keccak256(ethers.solidityPacked(["bytes32"], [secret]));

  const nowSrc = (await src.getBlock("latest")).timestamp;
  const resvDeadline = nowSrc + MIN_RESV_WINDOW + 120;
  const nowArc = (await arc.getBlock("latest")).timestamp;
  const payDeadline = nowArc + PAY_WINDOW;

  db.prepare(`INSERT INTO orders(orderId,offerId,takerSource,recipientArc,amount,proceeds,fee,hashlock,secret,
    resvDeadline,payDeadline,status,createdAt,lane) VALUES(?,?,?,?,?,?,?,?,?,?,?,'quoted',?,'bid')`)
    .run(orderId, offerId, sellerArc, recipientSource, amount6, (payout - fee).toString(),
      fee.toString(), hashlock, secret, resvDeadline, payDeadline, Math.floor(Date.now() / 1000));

  bidKeeper.registerOrder(orderId, {
    offerId, recipient: recipientSource, amount: payout, hashlock, resvDeadline, secret,
    payer: sellerArc, maker: wArc.address, proceeds: amount6, fee: "0",
  });

  const txReserve = await bidKeeper.reserveForOrder(orderId);
  db.prepare("UPDATE orders SET status='reserved', txReserve=? WHERE orderId=?").run(txReserve, orderId);

  return {
    orderId,
    escrow: env.ARC_ESCROW,   // the seller escrows Arc USDC here
    usdc: env.ARC_USDC,
    lockPayment: {
      orderId,
      maker: wArc.address,    // desk settles and forwards; payout is already reserved for you
      treasury: env.TREASURY,
      proceeds: amount6,
      fee: "0",
      hashlock,
      deadline: payDeadline,
    },
    youSend: amount6,
    youReceive: (payout - fee).toString(),
    payDeadline,
    resvDeadline,
  };
}

// Expired offers keep their liquidity locked until someone calls expireOffer. That call is
// permissionless, so the desk makes it on the maker's behalf and pays the gas — a maker should
// never have to babysit a window they already let lapse.
async function sweepExpiredOffers() {
  const now = Math.floor(Date.now() / 1000);
  const rows = [
    ...db.prepare("SELECT offerId FROM offers WHERE active=1 AND expiry != 0 AND expiry < ? AND remaining != '0'").all(now)
      .map((r) => ({ ...r, esc: arcEsc, tag: "ask" })),
    ...db.prepare("SELECT offerId FROM bids WHERE active=1 AND expiry != 0 AND expiry < ? AND remaining != '0'").all(now)
      .map((r) => ({ ...r, esc: srcEsc, tag: "bid" })),
  ];
  for (const r of rows) {
    try {
      const o = await r.esc.offers(r.offerId);
      if (!o.active || o.remaining === 0n) continue;
      await (await r.esc.expireOffer(r.offerId)).wait();
      console.log(`[sweeper] returned expired ${r.tag} ${r.offerId.slice(0, 10)}… to its maker`);
    } catch { /* retry next tick */ }
  }
}

// ---------------------------------------------------------------- http api

function httpErr(code, msg) { const e = new Error(msg); e.code = code; return e; }

// Simple per-IP sliding-window limiter for the only expensive, state-changing endpoint.
const rl = new Map(); // ip -> [timestamps]
function rateLimit(ip, max = 8, windowMs = 60000) {
  const now = Date.now();
  const hits = (rl.get(ip) || []).filter((t) => now - t < windowMs);
  hits.push(now);
  rl.set(ip, hits);
  if (rl.size > 5000) for (const [k, v] of rl) if (!v.some((t) => now - t < windowMs)) rl.delete(k);
  return hits.length <= max;
}

const routes = {
  "GET /health": async () => ({
    ok: true,
    keeper: wSrc.address,
    sourceEscrow: env.SOURCE_ESCROW,
    arcEscrow: env.ARC_ESCROW,
    feeBps: Number(FEE_BPS),
  }),

  "GET /offers": async () => {
    const now = Math.floor(Date.now() / 1000);
    const rows = db.prepare(
      "SELECT offerId,maker,remaining,premiumBps,expiry FROM offers WHERE active=1 AND remaining != '0'"
    ).all().filter((o) => o.expiry === 0 || o.expiry > now);
    return { offers: rows };
  },

  "GET /stats": async () => {
    const t = db.prepare("SELECT COUNT(*) n, COALESCE(SUM(CAST(proceeds AS INTEGER)+CAST(fee AS INTEGER)),0) v, COALESCE(SUM(CAST(fee AS INTEGER)),0) f FROM orders WHERE status='delivered'").get();
    return { trades: t.n, volume6: String(t.v), fees6: String(t.f) };
  },

  "GET /bids": async () => {
    const now = Math.floor(Date.now() / 1000);
    const rows = db.prepare(
      "SELECT offerId,bidder,remaining,premiumBps,expiry FROM bids WHERE active=1 AND remaining != '0'"
    ).all().filter((b) => b.expiry === 0 || b.expiry > now);
    return { bids: rows };
  },

  "POST /fills": async (body, _p, ip) => {
    if (!rateLimit(ip)) throw httpErr(429, "rate limit: slow down");
    return fillBid(body);
  },

  "POST /orders": async (body, _p, ip) => {
    if (!rateLimit(ip)) throw httpErr(429, "rate limit: slow down");
    return createOrder(body);
  },

  "GET /orders/:id": async (_, id) => {
    const o = db.prepare("SELECT orderId,offerId,takerSource,recipientArc,amount,proceeds,fee,hashlock,resvDeadline,payDeadline,status,createdAt,txReserve,txLock,txClaimPayment,txDeliver FROM orders WHERE orderId=?").get(id);
    if (!o) throw httpErr(404, "order not found");
    return o;
  },

  "GET /address/:addr/orders": async (_, addr) => {
    if (!ethers.isAddress(addr)) throw httpErr(400, "bad address");
    const rows = db.prepare(
      "SELECT orderId,amount,proceeds,fee,status,createdAt,payDeadline FROM orders WHERE lower(takerSource)=lower(?) ORDER BY createdAt DESC LIMIT 100"
    ).all(addr);
    return { orders: rows };
  },
};

// Static frontend from ../web — same origin as the API, so no CORS in production.
const WEB = new URL("../web/", import.meta.url);
const MIME = { html: "text/html", css: "text/css", js: "text/javascript", svg: "image/svg+xml", png: "image/png" };
function serveStatic(pathname, res) {
  const name = pathname === "/" ? "index.html" : pathname.slice(1);
  if (!/^[a-z0-9._-]+$/i.test(name)) return false;
  try {
    const body = readFileSync(new URL(name, WEB));
    res.writeHead(200, { "content-type": MIME[name.split(".").pop()] || "text/plain" });
    res.end(body);
    return true;
  } catch { return false; }
}

const server = createServer(async (req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "content-type");
  res.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  if (req.method === "OPTIONS") return res.writeHead(204).end();

  const url = new URL(req.url, "http://x");
  if (req.method === "GET" && serveStatic(url.pathname, res)) return;
  const parts = url.pathname.split("/").filter(Boolean);
  let handler = routes[`${req.method} ${url.pathname}`];
  let param;
  if (!handler && parts.length === 2 && req.method === "GET" && parts[0] === "orders") {
    handler = routes["GET /orders/:id"]; param = parts[1];
  }
  if (!handler && parts.length === 3 && req.method === "GET" && parts[0] === "address" && parts[2] === "orders") {
    handler = routes["GET /address/:addr/orders"]; param = parts[1];
  }
  if (!handler) { res.writeHead(404, { "content-type": "application/json" }); return res.end('{"error":"not found"}'); }

  let body = {};
  if (req.method === "POST") {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    try { body = JSON.parse(Buffer.concat(chunks).toString() || "{}"); }
    catch { res.writeHead(400, { "content-type": "application/json" }); return res.end('{"error":"bad json"}'); }
  }
  try {
    const ip = (req.headers["x-forwarded-for"] || "").split(",")[0].trim() || req.socket.remoteAddress || "?";
    const out = await handler(body, param, ip);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(out));
  } catch (e) {
    const code = e.code >= 400 && e.code < 600 ? e.code : 500;
    if (code === 500) console.error("[api]", e);
    res.writeHead(code, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: e.message }));
  }
});

// ---------------------------------------------------------------- main

await keeper.start();
await bidKeeper.start();
setInterval(() => indexOffers().catch(() => {}), 6000);
setInterval(() => indexBids().catch(() => {}), 6000);
setInterval(() => trackOrders().catch(() => {}), 6000);
setInterval(() => sweepStaleReservations().catch(() => {}), 30000);
setInterval(() => sweepExpiredOffers().catch(() => {}), 30000);
server.listen(PORT, () => console.log(`[api] listening on :${PORT}`));
