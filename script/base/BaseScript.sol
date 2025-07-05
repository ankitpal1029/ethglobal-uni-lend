// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IUniversalRouter} from "universal-router/contracts/interfaces/IUniversalRouter.sol";

// import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
// import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IStateView} from "v4-periphery/src/interfaces/IStateView.sol";

/// @notice Shared configuration between scripts
contract BaseScript is Script {
    IPermit2 immutable permit2;
    IPoolManager immutable poolManager;
    IPositionManager immutable positionManager;
    IStateView immutable stateView;
    IUniversalRouter immutable universalRouter;

    // IUniswapV4Router04 immutable swapRouter;
    address immutable deployerAddress;

    /////////////////////////////////////
    // --- Configure These ---
    /////////////////////////////////////

    uint24 lpFee = 5000; // 0.50%
    int24 tickSpacing = 100;
    uint160 startingPrice = 2 ** 96; // Starting price, sqrtPriceX96; floor(sqrt(1) * 2^96)

    IERC20 token0 = IERC20(0x76f14c98d2B3d4D7e09486Ca09e5BE1B4E19182a);
    IERC20 token1 = IERC20(0xbF784Ac432D1CA21135B3ee603E11ED990D77EA4);
    IHooks constant hookContract = IHooks(0x235877899ECd2287B073d312C02D21e7F8d09040);
    /////////////////////////////////////

    Currency immutable currency0;
    Currency immutable currency1;

    constructor() {
        poolManager = IPoolManager(0xb1860D529182ac3BC1F51Fa2ABd56662b7D13f33);
        positionManager = IPositionManager(payable(0xC585E0f504613b5fBf874F21Af14c65260fB41fA));
        stateView = IStateView(0x51D394718bc09297262e368c1A481217FdEB71eb);
        permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
        universalRouter = IUniversalRouter(0x8ac7bEE993bb44dAb564Ea4bc9EA67Bf9Eb5e743);
        // swapRouter = IUniswapV4Router04(payable(0x8ac7bEE993bb44dAb564Ea4bc9EA67Bf9Eb5e743));

        deployerAddress = getDeployer();

        (currency0, currency1) = getCurrencies();

        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");

        vm.label(address(deployerAddress), "Deployer");
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(positionManager), "PositionManager");
        // vm.label(address(swapRouter), "SwapRouter");
        vm.label(address(hookContract), "HookContract");
    }

    function getCurrencies() public view returns (Currency, Currency) {
        require(address(token0) != address(token1));

        if (token0 < token1) {
            return (Currency.wrap(address(token0)), Currency.wrap(address(token1)));
        } else {
            return (Currency.wrap(address(token1)), Currency.wrap(address(token0)));
        }
    }

    function getDeployer() public returns (address) {
        address[] memory wallets = vm.getWallets();

        require(wallets.length > 0, "No wallets found");

        return wallets[0];
    }
}
