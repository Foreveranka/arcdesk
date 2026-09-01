import { ethers } from "ethers";
import { ESCROW_ABI } from "./abis.mjs";

// The desk keeper. It never custodies funds: it reserves maker liquidity on Arc, and once
// the maker has taken the payment on the source chain (which publishes the preimage) it
// delivers the Arc side on the taker's behalf. Every value movement stays bounded by the
// on-chain hashlocks and deadlines, so a keeper that disappears can stall a swap but never
// capture one.
//
// Ordering, and why it is this way round: the MAKER holds the preimage. The maker commits
// first on Arc (a long reservation), the taker pays second (a short lock), the maker claims
// the payment and thereby reveals the preimage, and only then is the Arc delivery possible.
// Because delivery is permissionless and pays a fixed recipient, the keeper can submit it
// for the taker. That matters because Arc's gas token is USDC and a taker buying their
// first Arc USDC has none to spend, so the taker must never have to transact on Arc.
// A lane is one trading direction. The escrow is symmetric, so both directions are the same
// machinery with the chains swapped:
//   ask  — maker's liquidity sits on Arc,  the buyer pays on the source chain
//   bid  — bidder's funds sit on the source chain, the seller pays (delivers) on Arc
// In both, `offer` is the chain holding the posted liquidity and `payment` is the chain where
// the counterparty escrows what they give.
export class Keeper {
  constructor({ paymentSigner, offerSigner, paymentAddr, offerAddr, lane = "ask", log = console.log }) {
    this.payEsc = new ethers.Contract(paymentAddr, ESCROW_ABI, paymentSigner);
    this.offEsc = new ethers.Contract(offerAddr, ESCROW_ABI, offerSigner);
    this.lane = lane;
    this.orders = new Map(); // orderId -> { offerId, recipient, amount, hashlock, resvDeadline, secret? }
    this.log = log;
  }

  /// The backend registers an order before reserving. `secret` is only present when the
  /// desk itself is the maker for this order; for third-party makers the desk never sees it.
  registerOrder(orderId, o) {
    this.orders.set(orderId.toLowerCase(), o);
  }

  /// Commit the maker's liquidity to a taker order. Called before the taker pays, so the
  /// taker can verify on Arc that the reservation outlasts their payment deadline.
  async reserveForOrder(orderId) {
    const o = this.orders.get(orderId.toLowerCase());
    if (!o) throw new Error("unknown order " + orderId);
    const tx = await this.offEsc.reserve(
      orderId, o.offerId, o.recipient, o.amount, o.hashlock, o.resvDeadline
    );
    await tx.wait();
    this.log(`[keeper:${this.lane}] reserved ${orderId}`);
    return tx.hash;
  }

  /// Public RPCs frequently drop eth_newFilter subscriptions ("filter not found"), so
  /// events are polled with getLogs over explicit block ranges instead of listeners.
  async _poll(contract, filter, fromKey, handler) {
    const provider = contract.runner.provider;
    const latest = await provider.getBlockNumber();
    let from = this._cursors[fromKey];
    if (from === undefined) from = Math.max(0, latest - 20);
    if (from > latest) return;
    const to = Math.min(latest, from + 900); // stay under common getLogs range caps
    let logs = [];
    try {
      logs = await contract.queryFilter(filter, from, to);
    } catch (e) {
      this.log(`[keeper:${this.lane}] getLogs ${fromKey} ${from}-${to} failed: ${e.shortMessage || e.message}`);
      return;
    }
    this._cursors[fromKey] = to + 1;
    for (const log of logs) {
      const key = `${log.transactionHash}:${log.index}`;
      if (this._seen.has(key)) continue;
      this._seen.add(key);
      // Bound the dedup set so a 7/24 process never leaks memory. The cursor only moves
      // forward, so once a block range is past, its keys can never recur; keeping the last
      // few thousand is far more than the one-poll overlap needs.
      if (this._seen.size > 5000) {
        this._seen = new Set(Array.from(this._seen).slice(-2000));
      }
      await handler(log);
    }
  }

  async start(intervalMs = 4000) {
    this._cursors = {};
    this._seen = new Set();
    this._stopped = false;

    // Payment chain: the counterparty's funds are locked. When the desk is also the maker it holds
    // the preimage, so it takes the payment here, which is what publishes the preimage.
    const onPaymentLocked = async (log) => {
      const { orderId, hashlock, payer, maker, proceeds, fee } = log.args;
      const o = this.orders.get(orderId.toLowerCase());
      if (!o) return this.log(`[keeper:${this.lane}] payment locked for unknown order ${orderId}, ignoring`);
      // Payments are keyed by (orderId, payer), so anyone can lock SOMETHING under a public
      // orderId. Claiming reveals the secret, so the keeper must only ever claim the exact
      // payment it quoted: right payer, the desk as maker, and at least the quoted amounts.
      // A dust lock or a lock naming a different maker is ignored, never claimed.
      if (payer.toLowerCase() !== (o.payer || "").toLowerCase()) {
        return this.log(`[keeper:${this.lane}] payment on ${orderId} from unexpected payer ${payer}, ignoring`);
      }
      if (hashlock.toLowerCase() !== o.hashlock.toLowerCase()) {
        return this.log(`[keeper:${this.lane}] hashlock mismatch on ${orderId}, leaving it alone`);
      }
      if (maker.toLowerCase() !== (o.maker || "").toLowerCase()
          || proceeds < BigInt(o.proceeds) || fee < BigInt(o.fee)) {
        return this.log(`[keeper:${this.lane}] payment terms on ${orderId} do not match the quote, ignoring`);
      }
      if (!o.secret) {
        return this.log(`[keeper:${this.lane}] payment locked ${orderId}, waiting for the maker to claim`);
      }
      try {
        this.log(`[keeper:${this.lane}] payment locked ${orderId} -> claiming as maker (reveals preimage)`);
        const tx = await this.payEsc.claimPayment(orderId, payer, o.secret);
        await tx.wait();
        this.log(`[keeper:${this.lane}] payment claimed ${orderId}`);
      } catch (e) {
        this.log(`[keeper:${this.lane}] claimPayment failed ${orderId}: ${e.shortMessage || e.message}`);
      }
    };

    // Payment chain: the poster took the payment, so the preimage is now public. Release the
    // posted liquidity to its recipient, who never needs gas on that chain.
    const onPaymentClaimed = async (log) => {
      const { orderId, preimage } = log.args;
      try {
        this.log(`[keeper:${this.lane}] preimage revealed for ${orderId} -> delivering on Arc`);
        const tx = await this.offEsc.claimReservation(orderId, preimage);
        await tx.wait();
        this.log(`[keeper:${this.lane}] delivered ${orderId}`);
      } catch (e) {
        this.log(`[keeper:${this.lane}] delivery failed ${orderId}: ${e.shortMessage || e.message}`);
      }
    };

    const tick = async () => {
      if (this._stopped) return;
      try {
        await this._poll(this.payEsc, this.payEsc.filters.PaymentLocked(), "payLocked", onPaymentLocked);
        await this._poll(this.payEsc, this.payEsc.filters.PaymentClaimed(), "payClaimed", onPaymentClaimed);
      } catch (e) {
        this.log(`[keeper:${this.lane}] poll error: ${e.shortMessage || e.message}`);
      }
      if (!this._stopped) this._timer = setTimeout(tick, intervalMs);
    };
    await tick();

    this.log(`[keeper:${this.lane}] polling payment leg (PaymentLocked, PaymentClaimed)`);
  }

  async stop() {
    this._stopped = true;
    if (this._timer) clearTimeout(this._timer);
  }
}
