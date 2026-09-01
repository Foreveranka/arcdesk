// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {ArcdeskEscrow} from "../src/ArcdeskEscrow.sol";

/// @notice Adversarial suite. Every test here is written from an attacker's seat and asserts
///         either that the attack fails, or documents exactly how far it gets. Tests whose
///         name starts with EXPLOIT_ describe an attack that currently SUCCEEDS and is a real
///         finding; the rest are attacks the design already turns away.
contract AttackTest is Test {
    MockUSDC srcUsdc;
    MockUSDC arcUsdc;
    ArcdeskEscrow srcEsc;
    ArcdeskEscrow arcEsc;

    address maker = makeAddr("maker");
    address taker = makeAddr("taker");
    address takerArc = makeAddr("takerArc");
    address treasury = makeAddr("treasury");
    address keeper = makeAddr("keeper");
    address attacker = makeAddr("attacker");

    bytes32 secret = keccak256("maker-preimage");
    bytes32 hashlock = keccak256(abi.encodePacked(keccak256("maker-preimage")));
    bytes32 constant OFFER = keccak256("offer-1");
    bytes32 constant ORDER = keccak256("order-1");

    uint256 constant ARC_AMT = 100e6;
    uint256 constant PROCEEDS = 108e6;
    uint256 constant FEE = 216e4;
    uint64 constant RESV = 2 hours;
    uint64 constant PAY = 20 minutes;

    function setUp() public {
        srcUsdc = new MockUSDC(6);
        arcUsdc = new MockUSDC(6);
        srcEsc = new ArcdeskEscrow(srcUsdc, keeper);
        arcEsc = new ArcdeskEscrow(arcUsdc, keeper);
        arcUsdc.mint(maker, 1_000e6);
        srcUsdc.mint(taker, 1_000e6);
        srcUsdc.mint(attacker, 1_000e6);
        arcUsdc.mint(attacker, 1_000e6);
    }

    function _offer() internal {
        vm.startPrank(maker);
        arcUsdc.approve(address(arcEsc), ARC_AMT);
        arcEsc.postOffer(OFFER, ARC_AMT, 800, 0);
        vm.stopPrank();
    }

    function _reserve() internal {
        vm.prank(keeper);
        arcEsc.reserve(ORDER, OFFER, takerArc, ARC_AMT, hashlock, uint64(block.timestamp) + RESV);
    }

    function _lock() internal {
        vm.startPrank(taker);
        srcUsdc.approve(address(srcEsc), PROCEEDS + FEE);
        srcEsc.lockPayment(ORDER, maker, treasury, PROCEEDS, FEE, hashlock, uint64(block.timestamp) + PAY);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- attacks that fail

    /// Steal a delivery by claiming someone else's reservation to my own address.
    function test_CannotRedirectDelivery() public {
        _offer();
        _reserve();
        // The preimage is public once the maker claims payment. The attacker has it too.
        vm.prank(attacker);
        arcEsc.claimReservation(ORDER, secret);
        // ...but the funds still go to the recipient fixed at reserve time.
        assertEq(arcUsdc.balanceOf(takerArc), ARC_AMT, "delivery went to the taker");
        assertEq(arcUsdc.balanceOf(attacker), 1_000e6, "attacker gained nothing");
    }

    /// Take the taker's escrowed payment for myself.
    function test_CannotRedirectPayment() public {
        _offer();
        _reserve();
        _lock();
        vm.prank(attacker);
        srcEsc.claimPayment(ORDER, taker, secret); // attacker pays the gas, maker gets the money
        assertEq(srcUsdc.balanceOf(maker), PROCEEDS, "maker still paid");
        assertEq(srcUsdc.balanceOf(attacker), 1_000e6, "attacker gained nothing");
    }

    /// Refund someone else's payment into my wallet.
    function test_RefundAlwaysPaysThePayer() public {
        _offer();
        _lock();
        vm.warp(block.timestamp + PAY);
        vm.prank(attacker);
        srcEsc.refundPayment(ORDER, taker);
        assertEq(srcUsdc.balanceOf(taker), 1_000e6, "payer made whole");
        assertEq(srcUsdc.balanceOf(attacker), 1_000e6, "attacker gained nothing");
    }

    /// Drain an offer by cancelling it as a stranger, or sweep it early.
    function test_CannotTouchSomeoneElsesOffer() public {
        _offer();
        vm.startPrank(attacker);
        vm.expectRevert(bytes("not maker"));
        arcEsc.cancelOffer(OFFER);
        vm.expectRevert(bytes("not maker"));
        arcEsc.fundOffer(OFFER, 1);
        vm.expectRevert(bytes("open-ended"));
        arcEsc.expireOffer(OFFER);
        vm.stopPrank();
    }

    /// Claim a reservation with a forged preimage, or claim twice.
    function test_NoForgedOrReplayedClaims() public {
        _offer();
        _reserve();
        vm.startPrank(attacker);
        vm.expectRevert(bytes("bad preimage"));
        arcEsc.claimReservation(ORDER, keccak256("guess"));
        vm.stopPrank();
        arcEsc.claimReservation(ORDER, secret);
        vm.expectRevert(bytes("not reserved"));
        arcEsc.claimReservation(ORDER, secret); // double-spend attempt
    }

    /// Refund a reservation early to strand the taker after they paid.
    function test_CannotRefundReservationEarly() public {
        _offer();
        _reserve();
        vm.prank(attacker);
        vm.expectRevert(bytes("not yet"));
        arcEsc.refundReservation(ORDER);
    }

    /// Take over the desk.
    function test_CannotSeizeAdmin() public {
        vm.startPrank(attacker);
        vm.expectRevert(bytes("not owner"));
        arcEsc.setOperator(attacker);
        vm.expectRevert(bytes("not owner"));
        arcEsc.transferOwnership(attacker);
        vm.expectRevert(bytes("not operator"));
        arcEsc.reserve(ORDER, OFFER, attacker, 1, hashlock, uint64(block.timestamp) + RESV);
        vm.stopPrank();
    }

    /// Even the owner must not be able to reach escrowed funds.
    function test_OwnerCannotTouchFunds() public {
        _offer();
        _lock();
        uint256 escrowed = srcUsdc.balanceOf(address(srcEsc));
        // The owner's entire surface is setOperator + transferOwnership; there is no sweep,
        // no upgrade, and no pause. Confirm the balance is untouched by any owner action.
        srcEsc.setOperator(attacker);
        srcEsc.transferOwnership(attacker);
        assertEq(srcUsdc.balanceOf(address(srcEsc)), escrowed, "owner cannot move escrowed funds");
    }

    /// A maker cannot cancel liquidity that is already reserved for a taker.
    function test_MakerCannotPullReservedLiquidity() public {
        _offer();
        _reserve();
        vm.prank(maker);
        arcEsc.cancelOffer(OFFER); // takes back only the unreserved remainder (zero here)
        assertEq(arcUsdc.balanceOf(address(arcEsc)), ARC_AMT, "reserved slice stays escrowed");
        arcEsc.claimReservation(ORDER, secret);
        assertEq(arcUsdc.balanceOf(takerArc), ARC_AMT, "taker still gets delivery");
    }

    // ---------------------------------------------------------------- attacks that WORK

    /// EXPLOIT: the operator can move any maker's liquidity to itself. `reserve` is the only
    /// gate and it is operator-only with no maker consent, so a rogue or compromised keeper
    /// reserves an offer to its own address under a hashlock it chose, then claims it.
    /// Impact: total loss of every third-party maker's escrowed USDC.
    function test_EXPLOIT_OperatorDrainsMakerOffer() public {
        _offer();
        bytes32 evilSecret = keccak256("operator-owned");
        bytes32 evilHash = keccak256(abi.encodePacked(evilSecret));
        uint256 before = arcUsdc.balanceOf(attacker);

        vm.prank(keeper); // keeper key stolen, or the desk turns on its makers
        arcEsc.reserve(ORDER, OFFER, attacker, ARC_AMT, evilHash, uint64(block.timestamp) + RESV);
        arcEsc.claimReservation(ORDER, evilSecret);

        assertEq(arcUsdc.balanceOf(attacker) - before, ARC_AMT, "operator drained the whole offer");
    }

    /// FIXED (was an exploit): payments are now keyed by (orderId, payer), so an attacker
    /// locking a dust payment under a known orderId only occupies its own slot and cannot
    /// block the real taker's payment.
    function test_FrontRunOrderIdNoLongerBlocksTheTaker() public {
        _offer();
        _reserve(); // orderId + hashlock are public in the Reserved event

        // attacker front-runs with a dust lock under the same orderId, naming itself
        vm.startPrank(attacker);
        srcUsdc.approve(address(srcEsc), 2);
        srcEsc.lockPayment(ORDER, attacker, attacker, 1, 1, hashlock, uint64(block.timestamp) + PAY);
        vm.stopPrank();

        // the real taker's payment still goes through — different (orderId, payer) slot
        vm.startPrank(taker);
        srcUsdc.approve(address(srcEsc), PROCEEDS + FEE);
        srcEsc.lockPayment(ORDER, maker, treasury, PROCEEDS, FEE, hashlock, uint64(block.timestamp) + PAY);
        vm.stopPrank();

        // settle the taker's leg; the attacker's dust slot is independent and irrelevant
        vm.prank(maker);
        srcEsc.claimPayment(ORDER, taker, secret);
        assertEq(srcUsdc.balanceOf(maker), PROCEEDS, "maker paid from the real taker's slot");

        ArcdeskEscrow.Payment memory dust = srcEsc.paymentOf(ORDER, attacker);
        assertEq(uint256(dust.status), 1, "attacker's dust lock is still just Locked, harmless");
    }

}
