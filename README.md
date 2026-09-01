# Arcdesk

**[arcdesk.exchange](https://arcdesk.exchange)** — a two-sided, non-custodial OTC desk for moving
USDC between **Base** and the **Arc Network**. Makers post orders at their own premium, takers
accept them, and the desk earns a flat 2% from the taker. The desk never holds anyone's funds:
everything settles through escrow contracts, and every refund path is permissionless and time-based.

> **The contracts are unaudited.** They are covered by 49 automated tests and have settled real
> trades, but that is not an independent review. Do not risk more than you can afford to lose.

---

## Why this exists

Arc is a closed network: the official bridges in are not open, so USDC already inside it trades
above face value. That premium is the whole market. Makers price the scarcity, takers pay for
access, the desk takes 2%. When access opens, premiums collapse — this is a market for exactly as
long as the door stays shut, and the site says so plainly.

## How a trade works

The ordering is deliberate. **The party holding the posted liquidity also holds the preimage**, so
they commit first and reveal last:

1. **The maker commits first.** The keeper reserves a slice of their offer, addressed to the taker,
   under the maker's hashlock. Reservations must live at least 90 minutes.
2. **The taker pays second**, escrowing price + fee under the same hashlock on the other chain.
   A payment can be locked for at most 30 minutes.
3. **The maker claims the payment**, which publishes the preimage on-chain.
4. **Delivery** is then a permissionless call anyone can make, and the desk makes it.

Neither side can take the other's funds: the maker only reveals once a payment is claimable, and the
taker's payment refunds itself if nothing is delivered. The 30/90-minute asymmetry is enforced by
the contract and guarantees there is always time to deliver after a preimage goes public.

**Why step 4 being permissionless matters:** on Arc the gas token *is* USDC. A buyer acquiring their
first Arc USDC has none to spend, so they could never submit a claim there. Each party only ever
transacts on the chain where their funds already are.

## Two sides, one contract

The escrow is symmetric and the same bytecode is deployed to both chains; the chain it sits on
decides which half gets used. That is what makes bids possible with no new contract:

| | Ask (someone sells Arc USDC) | Bid (someone buys Arc USDC) |
|---|---|---|
| Posted liquidity lives on | Arc | Base |
| Counterparty pays on | Base | Arc |
| The taker is | the buyer | the seller |

## Live deployment

| Leg | Chain | Chain ID | Address |
|---|---|---|---|
| Payment | Base | 8453 | `0x663b1167456Ae4B52f3b226206B28cBc309c0a3a` |
| Liquidity | Arc | 5042 | `0x9f06B98B19EeB1bA17d8602D28e39a7350a8091b` |

USDC: Base `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, Arc `0x3600…0000` (6 decimals).

## Layout

```
contracts/   ArcdeskEscrow.sol and the full Foundry test suite
keeper/      settlement keeper; one class drives both trading directions
backend/     HTTP API + order-book indexer + keeper, one process, SQLite
web/         the site: order book, trade ticket, orders, profile, docs, policies
tools/       local browser tools for deploying and market making from a wallet
```

## Running it

```bash
cd contracts && forge test          # 49 tests
cp .env.example .env                # fill in RPCs, escrow addresses, keeper key
cd backend && PORT=8899 node server.mjs
```

That single process serves the API, indexes both order books, runs both keeper lanes, and serves
the site at `http://localhost:8899`.

### Local end-to-end

```bash
anvil --port 9987 & anvil --port 9988 &
cd contracts && forge build
cd ../keeper && SRC_URL=http://127.0.0.1:9987 ARC_URL=http://127.0.0.1:9988 node e2e.mjs
```

### Against the live chains

```bash
cd keeper && node live-e2e.mjs      # posts, pays, settles, and asserts balances
```

### Deploying

Use `tools/deploy.html` (serve `tools/` over http and open it) so the key never leaves your wallet,
or run `deploy-mainnet.sh`, which prompts for the key without echoing it. Both make **you** the
owner and set a separate hot key as operator.

## Testing

| Suite | What it covers |
|---|---|
| `ArcdeskEscrow.t.sol` | happy path, refunds, hashlock rules, access control, timed and open-ended orders |
| `Attack.t.sol` | adversarial: redirecting delivery or payment, forged and replayed claims, admin seizure, front-running |
| `Fuzz.t.sol` | randomised amounts and addresses: refunds return exactly what was paid, claims split exactly |
| `Invariant.t.sol` | 32k random call sequences; the escrow balance must equal its obligations exactly |
| `ForkedTestnet.t.sol` | wiring verified against the real chains and real USDC |

Static analysis: `slither src/ArcdeskEscrow.sol` reports no high or medium findings.

## Security

The system was tested adversarially and the findings fixed:

- **Order-id front-running** — payments are keyed by `(orderId, payer)`, so a dust lock under a
  public order id occupies only its own slot and cannot block the real taker.
- **Premature preimage reveal** — the keeper settles only the exact payment it quoted, checking the
  payer, the maker and the amounts before claiming.
- **Free reservation griefing** — a per-offer cap on unpaid reservations, per-IP rate limiting, and
  a sweeper that returns stale reservations and expired offers to their makers with the desk paying
  the gas.

**Known and open:** the operator can move liquidity posted by third-party makers. That is inherent
to a keeper-reserved design; the fix is maker-signed reservations (EIP-712), and it is a
prerequisite before third-party market making is opened. Today the desk is the only maker, so no
third-party funds are exposed.

## Trust model

| Party | Can | Cannot |
|---|---|---|
| Desk / keeper | stall a trade | take escrowed funds, redirect a delivery, or block a refund |
| Maker | decline to claim, so the trade times out and the taker is refunded | take a payment without releasing the USDC that unlocks it |
| Owner | change the operator | touch funds, block refunds, or upgrade the code — there is no proxy |
| Token issuer | freeze any Arc address, escrows included | — external, disclosed on the site's risk page |

## Arc specifics worth knowing

- USDC is also the gas token. `balanceOf` is the account's native balance divided by 10¹² — one pool
  of funds, a 6-decimal surface over an 18-decimal core.
- Transfers are executed by chain-level precompiles, so the Arc leg cannot be faithfully simulated
  on a fork and must be verified live.
- Public Arc RPCs return 503s often; the backend runs every endpoint behind a failover provider.

## License

MIT
