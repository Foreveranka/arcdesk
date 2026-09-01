// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ArcdeskEscrow
/// @notice One escrow contract deployed to both sides of the desk. A cross-chain OTC swap
///         uses two instances of it: the source chain (Base/Arbitrum) runs the payment leg,
///         Arc runs the liquidity leg. Which half is used is decided by the chain it sits
///         on, not by configuration, so both deployments share one audited bytecode.
///
/// Liquidity leg (Arc): makers park USDC behind an offer, priced at their own premium and
/// either time-limited or open-ended. The keeper reserves slices of an offer against a
/// taker order under a hashlock the MAKER chose, with the taker named as recipient.
///
/// Payment leg (source chain): the taker escrows maker proceeds plus the desk fee under the
/// same hashlock. Revealing the preimage on one chain makes it public for the other, which
/// is what binds the two legs together.
///
/// Ordering matters. The maker holds the preimage, so the maker moves first on Arc
/// (reserve, long window) and the taker pays second (lock, short window). The maker then
/// claims the payment, which publishes the preimage on the source chain, and the Arc
/// delivery becomes a permissionless call anyone can make on the taker's behalf. That is
/// deliberate: on Arc the gas token is USDC, and a taker buying their first Arc USDC has
/// none, so the taker must never be required to transact there. The two windows below
/// enforce that a payment always expires long before the reservation backing it, leaving
/// time to deliver after the preimage becomes public.
///
/// The keeper never custodies funds: reserved liquidity can only reach the pre-committed
/// recipient or return to the maker, and an escrowed payment can only reach the maker and
/// treasury named at lock time or return to the payer. Every refund path is permissionless
/// and time-based, so a keeper that disappears can stall a swap but never capture it.
contract ArcdeskEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public owner;
    address public operator; // desk keeper

    /// A payment must expire quickly; a reservation must outlive it by a wide margin. Each
    /// chain can only check its own clock, so the guarantee is built from two local bounds:
    /// no payment can be locked for longer than MAX_PAYMENT_WINDOW, and no reservation can
    /// be created for less than MIN_RESERVATION_WINDOW. Before paying, a taker reads the
    /// reservation on Arc and checks it outlasts the payment deadline with room to spare.
    uint64 public constant MAX_PAYMENT_WINDOW = 30 minutes;
    uint64 public constant MIN_RESERVATION_WINDOW = 90 minutes;

    // ---------------------------------------------------------------- liquidity leg (Arc)

    enum RStatus {
        None,
        Reserved,
        Claimed,
        Refunded
    }

    struct Offer {
        address maker;
        uint256 remaining;
        uint16 premiumBps;
        uint64 expiry; // 0 = open-ended (never auto-expires)
        bool active;
    }

    struct Reservation {
        bytes32 offerId;
        address recipient;
        uint256 amount;
        bytes32 hashlock;
        uint64 deadline;
        RStatus status;
    }

    mapping(bytes32 => Offer) public offers;
    mapping(bytes32 => Reservation) public reservations;

    // ----------------------------------------------------------- payment leg (source chain)

    enum PStatus {
        None,
        Locked,
        Claimed,
        Refunded
    }

    struct Payment {
        address payer;
        address maker;
        address treasury;
        uint256 proceeds;
        uint256 fee;
        bytes32 hashlock;
        uint64 deadline;
        PStatus status;
    }

    /// Payments are keyed by keccak(orderId, payer), NOT orderId alone. Order ids are public
    /// (announced in the Arc-side Reserved event), so keying by orderId only would let anyone
    /// front-run a taker with a dust lock under the same id and block the real payment with
    /// "order exists". Namespacing by payer makes every payer's slot independent.
    mapping(bytes32 => Payment) private _payments;

    function paymentKey(bytes32 orderId, address payer) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(orderId, payer));
    }

    /// Read a payment by its (orderId, payer) pair.
    function paymentOf(bytes32 orderId, address payer) external view returns (Payment memory) {
        return _payments[paymentKey(orderId, payer)];
    }

    // ------------------------------------------------------------------------------ events

    event OfferPosted(bytes32 indexed offerId, address indexed maker, uint256 amount, uint16 premiumBps, uint64 expiry);
    event OfferFunded(bytes32 indexed offerId, uint256 amount);
    event OfferCancelled(bytes32 indexed offerId, uint256 returned);
    event OfferExpired(bytes32 indexed offerId, uint256 returned);
    event Reserved(
        bytes32 indexed orderId,
        bytes32 indexed offerId,
        address indexed recipient,
        uint256 amount,
        bytes32 hashlock,
        uint64 deadline
    );
    event ReservationClaimed(bytes32 indexed orderId, bytes32 preimage);
    event ReservationRefunded(bytes32 indexed orderId, uint256 amount);

    event PaymentLocked(
        bytes32 indexed orderId,
        address indexed payer,
        address indexed maker,
        uint256 proceeds,
        uint256 fee,
        bytes32 hashlock,
        uint64 deadline
    );
    event PaymentClaimed(bytes32 indexed orderId, bytes32 preimage);
    event PaymentRefunded(bytes32 indexed orderId);

    event OperatorChanged(address operator);
    event OwnerChanged(address owner);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "not operator");
        _;
    }

    constructor(IERC20 _usdc, address _operator) {
        usdc = _usdc;
        owner = msg.sender;
        operator = _operator;
    }

    /// @dev Rejects the zero address: an operator of 0 would permanently break reserve()
    ///      and strand every offer until each maker cancelled by hand.
    function setOperator(address _operator) external onlyOwner {
        require(_operator != address(0), "zero operator");
        operator = _operator;
        emit OperatorChanged(_operator);
    }

    function transferOwnership(address _owner) external onlyOwner {
        require(_owner != address(0), "zero owner");
        owner = _owner;
        emit OwnerChanged(_owner);
    }

    // ------------------------------------------------------------------- liquidity leg API

    /// @notice Maker posts an offer, depositing `amount` USDC. Pass a future timestamp for a
    ///         time-limited offer, or 0 to leave it open until the maker cancels.
    function postOffer(bytes32 offerId, uint256 amount, uint16 premiumBps, uint64 expiry) external nonReentrant {
        require(offers[offerId].maker == address(0), "offer exists");
        require(amount > 0, "zero amount");
        require(expiry == 0 || expiry > block.timestamp, "bad expiry");

        offers[offerId] =
            Offer({maker: msg.sender, remaining: amount, premiumBps: premiumBps, expiry: expiry, active: true});
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit OfferPosted(offerId, msg.sender, amount, premiumBps, expiry);
    }

    /// @notice Maker tops up an existing offer.
    function fundOffer(bytes32 offerId, uint256 amount) external nonReentrant {
        Offer storage o = offers[offerId];
        require(o.maker == msg.sender, "not maker");
        require(o.active, "inactive");
        require(amount > 0, "zero amount");
        o.remaining += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit OfferFunded(offerId, amount);
    }

    /// @notice Maker withdraws unreserved liquidity and closes the offer. Funds already
    ///         reserved stay locked until claimed or refunded.
    function cancelOffer(bytes32 offerId) external nonReentrant {
        Offer storage o = offers[offerId];
        require(o.maker == msg.sender, "not maker");
        uint256 amt = o.remaining;
        o.remaining = 0;
        o.active = false;
        if (amt > 0) usdc.safeTransfer(o.maker, amt);
        emit OfferCancelled(offerId, amt);
    }

    /// @notice Sweep an expired offer's liquidity back to its maker. Permissionless, so the
    ///         desk can clean up without the maker paying attention. Open-ended offers never
    ///         expire and are closed with cancelOffer instead.
    function expireOffer(bytes32 offerId) external nonReentrant {
        Offer storage o = offers[offerId];
        require(o.maker != address(0), "no offer");
        require(o.expiry != 0, "open-ended");
        require(block.timestamp >= o.expiry, "not expired");
        require(o.active, "inactive");
        uint256 amt = o.remaining;
        o.remaining = 0;
        o.active = false;
        if (amt > 0) usdc.safeTransfer(o.maker, amt);
        emit OfferExpired(offerId, amt);
    }

    /// @notice Keeper reserves `amount` from an offer for a taker order under `hashlock`.
    function reserve(
        bytes32 orderId,
        bytes32 offerId,
        address recipient,
        uint256 amount,
        bytes32 hashlock,
        uint64 deadline
    ) external onlyOperator nonReentrant {
        require(reservations[orderId].status == RStatus.None, "order exists");
        require(recipient != address(0), "bad recipient");
        require(hashlock != bytes32(0), "bad hashlock");
        // The maker moves first and must stay committed long enough for the taker to pay
        // and for the delivery to land after the preimage goes public.
        require(deadline >= block.timestamp + MIN_RESERVATION_WINDOW, "reservation too short");

        Offer storage o = offers[offerId];
        require(o.active, "inactive");
        require(o.expiry == 0 || block.timestamp < o.expiry, "offer expired");
        require(amount > 0 && o.remaining >= amount, "insufficient");

        o.remaining -= amount;
        reservations[orderId] = Reservation({
            offerId: offerId,
            recipient: recipient,
            amount: amount,
            hashlock: hashlock,
            deadline: deadline,
            status: RStatus.Reserved
        });
        emit Reserved(orderId, offerId, recipient, amount, hashlock, deadline);
    }

    /// @notice Release reserved liquidity to its recipient by revealing the preimage. Once
    ///         the maker has claimed the payment on the source chain the preimage is public,
    ///         so the keeper (or anyone) can call this to deliver. The taker never needs Arc
    ///         gas, and the funds can only ever reach the recipient fixed at reserve time.
    function claimReservation(bytes32 orderId, bytes32 preimage) external nonReentrant {
        Reservation storage r = reservations[orderId];
        require(r.status == RStatus.Reserved, "not reserved");
        require(keccak256(abi.encodePacked(preimage)) == r.hashlock, "bad preimage");
        r.status = RStatus.Claimed;
        usdc.safeTransfer(r.recipient, r.amount);
        emit ReservationClaimed(orderId, preimage);
    }

    /// @notice Return a stale reservation to its offer after the deadline. Permissionless.
    function refundReservation(bytes32 orderId) external nonReentrant {
        Reservation storage r = reservations[orderId];
        require(r.status == RStatus.Reserved, "not reserved");
        require(block.timestamp >= r.deadline, "not yet");
        r.status = RStatus.Refunded;
        offers[r.offerId].remaining += r.amount;
        emit ReservationRefunded(orderId, r.amount);
    }

    // --------------------------------------------------------------------- payment leg API

    /// @notice Taker escrows maker proceeds plus the desk fee for `orderId`.
    function lockPayment(
        bytes32 orderId,
        address maker,
        address treasury,
        uint256 proceeds,
        uint256 fee,
        bytes32 hashlock,
        uint64 deadline
    ) external nonReentrant {
        bytes32 k = paymentKey(orderId, msg.sender);
        require(_payments[k].status == PStatus.None, "order exists");
        require(maker != address(0) && treasury != address(0), "bad payee");
        require(hashlock != bytes32(0), "bad hashlock");
        require(deadline > block.timestamp, "deadline passed");
        // Bounded so the maker cannot sit on a claimable payment until the reservation
        // backing it is about to expire.
        require(deadline <= block.timestamp + MAX_PAYMENT_WINDOW, "payment window too long");

        _payments[k] = Payment({
            payer: msg.sender,
            maker: maker,
            treasury: treasury,
            proceeds: proceeds,
            fee: fee,
            hashlock: hashlock,
            deadline: deadline,
            status: PStatus.Locked
        });
        usdc.safeTransferFrom(msg.sender, address(this), proceeds + fee);
        emit PaymentLocked(orderId, msg.sender, maker, proceeds, fee, hashlock, deadline);
    }

    /// @notice Pay the maker and the treasury by revealing the preimage. Permissionless.
    ///         `payer` selects which payment (keyed by orderId + payer) is being settled.
    function claimPayment(bytes32 orderId, address payer, bytes32 preimage) external nonReentrant {
        Payment storage p = _payments[paymentKey(orderId, payer)];
        require(p.status == PStatus.Locked, "not locked");
        require(keccak256(abi.encodePacked(preimage)) == p.hashlock, "bad preimage");
        p.status = PStatus.Claimed;
        if (p.proceeds > 0) usdc.safeTransfer(p.maker, p.proceeds);
        if (p.fee > 0) usdc.safeTransfer(p.treasury, p.fee);
        emit PaymentClaimed(orderId, preimage);
    }

    /// @notice Return the full escrowed payment to its payer once the deadline has passed.
    ///         Permissionless and unstoppable; funds always go to the original payer.
    function refundPayment(bytes32 orderId, address payer) external nonReentrant {
        Payment storage p = _payments[paymentKey(orderId, payer)];
        require(p.status == PStatus.Locked, "not locked");
        require(block.timestamp >= p.deadline, "not yet");
        p.status = PStatus.Refunded;
        usdc.safeTransfer(p.payer, p.proceeds + p.fee);
        emit PaymentRefunded(orderId);
    }
}
