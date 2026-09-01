// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {ArcdeskEscrow} from "../src/ArcdeskEscrow.sol";

/// @notice Drives the escrow with random sequences of every public action, from random
///         actors, at random times. The handler tracks what the contract *owes* so the
///         invariants can compare it against what the contract actually holds.
contract Handler is Test {
    ArcdeskEscrow public esc;
    MockUSDC public usdc;

    address[] public actors;
    bytes32[] public offerIds;
    bytes32[] public orderIds;

    // shadow accounting of every obligation the contract has taken on
    uint256 public totalOfferRemaining;
    uint256 public totalReserved;
    uint256 public totalLockedPayments;

    mapping(bytes32 => bool) offerSeen;
    mapping(bytes32 => bool) orderSeen;

    bytes32 constant SECRET = keccak256("invariant-secret");
    bytes32 constant HASHLOCK = keccak256(abi.encodePacked(keccak256("invariant-secret")));

    constructor(ArcdeskEscrow _esc, MockUSDC _usdc, address[] memory _actors) {
        esc = _esc;
        usdc = _usdc;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function postOffer(uint256 actorSeed, uint256 amount, uint16 premium, uint256 expirySeed) public {
        amount = bound(amount, 1, 1_000e6);
        address maker = _actor(actorSeed);
        bytes32 offerId = keccak256(abi.encode("offer", offerIds.length, maker));
        if (offerSeen[offerId]) return;
        uint64 expiry = expirySeed % 2 == 0 ? 0 : uint64(block.timestamp + bound(expirySeed, 60, 30 days));

        vm.startPrank(maker);
        usdc.mint(maker, amount);
        usdc.approve(address(esc), amount);
        esc.postOffer(offerId, amount, premium, expiry);
        vm.stopPrank();

        offerSeen[offerId] = true;
        offerIds.push(offerId);
        totalOfferRemaining += amount;
    }

    function reserve(uint256 offerSeed, uint256 amount, uint256 recipientSeed) public {
        if (offerIds.length == 0) return;
        bytes32 offerId = offerIds[offerSeed % offerIds.length];
        (, uint256 remaining,, uint64 expiry, bool active) = esc.offers(offerId);
        if (!active || remaining == 0) return;
        if (expiry != 0 && block.timestamp >= expiry) return;
        amount = bound(amount, 1, remaining);

        bytes32 orderId = keccak256(abi.encode("order", orderIds.length, offerId));
        if (orderSeen[orderId]) return;

        vm.prank(esc.operator());
        esc.reserve(
            orderId, offerId, _actor(recipientSeed), amount, HASHLOCK,
            uint64(block.timestamp) + esc.MIN_RESERVATION_WINDOW() + 1
        );

        orderSeen[orderId] = true;
        orderIds.push(orderId);
        totalOfferRemaining -= amount;
        totalReserved += amount;
    }

    function claimReservation(uint256 orderSeed) public {
        if (orderIds.length == 0) return;
        bytes32 orderId = orderIds[orderSeed % orderIds.length];
        (,, uint256 amount,,, ArcdeskEscrow.RStatus status) = esc.reservations(orderId);
        if (status != ArcdeskEscrow.RStatus.Reserved) return;
        esc.claimReservation(orderId, SECRET);
        totalReserved -= amount;
    }

    function refundReservation(uint256 orderSeed) public {
        if (orderIds.length == 0) return;
        bytes32 orderId = orderIds[orderSeed % orderIds.length];
        (bytes32 offerId,, uint256 amount,, uint64 deadline, ArcdeskEscrow.RStatus status) = esc.reservations(orderId);
        if (status != ArcdeskEscrow.RStatus.Reserved || block.timestamp < deadline) return;
        esc.refundReservation(orderId);
        totalReserved -= amount;
        // liquidity returns to the offer, whether or not the offer is still active
        offerId; // silence unused
        totalOfferRemaining += amount;
    }

    function cancelOffer(uint256 offerSeed) public {
        if (offerIds.length == 0) return;
        bytes32 offerId = offerIds[offerSeed % offerIds.length];
        (address maker, uint256 remaining,,,) = esc.offers(offerId);
        if (maker == address(0)) return;
        vm.prank(maker);
        esc.cancelOffer(offerId);
        totalOfferRemaining -= remaining;
    }

    function expireOffer(uint256 offerSeed) public {
        if (offerIds.length == 0) return;
        bytes32 offerId = offerIds[offerSeed % offerIds.length];
        (, uint256 remaining,, uint64 expiry, bool active) = esc.offers(offerId);
        if (!active || expiry == 0 || block.timestamp < expiry) return;
        esc.expireOffer(offerId);
        totalOfferRemaining -= remaining;
    }

    function lockPayment(uint256 actorSeed, uint256 proceeds, uint256 fee, uint256 idSeed) public {
        proceeds = bound(proceeds, 0, 500e6);
        fee = bound(fee, 0, 50e6);
        address payer = _actor(actorSeed);
        bytes32 orderId = keccak256(abi.encode("pay", idSeed));
        ArcdeskEscrow.Payment memory existing = esc.paymentOf(orderId, payer);
        if (existing.status != ArcdeskEscrow.PStatus.None) return;

        vm.startPrank(payer);
        usdc.mint(payer, proceeds + fee);
        usdc.approve(address(esc), proceeds + fee);
        esc.lockPayment(
            orderId, _actor(actorSeed + 1), _actor(actorSeed + 2), proceeds, fee, HASHLOCK,
            uint64(block.timestamp) + esc.MAX_PAYMENT_WINDOW()
        );
        vm.stopPrank();
        totalLockedPayments += proceeds + fee;
    }

    function claimPayment(uint256 actorSeed, uint256 idSeed) public {
        address payer = _actor(actorSeed);
        bytes32 orderId = keccak256(abi.encode("pay", idSeed));
        ArcdeskEscrow.Payment memory p = esc.paymentOf(orderId, payer);
        if (p.status != ArcdeskEscrow.PStatus.Locked) return;
        esc.claimPayment(orderId, payer, SECRET);
        totalLockedPayments -= (p.proceeds + p.fee);
    }

    function refundPayment(uint256 actorSeed, uint256 idSeed) public {
        address payer = _actor(actorSeed);
        bytes32 orderId = keccak256(abi.encode("pay", idSeed));
        ArcdeskEscrow.Payment memory p = esc.paymentOf(orderId, payer);
        if (p.status != ArcdeskEscrow.PStatus.Locked || block.timestamp < p.deadline) return;
        esc.refundPayment(orderId, payer);
        totalLockedPayments -= (p.proceeds + p.fee);
    }

    /// let time move so deadline-gated paths are reachable
    function warp(uint256 secondsSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 3 hours));
    }
}

