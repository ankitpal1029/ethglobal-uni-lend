// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {LendingHook} from "../src/LendingHook.sol";

// import {Counter} from "../src/Counter.sol";

/// @notice Mines the address and deploys the Counter.sol Hook contract
contract DeployHookScript is BaseScript {
    function run() public {
        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        // Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        //     | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(
            poolManager,
            0xAC5092A5c7302693a8e39643339109d21DBad723, // personal wallet is owner
            "Yangit Lend",
            "YL",
            90,
            80,
            address(permit2)
        );
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(LendingHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.startBroadcast();
        LendingHook lendingHook = new LendingHook{salt: salt}(
            poolManager,
            0xAC5092A5c7302693a8e39643339109d21DBad723, // personal wallet is owner
            "Yangit Lend",
            "YL",
            90,
            80,
            address(permit2)
        );
        vm.stopBroadcast();
        console.log("lendingHook", address(lendingHook));
        console.log("hookAddress", hookAddress);

        require(address(lendingHook) == hookAddress, "DeployHookScript: Hook Address Mismatch");
    }
}
