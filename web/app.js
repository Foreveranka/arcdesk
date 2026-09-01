// Arcdesk shared frontend logic: API access, wallet, formatting, nav.
// No build step, no libraries — raw JSON-RPC for reads, window.ethereum for writes.
"use strict";

const CFG = {
  // Default API: the public desk on the VPS; local dev automatically talks to a local backend.
  api: localStorage.getItem("arcdesk.api") ||
    (location.hostname === "localhost" || location.hostname === "127.0.0.1"
      ? "http://localhost:8899"
      : "https://api.arcdesk.exchange"),
  sourceChainId: "0x2105", // Base mainnet
  sourceRpc: "https://mainnet.base.org",
  arcRpc: "https://rpc.arc-scan.org",
  arcChainId: "0x13b2", // Arc mainnet 5042
  arcNative: { name: "USD Coin", symbol: "USDC", decimals: 18 },
  arcExplorer: "https://arcscan.app",
  sourceUsdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  arcUsdc: "0x3600000000000000000000000000000000000000",
  explorerSrc: "https://basescan.org",
  // 4-byte selectors, precomputed with `cast sig`
  sel: { approve: "0x095ea7b3", lockPayment: "0x8901ff7b", refundPayment: "0x40f2953a",
         balanceOf: "0x70a08231", allowance: "0xdd62ed3e" },
};

// ---------------------------------------------------------------- helpers

const $ = (q, el) => (el || document).querySelector(q);
const $$ = (q, el) => Array.from((el || document).querySelectorAll(q));
const short = (a) => (a ? a.slice(0, 6) + "…" + a.slice(-4) : "—");
const fmt6 = (v) => (Number(BigInt(v)) / 1e6).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const pad32 = (hex) => hex.replace(/^0x/, "").padStart(64, "0");
const padAddr = (a) => pad32(a.toLowerCase());
const padNum = (n) => pad32(BigInt(n).toString(16));

