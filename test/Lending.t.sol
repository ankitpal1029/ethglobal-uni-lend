// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {LendingHook} from "../src/LendingHook.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {IERC721Receiver} from "../src/interfaces/IERC721Receiver.sol";
import {RatioTickMath} from "../src/lib/RatioTickMath.sol";
import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {Variables} from "../src/Variables.sol";
import {MockChainLink, IChainLink} from "./utils/MockOracle.sol";

contract LendingHookTest is Test, GasSnapshot, Fixtures, Variables {
    // use libs
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    LendingHook hook;
    PoolId poolId;
    IChainLink mockChainLink;

    address constant user1 = 0x8E1c4e0a7e85b2490f6d811824515D6FAD3115A6;
    address constant user2 = 0x1A752656D698c48f3C0eB960c9eBCc814bb86F26;
    address constant user3 = 0xF0E17D67776FcdC524b80572dd6e3cf654A63E70;
    address constant owner = 0xAC5092A5c7302693a8e39643339109d21DBad723;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    // Currency currency0;
    // Currency currency1;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(
            manager, // _poolManager
            address(this), // _owner (set to test contract for testing)); //Add all the necessary constructor arguments from the hook
            "Yangit Lend",
            "YL",
            90,
            80
        );
        deployCodeTo("LendingHook.sol:LendingHook", constructorArgs, flags);
        hook = LendingHook(flags);
        console.log("LendingHook address:", address(hook));
        console.log("Currency0(WETH):", Currency.unwrap(currency0));
        console.log("Currency1(USDC):", Currency.unwrap(currency1));

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        mockChainLink = new MockChainLink();
        hook.setOracle(poolId, address(mockChainLink), 5000);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 40e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );

        // Supply currency 1 to lending contract
        uint256 earnAmt = 100e18;
        IERC20(Currency.unwrap(currency1)).approve(address(hook), earnAmt);
        hook.earn(key, earnAmt, address(this));

        (int256 liqLimit,) = RatioTickMath.getTickAtRatio((95 * RatioTickMath.ZERO_TICK_SCALED_RATIO) / 100);
        (int256 liqThresh,) = RatioTickMath.getTickAtRatio((90 * RatioTickMath.ZERO_TICK_SCALED_RATIO) / 100);

        console.log("Liquidation limit:", liqLimit);
        console.log("liquidation threshold:", liqThresh);

        // Supply currency 0 to test users
        IERC20(Currency.unwrap(currency0)).transfer(address(user1), earnAmt);
        IERC20(Currency.unwrap(currency0)).transfer(address(user2), earnAmt);
    }

    function testSupplyAndBorrow() public {
        IERC20(Currency.unwrap(currency0)).approve(address(hook), 1e18);

        uint256 _nftId = 1;
        uint256 _supplyAmt = 1e18;
        uint256 _borrowAmt = 0.5e18;

        uint256 currency0BalBefore = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        hook.supply(_nftId, key, _supplyAmt);
        uint256 currency0BalAfter = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        assertEq(currency0BalBefore - _supplyAmt, currency0BalAfter);

        uint256 currency1BalBefore = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        hook.borrow(_nftId, key, _borrowAmt);
        uint256 currency1BalAfter = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        assertEq(currency1BalAfter, currency1BalBefore + _borrowAmt);
    }

    function testLiquidation() public {
        console.log("################### start testLiquidation ########################");
        uint256 _user1_nftId = 1;
        uint256 _user1_supplyAmt = 1e18;
        uint256 _user1_borrowAmt = 0.8e18;

        uint256 _user2_nftId = 2;

        PoolId keyId_ = key.toId();

        vm.startPrank(user1);
        IERC20(Currency.unwrap(key.currency0)).approve(address(hook), 2e18);
        hook.supply(_user1_nftId, key, _user1_supplyAmt);
        hook.borrow(_user1_nftId, key, _user1_borrowAmt); // 0.8 is the ratio of this position
        LatestPositionData memory _user1_position = hook.fetchPosition(_user1_nftId, keyId_);
        console.log("borrowedAmt", _user1_position.borrowedAmt);
        console.log("collateralAmt", _user1_position.collateralAmt);
        vm.stopPrank();

        (, int24 _tickPre,,) = manager.getSlot0(keyId_);
        console.log("tick before liquidation swap", TickMath.getSqrtPriceAtTick(_tickPre));

        // do a big swap to change the price massively so that user gets liquidated
        bool zeroForOne = true;
        IERC20(Currency.unwrap(key.currency0)).transfer(address(hook), 39e18);
        int256 amountSpecified = -39e18; // negative number indicates exact input swap!
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        (, int24 _tickPost,,) = manager.getSlot0(keyId_);
        console.log("tick after liquidation swap", TickMath.getSqrtPriceAtTick(_tickPost));

        LatestPositionData memory _latestPositionData = hook.fetchPosition(_user1_nftId, keyId_);
        assertEq(_latestPositionData.isFullyLiquidated, true);
        console.log("################### end testLiquidation ########################");
    }

    function testSupplyAfterBorrow() public {
        console.log("################### start testSupplyAfterBorrow ########################");
        uint256 _user1_nftId = 1;
        uint256 _user1_supplyAmt = 1e18;
        uint256 _user1_borrowAmt = 0.8e18;

        uint256 _user2_nftId = 2;

        PoolId keyId_ = key.toId();

        vm.startPrank(user1);
        IERC20(Currency.unwrap(key.currency0)).approve(address(hook), 2e18);
        hook.supply(_user1_nftId, key, _user1_supplyAmt);
        hook.borrow(_user1_nftId, key, _user1_borrowAmt); // 0.8 is the ratio of this position
        LatestPositionData memory _user1_position = hook.fetchPosition(_user1_nftId, keyId_);
        console.log("old borrowedAmt", _user1_position.borrowedAmt);
        console.log("old collateralAmt", _user1_position.collateralAmt);
        hook.supply(_user1_nftId, key, _user1_supplyAmt);
        vm.stopPrank();

        LatestPositionData memory _latestPositionData = hook.fetchPosition(_user1_nftId, keyId_);
        console.log("new borrowed amt", _latestPositionData.borrowedAmt);
        console.log("new collateral amt", _latestPositionData.collateralAmt);

        console.log("################### end testSupplyAfterBorrow ########################");
    }

    function testOracleBackStop() public {
        console.log("################### start testOracleBackStop ########################");
        uint256 _user1_nftId = 1;
        uint256 _user1_supplyAmt = 1e18;
        uint256 _user1_borrowAmt = 0.8e18;

        uint256 _user2_nftId = 2;

        PoolId keyId_ = key.toId();
        hook.setOracle(keyId_, address(mockChainLink), 10);

        vm.startPrank(user1);
        IERC20(Currency.unwrap(key.currency0)).approve(address(hook), 2e18);
        hook.supply(_user1_nftId, key, _user1_supplyAmt);
        hook.borrow(_user1_nftId, key, _user1_borrowAmt); // 0.8 is the ratio of this position
        LatestPositionData memory _user1_position = hook.fetchPosition(_user1_nftId, keyId_);
        console.log("borrowedAmt", _user1_position.borrowedAmt);
        console.log("collateralAmt", _user1_position.collateralAmt);
        vm.stopPrank();

        (, int24 _tickPre,,) = manager.getSlot0(keyId_);
        console.log("tick before liquidation swap", TickMath.getSqrtPriceAtTick(_tickPre));

        // do a big swap to change the price massively so that user gets liquidated
        bool zeroForOne = true;
        IERC20(Currency.unwrap(key.currency0)).transfer(address(hook), 39e18);
        int256 amountSpecified = -39e18; // negative number indicates exact input swap!
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        (, int24 _tickPost,,) = manager.getSlot0(keyId_);
        console.log("tick after liquidation swap", TickMath.getSqrtPriceAtTick(_tickPost));

        LatestPositionData memory _latestPositionData = hook.fetchPosition(_user1_nftId, keyId_);
        // position should not get liquidated due to backstop
        assertEq(_latestPositionData.isFullyLiquidated, false);
        console.log("################### end testOracleBackStop ########################");
    }

    function onERC721Received(address operator, address, /*from*/ uint256, /*tokenId*/ bytes memory /*data*/ )
        external
        view
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}
