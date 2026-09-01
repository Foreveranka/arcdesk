// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {ArcdeskEscrow} from "../src/ArcdeskEscrow.sol";

/// @notice Property tests over randomised amounts, premiums, addresses and deadlines. Each
///         one states a money guarantee that must hold for every input, not just the ones
///         a hand-written example happens to pick.
contract FuzzTest is Test {
    MockUSDC usdc;
    ArcdeskEscrow esc;
    address keeper = makeAddr("keeper");

    bytes32 constant SECRET = keccak256("fuzz-secret");
    bytes32 constant HASHLOCK = keccak256(abi.encodePacked(keccak256("fuzz-secret")));

    function setUp() public {
        usdc = new MockUSDC(6);
        esc = new ArcdeskEscrow(usdc, keeper);
    }

    function _assume(address a) internal view {
        vm.assume(a != address(0) && a != address(esc) && a.code.length == 0);
    }

    /// A refunded payer always gets back exactly what they escrowed — never less, never more.
    function testFuzz_RefundReturnsExactlyWhatWasPaid(
        address payer, address maker, address treasury,
        uint96 proceeds, uint96 fee, uint32 windowSeed
    ) public {
        _assume(payer); _assume(maker); _assume(treasury);
        vm.assume(maker != treasury);
        uint256 total = uint256(proceeds) + uint256(fee);
        vm.assume(total > 0 && total < 1e30);
        uint64 window = uint64(bound(windowSeed, 1, esc.MAX_PAYMENT_WINDOW()));

        bytes32 orderId = keccak256(abi.encode(payer, proceeds, fee));
        usdc.mint(payer, total);
        vm.startPrank(payer);
        usdc.approve(address(esc), total);
        esc.lockPayment(orderId, maker, treasury, proceeds, fee, HASHLOCK, uint64(block.timestamp) + window);
        vm.stopPrank();
        assertEq(usdc.balanceOf(payer), 0, "funds left the payer");

        vm.warp(block.timestamp + window);
        esc.refundPayment(orderId, payer); // permissionless
        assertEq(usdc.balanceOf(payer), total, "payer refunded to the cent");
        assertEq(usdc.balanceOf(address(esc)), 0, "escrow emptied");
    }

    /// A claimed payment always splits exactly: proceeds to the maker, fee to the treasury,
    /// nothing retained and nothing conjured.
    function testFuzz_ClaimSplitsExactly(
        address payer, address maker, address treasury, uint96 proceeds, uint96 fee
    ) public {
        _assume(payer); _assume(maker); _assume(treasury);
        vm.assume(maker != treasury && payer != maker && payer != treasury);
        uint256 total = uint256(proceeds) + uint256(fee);
        vm.assume(total > 0 && total < 1e30);

        bytes32 orderId = keccak256(abi.encode("split", payer, proceeds));
        usdc.mint(payer, total);
        vm.startPrank(payer);
        usdc.approve(address(esc), total);
        esc.lockPayment(orderId, maker, treasury, proceeds, fee, HASHLOCK, uint64(block.timestamp) + 10 minutes);
        vm.stopPrank();

        uint256 m0 = usdc.balanceOf(maker);
        uint256 t0 = usdc.balanceOf(treasury);
        esc.claimPayment(orderId, payer, SECRET);
        assertEq(usdc.balanceOf(maker) - m0, proceeds, "maker got exactly the proceeds");
        assertEq(usdc.balanceOf(treasury) - t0, fee, "treasury got exactly the fee");
        assertEq(usdc.balanceOf(address(esc)), 0, "escrow emptied");
    }

    /// Delivery always lands on the recipient chosen at reserve time, whoever submits it,
    /// and always for the exact reserved amount.
    function testFuzz_DeliveryGoesToTheNamedRecipient(
        address maker, address recipient, address submitter, uint96 amount, uint16 premium
    ) public {
        _assume(maker); _assume(recipient); _assume(submitter);
        vm.assume(maker != recipient);
        vm.assume(amount > 0);

        bytes32 offerId = keccak256(abi.encode("o", maker, amount));
        bytes32 orderId = keccak256(abi.encode("r", recipient, amount));
        usdc.mint(maker, amount);
        vm.startPrank(maker);
        usdc.approve(address(esc), amount);
        esc.postOffer(offerId, amount, premium, 0);
        vm.stopPrank();

        // Read the window before pranking: an external call while a prank is armed would
        // consume it and the reserve would come from the test contract, not the keeper.
        uint64 resvDeadline = uint64(block.timestamp) + esc.MIN_RESERVATION_WINDOW() + 1;
        vm.prank(keeper);
        esc.reserve(orderId, offerId, recipient, amount, HASHLOCK, resvDeadline);

        uint256 r0 = usdc.balanceOf(recipient);
        vm.prank(submitter); // anyone may deliver
        esc.claimReservation(orderId, SECRET);
        assertEq(usdc.balanceOf(recipient) - r0, amount, "recipient got exactly the reserved amount");
        assertEq(usdc.balanceOf(address(esc)), 0, "escrow emptied");
    }

    /// A reservation that is never claimed always returns the full amount to its offer,
    /// so maker liquidity can never be permanently stranded by an abandoned order.
    function testFuzz_UnclaimedReservationReturnsToOffer(uint96 amount, uint96 slice) public {
        vm.assume(amount > 0);
        uint256 take = bound(slice, 1, amount);
        address maker = makeAddr("m");
        address recipient = makeAddr("r");

        bytes32 offerId = keccak256(abi.encode("off", amount));
        bytes32 orderId = keccak256(abi.encode("ord", amount, take));
        usdc.mint(maker, amount);
        vm.startPrank(maker);
        usdc.approve(address(esc), amount);
        esc.postOffer(offerId, amount, 100, 0);
        vm.stopPrank();

        uint64 deadline = uint64(block.timestamp) + esc.MIN_RESERVATION_WINDOW() + 1;
        vm.prank(keeper);
        esc.reserve(orderId, offerId, recipient, take, HASHLOCK, deadline);

        vm.warp(deadline);
        esc.refundReservation(orderId);
        (, uint256 remaining,,,) = esc.offers(offerId);
        assertEq(remaining, amount, "offer restored to its full size");

        vm.prank(maker);
        esc.cancelOffer(offerId);
        assertEq(usdc.balanceOf(maker), amount, "maker recovered everything");
    }

    /// No preimage other than the real one can ever open a lock.
    function testFuzz_WrongPreimageNeverOpens(bytes32 guess) public {
        vm.assume(guess != SECRET);
        address payer = makeAddr("p");
        bytes32 orderId = keccak256("guess-test");
        usdc.mint(payer, 100e6);
        vm.startPrank(payer);
        usdc.approve(address(esc), 100e6);
        esc.lockPayment(orderId, makeAddr("m"), makeAddr("t"), 90e6, 10e6, HASHLOCK, uint64(block.timestamp) + 10 minutes);
        vm.stopPrank();

        vm.expectRevert(bytes("bad preimage"));
        esc.claimPayment(orderId, payer, guess);
    }

    /// The contract refuses any payment window longer than its own bound, for every input.
    function testFuzz_PaymentWindowBoundIsAbsolute(uint64 windowSeed) public {
        uint64 window = uint64(bound(windowSeed, esc.MAX_PAYMENT_WINDOW() + 1, 365 days));
        address payer = makeAddr("p2");
        usdc.mint(payer, 10e6);
        vm.startPrank(payer);
        usdc.approve(address(esc), 10e6);
        vm.expectRevert(bytes("payment window too long"));
        esc.lockPayment(keccak256("w"), makeAddr("m"), makeAddr("t"), 10e6, 0, HASHLOCK,
            uint64(block.timestamp) + window);
        vm.stopPrank();
    }
}
