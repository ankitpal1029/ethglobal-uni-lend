// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Mines the address and deploys the Counter.sol Hook contract
contract DeployHookScript is Script {
    function run() public {
        vm.startBroadcast();

        MockERC20 token0 = new MockERC20("Token1", "T1", 1000000000e18);

        MockERC20 token1 = new MockERC20("Token2", "T2", 1000000000e18);

        vm.stopBroadcast();
        console.log("token0:", address(token0));
        console.log("token1:", address(token1));
    }
}
