// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArcdeskEscrow} from "../src/ArcdeskEscrow.sol";

/// @notice Integration test against the REAL testnet chains and their REAL USDC
///         contracts: Base Sepolia (source) and Arc testnet (liquidity). Both forks are
///         live in one test via vm.selectFork, so the escrows are exercised against the
///         actual token implementations they will meet on deploy, not a mock.
/// Run:  forge test --match-contract ForkedTestnet -vv
///       (needs SOURCE_FORK_RPC / ARC_FORK_RPC, defaults to the public testnet RPCs)
contract ForkedTestnetTest is Test {
    IERC20 constant BASE_USDC = IERC20(0x036CbD53842c5426634e7929541eC2318f3dCF7e); // Base Sepolia USDC
    IERC20 constant ARC_USDC = IERC20(0x3600000000000000000000000000000000000000); // Arc predeploy USDC

    uint256 srcFork;
    uint256 arcFork;

    ArcdeskEscrow payEsc; // same contract, payment leg on Base Sepolia
    ArcdeskEscrow liqEsc; // same contract, liquidity leg on Arc

    address maker = makeAddr("maker");
    address taker = makeAddr("taker");
    address takerArc = makeAddr("takerArc");
    address treasury = makeAddr("treasury");
    address keeper = makeAddr("keeper");

    bytes32 secret = keccak256("fork-secret");
    bytes32 hashlock = keccak256(abi.encodePacked(keccak256("fork-secret")));
    bytes32 constant OFFER = keccak256("fork-offer");
    bytes32 constant ORDER = keccak256("fork-order");

    // 100 USDC on Arc, 8% premium -> 108 proceeds, 2% desk fee -> 2.16
    uint256 constant ARC_AMT = 100e6; // Arc testnet USDC is 6dp
    uint256 constant PROCEEDS = 108e6;
    uint256 constant FEE = 216e4;

    function setUp() public {
        string memory srcRpc = vm.envOr("SOURCE_FORK_RPC", string("https://sepolia.base.org"));
        string memory arcRpc = vm.envOr("ARC_FORK_RPC", string("https://rpc.testnet.arc.network"));
        srcFork = vm.createFork(srcRpc);
        arcFork = vm.createFork(arcRpc);

        vm.selectFork(srcFork);
        payEsc = new ArcdeskEscrow(BASE_USDC, keeper);

        vm.selectFork(arcFork);
        liqEsc = new ArcdeskEscrow(ARC_USDC, keeper);
    }

    function test_Fork_RealUsdcMetadata() public {
        vm.selectFork(srcFork);
        assertEq(block.chainid, 84532, "source is Base Sepolia");
        vm.selectFork(arcFork);
        assertEq(block.chainid, 5042002, "liquidity chain is Arc testnet");
        // Arc's USDC is the gas token and a 6dp ERC20.
        (bool ok, bytes memory out) = address(ARC_USDC).staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(ok, "arc usdc responds");
        assertEq(abi.decode(out, (uint8)), 6, "arc usdc 6dp");
    }

    /// @dev Arc's USDC balance is a 6dp view over the account's native balance (÷1e12) and
    ///      every transfer is executed by chain-level precompiles at 0x1800…0000/0001 that
    ///      do not exist inside forge's EVM. A full Arc-side transfer therefore cannot be
    ///      faithfully simulated on a fork; it is covered by the unit suite against a mock
    ///      token, by the local two-chain e2e, and must be re-verified live after deploy.
    ///      What a fork CAN prove is the deploy-time wiring, which is what this asserts.
    function test_Fork_ArcLegWiredToRealArcUsdc() public {
        vm.selectFork(arcFork);
        assertEq(address(liqEsc.usdc()), address(ARC_USDC), "escrow points at Arc USDC predeploy");
        assertEq(liqEsc.operator(), keeper, "keeper set as operator");
        assertEq(liqEsc.owner(), address(this), "deployer owns the escrow");

        // The 6dp view over native balance: fund an account and read it back through USDC.
        address probe = makeAddr("probe");
        vm.deal(probe, 250e6 * 1e12); // 250 USDC expressed in 18dp native units
        assertEq(ARC_USDC.balanceOf(probe), 250e6, "balanceOf is native / 1e12");
    }

    function test_Fork_SourceLegWiredToRealBaseUsdc() public {
        vm.selectFork(srcFork);
        assertEq(address(payEsc.usdc()), address(BASE_USDC), "escrow points at Base Sepolia USDC");
    }

    function test_Fork_TakerRefundsItselfWhenDeskStalls() public {
        vm.selectFork(srcFork);
        deal(address(BASE_USDC), taker, PROCEEDS + FEE);
        uint64 payDeadline = uint64(block.timestamp) + 30 minutes;
        vm.startPrank(taker);
        BASE_USDC.approve(address(payEsc), PROCEEDS + FEE);
        payEsc.lockPayment(ORDER, maker, treasury, PROCEEDS, FEE, hashlock, payDeadline);
        vm.stopPrank();

        // Desk never reserves. After the deadline the taker calls refund itself.
        vm.warp(payDeadline);
        payEsc.refundPayment(ORDER, taker);
        assertEq(BASE_USDC.balanceOf(taker), PROCEEDS + FEE, "taker made whole on real USDC");
    }

}
