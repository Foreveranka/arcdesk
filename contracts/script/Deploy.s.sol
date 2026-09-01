// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArcdeskEscrow} from "../src/ArcdeskEscrow.sol";

/// @notice Deploys the one escrow contract. Run it once per chain: the source chain uses
///         the payment leg, Arc uses the liquidity leg, both from the same bytecode.
///   USDC     = the chain's USDC address
///   OPERATOR = the desk keeper allowed to reserve liquidity
contract Deploy is Script {
    function run() external {
        address usdc = vm.envAddress("USDC");
        address operator = vm.envAddress("OPERATOR");
        vm.startBroadcast();
        ArcdeskEscrow esc = new ArcdeskEscrow(IERC20(usdc), operator);
        console.log("ArcdeskEscrow:", address(esc));
        console.log("chainid:", block.chainid);
        vm.stopBroadcast();
    }
}
