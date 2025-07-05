// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {MockChainLink, IChainLink} from "../test/utils/MockOracle.sol";
import {ILending} from "../src/interfaces/ILending.sol";

contract DeployAndSetOracle is BaseScript {
    using CurrencyLibrary for Currency;

    function run() external {
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        vm.startBroadcast();

        IChainLink mockChainLink = new MockChainLink();

        ILending(address(hookContract)).setOracle(poolKey.toId(), address(mockChainLink), 5000); // 50%

        vm.stopBroadcast();
    }
}
