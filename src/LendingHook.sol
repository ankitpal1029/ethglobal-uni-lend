// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ILending} from "./interfaces/ILending.sol";
import {ERC721} from "v4-periphery/lib/permit2/lib/solmate/src/tokens/ERC721.sol";
import {Variables} from "./Variables.sol";
import {RatioTickMath} from "./lib/RatioTickMath.sol";
import {Helpers} from "./lib/Helpers.sol";
import {Events} from "./lib/Events.sol";
import {BigMathMinified} from "./lib/bigMathMinified.sol";

// TODO: figure out how interest calcs would work, mostly just do it lazy updates
// if user tries to withdraw etc it will play a role
interface IChainLink {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

// TODO: figure out the earn %ge also for users and payouts
contract LendingHook is BaseHook, ILending, ERC721, Variables, Helpers, Events {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using BigMathMinified for uint256;

    enum PositionStatus {
        INACTIVE,
        ACTIVE,
        LIQUIDATING
    }

    address owner;

    uint256 public constant LIQUIDATION_THRESHOLD = 9000; // 90% threshold
    uint256 public constant LIQUIDATION_MAX_LIMIT = 9500; // 95% max limit
    int256 public constant ADJUSTMENT_CONSTANT_X96 = 5285573645188862003549483022; // log 1.0015 (1.0001) * 2^96

    modifier onlyOwner() {
        require(msg.sender == owner, "UNAUTHORISED");
        _;
    }

    constructor(
        IPoolManager _poolManager,
        address _owner,
        string memory _nftName,
        string memory _nftSymbol,
        uint256 _liquidationLimit,
        uint256 _liquidationThreshold
    ) BaseHook(_poolManager) ERC721(_nftName, _nftSymbol) {
        owner = _owner;
        poolManager = _poolManager;
        liquidationLimit = _liquidationLimit;
        liquidationThreshold = _liquidationThreshold;
    }

    function supply(uint256 _nftId, PoolKey calldata _key, uint256 _amt) external {}
    function borrow(uint256 _nftId, PoolKey calldata _key, uint256 _amt) external {}
    function repay() external {}
    function withdraw() external {}
    function earn(PoolKey calldata _key, uint256 _amt, address _receiver) external {}

    /**
     * @notice Define which hooks are implemented
     * @return Hooks.Permissions configuration
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // Track supported pools
            beforeAddLiquidity: false,
            afterAddLiquidity: false, // Track LP positions
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false, // Update LP positions
            beforeSwap: false, // Apply inverse range orders & check position health
            afterSwap: true, // Update positions after price changes
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "yangit-lend.com";
    }
}
