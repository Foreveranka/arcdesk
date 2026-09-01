// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {ArcdeskEscrow} from "../src/ArcdeskEscrow.sol";

/// @notice Exercises both legs of the desk. In production the two legs live on different
///         chains (source = Base/Arb, liquidity = Arc); here two instances of the same
///         contract run side by side in one EVM so the coordination is testable end to end.
contract ArcdeskEscrowTest is Test {
    MockUSDC srcUsdc; // source chain token (6dp, like Base USDC)
    MockUSDC arcUsdc; // Arc token (6dp)
    ArcdeskEscrow srcEsc; // payment leg
    ArcdeskEscrow arcEsc; // liquidity leg

    address maker = makeAddr("maker");
    address taker = makeAddr("taker");
    address takerArc = makeAddr("takerArc");
    address treasury = makeAddr("treasury");
    address keeper = makeAddr("keeper");
    address stranger = makeAddr("stranger");

    // The MAKER generates the preimage; the taker only ever sees the hash.
    bytes32 secret = keccak256("maker-preimage");
    bytes32 hashlock = keccak256(abi.encodePacked(keccak256("maker-preimage")));

    bytes32 constant OFFER = keccak256("offer-1");
    bytes32 constant ORDER = keccak256("order-1");

    // Buy 100 Arc USDC at 50% premium -> 150 proceeds, 2% desk fee -> 3.
    uint256 constant ARC_AMT = 100e6;
    uint256 constant PROCEEDS = 150e6;
    uint256 constant FEE = 3e6;
    uint16 constant PREMIUM_BPS = 5000;
    uint64 constant OFFER_TTL = 10 minutes;
    uint64 constant RESV_WINDOW = 2 hours; // > MIN_RESERVATION_WINDOW
    uint64 constant PAY_WINDOW = 20 minutes; // < MAX_PAYMENT_WINDOW

    function setUp() public {
        srcUsdc = new MockUSDC(6);
        arcUsdc = new MockUSDC(6);
        srcEsc = new ArcdeskEscrow(srcUsdc, keeper);
        arcEsc = new ArcdeskEscrow(arcUsdc, keeper);

        arcUsdc.mint(maker, 1_000e6);
        srcUsdc.mint(taker, 1_000e6);
    }

    function _postOffer(uint64 expiry) internal {
        vm.startPrank(maker);
        arcUsdc.approve(address(arcEsc), ARC_AMT);
        arcEsc.postOffer(OFFER, ARC_AMT, PREMIUM_BPS, expiry);
        vm.stopPrank();
    }

    function _postTimedOffer() internal {
        _postOffer(uint64(block.timestamp) + OFFER_TTL);
    }

    function _lockPayment(uint64 deadline) internal {
        vm.startPrank(taker);
        srcUsdc.approve(address(srcEsc), PROCEEDS + FEE);
        srcEsc.lockPayment(ORDER, maker, treasury, PROCEEDS, FEE, hashlock, deadline);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ full swap

    /// Maker moves first on Arc, taker pays second, maker claims the payment (publishing
    /// the preimage), and a third party delivers on Arc so the taker never needs Arc gas.
    function test_HappyPath() public {
        _postTimedOffer();
        uint64 resvDeadline = uint64(block.timestamp) + RESV_WINDOW;
        uint64 payDeadline = uint64(block.timestamp) + PAY_WINDOW;

        vm.prank(keeper);
        arcEsc.reserve(ORDER, OFFER, takerArc, ARC_AMT, hashlock, resvDeadline);

        _lockPayment(payDeadline);

        // Maker reveals the preimage by taking the payment.
        vm.prank(maker);
        srcEsc.claimPayment(ORDER, taker, secret);

        // Anyone can now deliver on Arc; here a stranger does it, and the taker's Arc
        // balance is untouched by gas because the taker never sends a transaction.
        assertEq(arcUsdc.balanceOf(takerArc), 0, "taker starts with no arc usdc");
        vm.prank(stranger);
        arcEsc.claimReservation(ORDER, secret);
        assertEq(arcUsdc.balanceOf(takerArc), ARC_AMT, "taker got arc usdc without transacting");

        assertEq(srcUsdc.balanceOf(maker), PROCEEDS, "maker got proceeds");
        assertEq(srcUsdc.balanceOf(treasury), FEE, "treasury got fee");
        assertEq(srcUsdc.balanceOf(address(srcEsc)), 0, "payment escrow drained");
        assertEq(arcUsdc.balanceOf(address(arcEsc)), 0, "liquidity escrow drained");
    }

    // --------------------------------------------------------------- refund paths

    function test_TakerRefund_WhenSwapStalls() public {
        _postTimedOffer();
        uint64 payDeadline = uint64(block.timestamp) + PAY_WINDOW;
        _lockPayment(payDeadline);
        vm.warp(payDeadline);
        srcEsc.refundPayment(ORDER, taker);
        assertEq(srcUsdc.balanceOf(taker), 1_000e6, "taker fully refunded");
    }

    function test_PaymentRefund_RejectedBeforeDeadline() public {
        _postTimedOffer();
        uint64 payDeadline = uint64(block.timestamp) + PAY_WINDOW;
        _lockPayment(payDeadline);
        vm.expectRevert(bytes("not yet"));
        srcEsc.refundPayment(ORDER, taker);
    }

    function test_ReservationRefund_ReturnsToOffer() public {
        _postTimedOffer();
        uint64 resvDeadline = uint64(block.timestamp) + RESV_WINDOW;
        vm.prank(keeper);
        arcEsc.reserve(ORDER, OFFER, takerArc, ARC_AMT, hashlock, resvDeadline);

        vm.warp(resvDeadline);
        arcEsc.refundReservation(ORDER);
        (, uint256 remaining,,,) = arcEsc.offers(OFFER);
        assertEq(remaining, ARC_AMT, "liquidity back in offer");
    }

    function test_ClaimedPaymentCannotBeRefunded() public {
        _postTimedOffer();
        uint64 payDeadline = uint64(block.timestamp) + PAY_WINDOW;
        _lockPayment(payDeadline);
        srcEsc.claimPayment(ORDER, taker, secret);
        vm.warp(payDeadline);
        vm.expectRevert(bytes("not locked"));
        srcEsc.refundPayment(ORDER, taker);
    }

    // ------------------------------------------------------------- hashlock rules

    function test_CannotClaimReservationWithoutSecret() public {
        _postTimedOffer();
        vm.prank(keeper);
        arcEsc.reserve(ORDER, OFFER, takerArc, ARC_AMT, hashlock, uint64(block.timestamp) + RESV_WINDOW);
        vm.expectRevert(bytes("bad preimage"));
        arcEsc.claimReservation(ORDER, keccak256("wrong"));
    }

    function test_CannotClaimPaymentWithoutSecret() public {
        _postTimedOffer();
        _lockPayment(uint64(block.timestamp) + PAY_WINDOW);
        vm.expectRevert(bytes("bad preimage"));
        srcEsc.claimPayment(ORDER, taker, keccak256("wrong"));
    }

    // ------------------------------------------------------------- access control

    function test_OnlyOperatorCanReserve() public {
        _postTimedOffer();
        vm.prank(stranger);
        vm.expectRevert(bytes("not operator"));
        arcEsc.reserve(ORDER, OFFER, takerArc, ARC_AMT, hashlock, uint64(block.timestamp) + RESV_WINDOW);
    }

    function test_OnlyOwnerCanSetOperator() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not owner"));
        arcEsc.setOperator(stranger);
    }

    function test_OnlyMakerCanCancelOffer() public {
        _postTimedOffer();
        vm.prank(stranger);
        vm.expectRevert(bytes("not maker"));
        arcEsc.cancelOffer(OFFER);
    }

    // Griefing check: a rogue keeper cannot redirect maker liquidity to itself beyond the
    // slice it reserves, and reserved funds only ever reach the named recipient.
    function test_KeeperCannotDrainOffer() public {
        _postTimedOffer();
        vm.prank(keeper);
        arcEsc.reserve(ORDER, OFFER, keeper, 1e6, hashlock, uint64(block.timestamp) + RESV_WINDOW);
        arcEsc.claimReservation(ORDER, secret);
        assertEq(arcUsdc.balanceOf(keeper), 1e6);
        (, uint256 remaining,,,) = arcEsc.offers(OFFER);
        assertEq(remaining, ARC_AMT - 1e6, "rest of offer untouched");
    }

    // ------------------------------------------------------- timed / open-ended offers

    function test_OfferExpiry_BlocksReservation() public {
        _postTimedOffer();
        vm.warp(block.timestamp + OFFER_TTL + 1);
        vm.prank(keeper);
        vm.expectRevert(bytes("offer expired"));
        arcEsc.reserve(ORDER, OFFER, takerArc, ARC_AMT, hashlock, uint64(block.timestamp) + RESV_WINDOW);
    }

    function test_ExpireOffer_ReturnsLiquidityToMaker() public {
        _postTimedOffer();
        vm.warp(block.timestamp + OFFER_TTL + 1);
        arcEsc.expireOffer(OFFER); // permissionless sweep
        assertEq(arcUsdc.balanceOf(maker), 1_000e6, "maker whole again");
        (,,,, bool active) = arcEsc.offers(OFFER);
        assertFalse(active);
    }

    function test_ExpireOffer_OnlyAfterExpiry() public {
        _postTimedOffer();
        vm.expectRevert(bytes("not expired"));
        arcEsc.expireOffer(OFFER);
    }

    function test_OpenEndedOffer_StillReservableFarInFuture() public {
        _postOffer(0);
        vm.warp(block.timestamp + 365 days);
        vm.prank(keeper);
        arcEsc.reserve(ORDER, OFFER, takerArc, ARC_AMT, hashlock, uint64(block.timestamp) + RESV_WINDOW);
        arcEsc.claimReservation(ORDER, secret);
        assertEq(arcUsdc.balanceOf(takerArc), ARC_AMT, "open-ended offer still fillable");
    }

    function test_OpenEndedOffer_CannotBeExpireSwept() public {
        _postOffer(0);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(bytes("open-ended"));
        arcEsc.expireOffer(OFFER);
    }

    function test_OpenEndedOffer_MakerCanStillCancel() public {
        _postOffer(0);
        vm.prank(maker);
        arcEsc.cancelOffer(OFFER);
        assertEq(arcUsdc.balanceOf(maker), 1_000e6, "maker withdrew open-ended liquidity");
    }

    function test_PostOffer_RejectsPastExpiry() public {
        vm.warp(1000);
        vm.startPrank(maker);
        arcUsdc.approve(address(arcEsc), ARC_AMT);
        vm.expectRevert(bytes("bad expiry"));
        arcEsc.postOffer(OFFER, ARC_AMT, PREMIUM_BPS, uint64(block.timestamp) - 1);
        vm.stopPrank();
    }

    function test_ReserveMoreThanOfferFails() public {
        _postTimedOffer();
        vm.prank(keeper);
        vm.expectRevert(bytes("insufficient"));
        arcEsc.reserve(ORDER, OFFER, takerArc, ARC_AMT + 1, hashlock, uint64(block.timestamp) + RESV_WINDOW);
    }

    function test_DuplicateOrderIdRejected() public {
        _postTimedOffer();
        uint64 dl = uint64(block.timestamp) + RESV_WINDOW;
        vm.startPrank(keeper);
        arcEsc.reserve(ORDER, OFFER, takerArc, 1e6, hashlock, dl);
        vm.expectRevert(bytes("order exists"));
        arcEsc.reserve(ORDER, OFFER, takerArc, 1e6, hashlock, dl);
        vm.stopPrank();
    }

    // ------------------------------------------------- ordering windows (the A fix)

    /// A payment that outlives its reservation would let a maker take the money and then
    /// let the delivery lapse, so the payment window is capped on-chain.
    function test_PaymentWindowIsCapped() public {
        _postTimedOffer();
        // Read the bound before arming expectRevert: an external call made while it is
        // armed would consume the expectation instead of the call under test.
        uint64 tooLate = uint64(block.timestamp) + srcEsc.MAX_PAYMENT_WINDOW() + 1;
        vm.startPrank(taker);
        srcUsdc.approve(address(srcEsc), PROCEEDS + FEE);
        vm.expectRevert(bytes("payment window too long"));
        srcEsc.lockPayment(ORDER, maker, treasury, PROCEEDS, FEE, hashlock, tooLate);
        vm.stopPrank();
    }

    /// The maker commits first and must stay committed well past any payment deadline.
    function test_ReservationWindowHasAFloor() public {
        _postTimedOffer();
        uint64 tooSoon = uint64(block.timestamp) + arcEsc.MIN_RESERVATION_WINDOW() - 1;
        vm.prank(keeper);
        vm.expectRevert(bytes("reservation too short"));
        arcEsc.reserve(ORDER, OFFER, takerArc, ARC_AMT, hashlock, tooSoon);
    }

    function test_ReservationOutlivesPaymentByAWideMargin() public {
        assertGt(
            arcEsc.MIN_RESERVATION_WINDOW(),
            srcEsc.MAX_PAYMENT_WINDOW() * 2,
            "delivery window survives the payment deadline"
        );
    }

    /// If the maker takes the payment but nobody delivers, the taker is not left empty
    /// handed: the preimage is public, so the delivery stays callable by anyone until the
    /// reservation deadline, which is far later than the payment deadline.
    function test_DeliveryStillPossibleLongAfterPaymentDeadline() public {
        _postTimedOffer();
        uint64 resvDeadline = uint64(block.timestamp) + RESV_WINDOW;
        uint64 payDeadline = uint64(block.timestamp) + PAY_WINDOW;
        vm.prank(keeper);
        arcEsc.reserve(ORDER, OFFER, takerArc, ARC_AMT, hashlock, resvDeadline);
        _lockPayment(payDeadline);
        vm.prank(maker);
        srcEsc.claimPayment(ORDER, taker, secret);

        vm.warp(payDeadline + 1); // payment window is over
        vm.prank(stranger);
        arcEsc.claimReservation(ORDER, secret);
        assertEq(arcUsdc.balanceOf(takerArc), ARC_AMT, "delivery still landed");
    }

    // Both legs are the same bytecode: an instance can serve either role.
    function test_SameContractServesBothLegs() public {
        assertEq(address(srcEsc).code.length, address(arcEsc).code.length, "identical bytecode");
    }
}