contract InvariantTest is Test {
    ArcdeskEscrow esc;
    MockUSDC usdc;
    Handler handler;

    function setUp() public {
        usdc = new MockUSDC(6);
        address keeper = makeAddr("keeper");
        esc = new ArcdeskEscrow(usdc, keeper);

        address[] memory actors = new address[](5);
        for (uint256 i = 0; i < 5; i++) actors[i] = makeAddr(string(abi.encodePacked("actor", i)));
        handler = new Handler(esc, usdc, actors);
        targetContract(address(handler));
    }

    /// The contract must always hold at least everything it owes: unreserved offer
    /// liquidity, reserved slices, and escrowed payments. If this ever breaks, someone
    /// could be paid out of another user's money.
    function invariant_SolventForEveryObligation() public view {
        uint256 owed = handler.totalOfferRemaining() + handler.totalReserved() + handler.totalLockedPayments();
        // Exact, not >=: nothing else can move the contract's balance, so any drift means
        // the contract released funds it did not owe, or kept funds it should have released.
        assertEq(usdc.balanceOf(address(esc)), owed, "escrow balance drifted from its obligations");
    }

    /// Admin roles can never be silently lost, which would strand funds behind a dead
    /// operator (reserve) or a dead owner (role rotation).
    function invariant_RolesNeverZero() public view {
        assertTrue(esc.operator() != address(0), "operator went to zero");
        assertTrue(esc.owner() != address(0), "owner went to zero");
    }

    /// The two ordering windows are the whole cross-chain safety argument: a payment must
    /// always expire long before the reservation backing it.
    function invariant_DeliveryWindowOutlivesPayment() public view {
        assertGt(esc.MIN_RESERVATION_WINDOW(), esc.MAX_PAYMENT_WINDOW() * 2, "window ordering broken");
    }
}
