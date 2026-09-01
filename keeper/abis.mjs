// Minimal ABI for ArcdeskEscrow (must match src/ArcdeskEscrow.sol). One contract serves
// both legs, so the same ABI is used for the source-chain and Arc deployments.
export const ESCROW_ABI = [
  // liquidity leg
  "function postOffer(bytes32 offerId,uint256 amount,uint16 premiumBps,uint64 expiry)",
  "function fundOffer(bytes32 offerId,uint256 amount)",
  "function cancelOffer(bytes32 offerId)",
  "function expireOffer(bytes32 offerId)",
  "function reserve(bytes32 orderId,bytes32 offerId,address recipient,uint256 amount,bytes32 hashlock,uint64 deadline)",
  "function claimReservation(bytes32 orderId,bytes32 preimage)",
  "function refundReservation(bytes32 orderId)",
  "function offers(bytes32) view returns (address maker,uint256 remaining,uint16 premiumBps,uint64 expiry,bool active)",
  "function reservations(bytes32) view returns (bytes32 offerId,address recipient,uint256 amount,bytes32 hashlock,uint64 deadline,uint8 status)",
  // payment leg
  "function lockPayment(bytes32 orderId,address maker,address treasury,uint256 proceeds,uint256 fee,bytes32 hashlock,uint64 deadline)",
  "function claimPayment(bytes32 orderId,address payer,bytes32 preimage)",
  "function refundPayment(bytes32 orderId,address payer)",
  "function paymentKey(bytes32,address) view returns (bytes32)",
  "function paymentOf(bytes32 orderId,address payer) view returns (tuple(address payer,address maker,address treasury,uint256 proceeds,uint256 fee,bytes32 hashlock,uint64 deadline,uint8 status))",
  // config
  "function usdc() view returns (address)",
  "function owner() view returns (address)",
  "function operator() view returns (address)",
  // events
  "event OfferPosted(bytes32 indexed offerId,address indexed maker,uint256 amount,uint16 premiumBps,uint64 expiry)",
  "event OfferCancelled(bytes32 indexed offerId,uint256 returned)",
  "event OfferExpired(bytes32 indexed offerId,uint256 returned)",
  "event Reserved(bytes32 indexed orderId,bytes32 indexed offerId,address indexed recipient,uint256 amount,bytes32 hashlock,uint64 deadline)",
  "event ReservationClaimed(bytes32 indexed orderId,bytes32 preimage)",
  "event ReservationRefunded(bytes32 indexed orderId,uint256 amount)",
  "event PaymentLocked(bytes32 indexed orderId,address indexed payer,address indexed maker,uint256 proceeds,uint256 fee,bytes32 hashlock,uint64 deadline)",
  "event PaymentClaimed(bytes32 indexed orderId,bytes32 preimage)",
  "event PaymentRefunded(bytes32 indexed orderId)",
];

export const ERC20_ABI = [
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function mint(address,uint256)",
  "function decimals() view returns (uint8)",
];
