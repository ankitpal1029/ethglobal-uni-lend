// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";
import {BaseScript} from "./base/BaseScript.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IUniversalRouter} from "universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "universal-router/contracts/libraries/Commands.sol";

// DOESN'T WORK
contract Swap is BaseScript {
    uint256 constant V4_SWAP = 0x10;

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        uint256 amountIn = 1 * 10 ** 10;
        uint256 amountOutMinimum = 0; // Adjust based on price oracle
        uint256 deadline = block.timestamp + 20 minutes;
        vm.startBroadcast();

        token0.approve(address(permit2), amountIn);
        permit2.approve(address(token0), address(universalRouter), uint160(amountIn), uint48(deadline));

        // Encode V4_SWAP_EXACT_IN command (0x04)
        // bytes memory commands = abi.encodePacked(bytes1(0x04));
        // bytes memory commands = abi.encodePacked(Commands.V3_SWAP_EXACT_IN);
        bytes memory commands = abi.encodePacked(bytes1(0x10));
        // 0x10

        // Encode swap inputs
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            deployer, // Recipient
            amountIn, // Input amount
            amountOutMinimum, // Minimum output
            poolKey, // PoolKey
            true // Payer is sender
        );

        uint256 token1BalBefore = token1.balanceOf(deployer);
        console.log("Token1 bal before:", token1BalBefore);

        // Execute swap
        universalRouter.execute(commands, inputs, deadline);

        uint256 token1BalAfter = token1.balanceOf(deployer);
        console.log("Swap completed. token1 received:", token1BalAfter);
        vm.stopBroadcast();
    }
}