async function api(path, opts) {
  const r = await fetch(CFG.api + path, {
    headers: { "content-type": "application/json" }, ...opts,
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || `API ${r.status}`);
  return j;
}

async function rpc(url, method, params) {
  const r = await fetch(url, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return j.result;
}

const readUsdc = async (rpcUrl, token, addr) =>
  BigInt(await rpc(rpcUrl, "eth_call", [{ to: token, data: CFG.sel.balanceOf + padAddr(addr) }, "latest"]) || "0x0");

// ---------------------------------------------------------------- wallet

const wallet = {
  addr: localStorage.getItem("arcdesk.addr") || null,

  async connect() {
    if (!window.ethereum) { toast("No wallet found. Install MetaMask or Rabby.", "err"); return null; }
    const [addr] = await window.ethereum.request({ method: "eth_requestAccounts" });
    this.addr = addr;
    localStorage.setItem("arcdesk.addr", addr);
    renderWalletButton();
    return addr;
  },

  // Trades run on either chain: buying settles on the source chain, selling into a bid
  // settles on Arc. Every wallet call therefore names which chain it belongs to.
  chain(which) {
    return which === "arc"
      ? { id: CFG.arcChainId, rpc: CFG.arcRpc, label: "Arc",
          nativeCurrency: CFG.arcNative, explorer: CFG.arcExplorer }
      : { id: CFG.sourceChainId, rpc: CFG.sourceRpc, label: "Base",
          nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, explorer: CFG.explorerSrc };
  },

  async ensureChain(which) {
    const net = this.chain(which);
    const id = await window.ethereum.request({ method: "eth_chainId" });
    if (id === net.id) return;
    try {
      await window.ethereum.request({
        method: "wallet_switchEthereumChain", params: [{ chainId: net.id }],
      });
    } catch (e) {
      if (e.code === 4902 || /unrecognized|not been added/i.test(e.message || "")) {
        await window.ethereum.request({ method: "wallet_addEthereumChain", params: [{
          chainId: net.id, chainName: net.label, rpcUrls: [net.rpc],
          nativeCurrency: net.nativeCurrency, blockExplorerUrls: [net.explorer],
        }]});
        await window.ethereum.request({
          method: "wallet_switchEthereumChain", params: [{ chainId: net.id }],
        });
      } else throw e;
    }
  },

  async send(to, data, which = "source") {
    await this.ensureChain(which);
    return window.ethereum.request({
      method: "eth_sendTransaction",
      params: [{ from: this.addr, to, data }],
    });
  },

  async waitTx(hash, which = "source") {
    const url = this.chain(which).rpc;
    for (let i = 0; i < 80; i++) {
      const rec = await rpc(url, "eth_getTransactionReceipt", [hash]);
      if (rec) {
        if (rec.status !== "0x1") throw new Error("transaction reverted");
        return rec;
      }
      await new Promise((r) => setTimeout(r, 2500));
    }
    throw new Error("transaction not mined in time");
  },
};

function renderWalletButton() {
  const b = $("#connect");
  if (!b) return;
  if (wallet.addr) {
    b.classList.add("on");
    b.innerHTML = `<span class="dot"></span> <span class="mono">${short(wallet.addr)}</span>`;
  } else {
    b.classList.remove("on");
    b.textContent = "Connect wallet";
  }
}

// Theme: explicit choice persists in localStorage; without one the OS setting rules.
(function initTheme() {
  const saved = localStorage.getItem("arcdesk.theme");
  if (saved) document.documentElement.dataset.theme = saved;
})();
function toggleTheme() {
  const cur = document.documentElement.dataset.theme ||
    (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
  const next = cur === "dark" ? "light" : "dark";
  document.documentElement.dataset.theme = next;
  localStorage.setItem("arcdesk.theme", next);
  paintThemeBtn();
}
function paintThemeBtn() {
  const b = $("#themebtn");
  if (!b) return;
  const cur = document.documentElement.dataset.theme ||
    (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
  b.textContent = cur === "dark" ? "\u2600" : "\u263e";
  b.title = cur === "dark" ? "Switch to light" : "Switch to dark";
}

function initNav(current) {
  $$("nav.menu a").forEach((a) => { if (a.dataset.page === current) a.classList.add("here"); });
  const b = $("#connect");
  if (b) b.addEventListener("click", () => wallet.connect());
  const t = $("#themebtn");
  if (t) t.addEventListener("click", toggleTheme);
  paintThemeBtn();
  renderWalletButton();
}

// ---------------------------------------------------------------- ui bits

function toast(msg, kind) {
  let t = $("#toast");
  if (!t) {
    t = document.createElement("div");
    t.id = "toast";
    t.style.cssText = "position:fixed;bottom:22px;left:50%;transform:translateX(-50%);z-index:99;padding:11px 18px;border-radius:11px;font-weight:600;font-size:14px;box-shadow:var(--shadow);max-width:90vw";
    document.body.appendChild(t);
  }
  t.style.background = kind === "err" ? "var(--crit-soft)" : "var(--teal-soft)";
  t.style.color = kind === "err" ? "var(--crit)" : "var(--teal)";
  t.textContent = msg;
  t.style.display = "block";
  clearTimeout(t._h);
  t._h = setTimeout(() => (t.style.display = "none"), 5000);
}

const premClass = (bps) => (bps <= 500 ? "low" : bps <= 1200 ? "mid" : "high");
const statusBadge = (s) => ({
  quoted: '<span class="badge neutral">Quoted</span>',
  reserved: '<span class="badge pending">● Reserved — pay now</span>',
  paid: '<span class="badge pending">● Settling</span>',
  maker_paid: '<span class="badge pending">● Delivering</span>',
  delivered: '<span class="badge done">✓ Delivered</span>',
  refunded: '<span class="badge refund">↺ Refunded</span>',
  expired: '<span class="badge refund">Expired</span>',
}[s] || `<span class="badge neutral">${s}</span>`);

// calldata builders for the taker's transactions
const dataApprove = (spender, amount) => CFG.sel.approve + padAddr(spender) + padNum(amount);
const dataLockPayment = (p) =>
  CFG.sel.lockPayment + pad32(p.orderId) + padAddr(p.maker) + padAddr(p.treasury) +
  padNum(p.proceeds) + padNum(p.fee) + pad32(p.hashlock) + padNum(p.deadline);
const SEL_CANCEL_OFFER = "0xf952279e"; // cancelOffer(bytes32)
const SEL_POST_OFFER = "0x93154f38"; // postOffer(bytes32,uint256,uint16,uint64)
const dataRefund = (orderId, payer) => CFG.sel.refundPayment + pad32(orderId) + padAddr(payer);
