// Production keeper runner. Configure via env (see ../.env.example) and run:
//   node index.mjs
// It watches the source-chain PaymentEscrow and the Arc LiquidityEscrow and drives
// settlement. Order registration (linking a source payment to an Arc offer + recipient)
// is done by your backend via keeper.registerOrder(); here we expose a tiny HTTP hook
// only if ORDERS_HTTP is set, otherwise import and call registerOrder from your app.
import { ethers } from "ethers";
import { Keeper } from "./keeper.mjs";

const need = (k) => {
  const v = process.env[k];
  if (!v) throw new Error(`missing env ${k}`);
  return v;
};

const source = new ethers.JsonRpcProvider(need("SOURCE_RPC"));
const arc = new ethers.JsonRpcProvider(need("ARC_RPC"));
const sourceSigner = new ethers.Wallet(need("KEEPER_PK"), source);
const arcSigner = new ethers.Wallet(need("KEEPER_PK"), arc);

const keeper = new Keeper({
  paymentSigner: sourceSigner,
  offerSigner: arcSigner,
  paymentAddr: need("SOURCE_ESCROW"),
  offerAddr: need("ARC_ESCROW"),
});

await keeper.start();
console.log("[keeper] running. source:", need("SOURCE_RPC"), "arc:", need("ARC_RPC"));

// Keep the process alive.
process.on("SIGINT", async () => {
  await keeper.stop();
  process.exit(0);
});

// Export for a backend that imports this module to register orders.
export { keeper };
