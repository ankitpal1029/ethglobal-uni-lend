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
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {ISignatureTransfer} from "universal-router/permit2/src/interfaces/ISignatureTransfer.sol";

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
        uint256 _liquidationThreshold,
        address _permit2
    ) BaseHook(_poolManager) ERC721(_nftName, _nftSymbol) {
        owner = _owner;
        poolManager = _poolManager;
        liquidationLimit = _liquidationLimit;
        liquidationThreshold = _liquidationThreshold;
        permit2 = _permit2;
    }

    function getPrice(PoolId _keyId) public view returns (int256 priceX96) {
        require(oracleAddress[_keyId] != address(0), "Oracle Not Defined");
        IChainLink oracle = IChainLink(oracleAddress[_keyId]);
        (
            /* uint80 roundId */
            ,
            int256 answer,
            /*uint256 startedAt*/
            ,
            /*uint256 updatedAt*/
            ,
            /*uint80 answeredInRound*/
        ) = oracle.latestRoundData();
        uint8 decimals = oracle.decimals();

        priceX96 = (answer << 96) / int256(10 ** decimals);
    }

    function setOracle(PoolId _keyId, address _oracle, uint256 _maxDeviationFromOracle) public onlyOwner {
        // oracleAddress[_keyId] = Oracle({oracle: _oracle, maxDeviationFromOracle: _maxDeviationFromOracle});
        oracleAddress[_keyId] = _oracle;
        maxDeviation[_keyId] = _maxDeviationFromOracle;
    }

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

    function _afterInitialize(address, PoolKey calldata _key, uint160, int24 _tick)
        internal
        override
        onlyPoolManager
        returns (bytes4)
    {
        lastTicks[_key.toId()] = _tick;
        initialPrice_X96 =
            (uint256(TickMath.getSqrtPriceAtTick(_tick)) * uint256(TickMath.getSqrtPriceAtTick(_tick))) >> 96;
        // setup lending market
        return (IHooks.afterInitialize.selector);
    }

    function _getRatioTickAdjustmentFactorX96(int24 _oldTick, int24 _newTick, int256 _oldTickAdjustmentFactor)
        public
        pure
        returns (int256)
    {
        /*
           uniswap tick math
           sqrtPriceX96 = sqrt(1.001 ^ tick) * X96
           sqrtPrice = sqrt(1.001 ^ tick)
           

           what i need:

           a = log 1.0015 (new price / old price)
           
           (1/2) * a = log 1.0015 (sqrt new price / sqrt old price )
           (1/2) * a = log 1.0015 (sqrt new price ) - log 1.0015 (sqrt old price )
           
           (1/2) * a = log 1.0015 (sqrt(1.001 ^ new tick)/ sqrt(1.001 ^ old tick))
           (1/2) * a = log 1.0015 (sqrt(1.001 ^ (new tick - old tick)))
           
           a = log 1.0015 1.001 ^ (new tick - old tick)
           a = (new tick - old tick) * log 1.0015 1.001
           a = (new tick - old tick) * 0.06671331856569614
           
           new tick adjustment factor = old tick adjustment factor - (new tick - old tick) *   0.06671331856569614

        */

        return _oldTickAdjustmentFactor - (_newTick - _oldTick) * ADJUSTMENT_CONSTANT_X96;
    }

    function _afterSwap(address, PoolKey calldata _key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId keyId_ = _key.toId();

        (, int24 _newTick,,) = poolManager.getSlot0(keyId_);

        VaultVariablesState memory vaultVariables_ = vaultVariables[keyId_];
        {
            int256 priceX96 = getPrice(keyId_);
            int256 sqrtPrice = int256(uint256(TickMath.getSqrtPriceAtTick(_newTick)));
            // (sqrtPrice * sqrtPrice) >> 96;
            int256 uniswapPriceX96 = int256((sqrtPrice ** 2) >> 96);
            int256 diff = uniswapPriceX96 - priceX96 > 0 ? uniswapPriceX96 - priceX96 : priceX96 - uniswapPriceX96;

            console.log("values", (diff) * 100 / priceX96);
            console.log("uniswapPriceX96", uniswapPriceX96);
            console.log("priceX96", priceX96);
            console.log("percentage diff", (diff) * 100 / priceX96);

            if ((diff) * 100 / priceX96 > int256(maxDeviation[keyId_])) {
                // update last tick anyways since it's keeping track of history
                int256 _adjustmentFactorX96 =
                    _getRatioTickAdjustmentFactorX96(lastTicks[keyId_], _newTick, vaultVariables_.tickAdjustmentFactor);
                vaultVariables[keyId_].tickAdjustmentFactor = _adjustmentFactorX96;
                lastTicks[keyId_] = _newTick;

                // if deviation breached return from hook
                return (IHooks.afterSwap.selector, 0);
            }
        }

        // calculate new adjustment factor, will be used to figure out liquidateable positions using tickHasDebt
        int256 _adjustedLiqLimit;
        // calculate adjusted liquidation limit
        {
            int256 _adjustmentFactorX96 =
                _getRatioTickAdjustmentFactorX96(lastTicks[keyId_], _newTick, vaultVariables_.tickAdjustmentFactor);
            vaultVariables[keyId_].tickAdjustmentFactor = _adjustmentFactorX96;
            lastTicks[keyId_] = _newTick;
            (int256 _liqLimit,) =
                RatioTickMath.getTickAtRatio((liquidationLimit * RatioTickMath.ZERO_TICK_SCALED_RATIO) / 100);

            _adjustedLiqLimit = _liqLimit - _adjustmentFactorX96 / ADJUSTMENT_CONSTANT_X96;
        }

        // check if liquidateable
        {
            uint256 collateralAbsorbed = 0;
            {
                int256 currentMapId = vaultVariables_.topMostTick < 0
                    ? ((vaultVariables_.topMostTick + 1) / 256) - 1
                    : vaultVariables_.topMostTick / 256;

                uint256 currentTickHasDebt = tickHasDebt[keyId_][currentMapId];

                int256 nextTick_ = RatioTickMath.MAX_TICK;

                // set tickHasDebt words to 0 where it gets liquidated
                // TODO: do the branch stuff so that user will know they are liquidated
                while (true) {
                    if (currentTickHasDebt > 0) {
                        uint256 mostSigBit = currentTickHasDebt.mostSignificantBit();
                        nextTick_ = currentMapId * 256 + int256(mostSigBit) - 1;

                        while (nextTick_ > _adjustedLiqLimit) {
                            TickData memory temp = tickData[keyId_][nextTick_];

                            collateralAbsorbed +=
                                (temp.rawDebt * initialPrice_X96 / RatioTickMath.getRatioAtTick(nextTick_));
                            tickData[keyId_][nextTick_] =
                                TickData({isLiquidated: true, totalIds: temp.totalIds, rawDebt: 0});

                            uint256 temp3 = 257 - mostSigBit;
                            currentTickHasDebt = (currentTickHasDebt << temp3) >> temp3;
                            if (currentTickHasDebt == 0) break;

                            mostSigBit = currentTickHasDebt.mostSignificantBit();
                            nextTick_ = currentMapId * 256 + int256(mostSigBit) - 1;
                        }
                        tickHasDebt[keyId_][currentMapId] = currentTickHasDebt;
                    }

                    if (nextTick_ <= _adjustedLiqLimit) {
                        break;
                    }

                    if (currentMapId < -129) {
                        nextTick_ = type(int256).min;
                        break;
                    }

                    // Fetching next tickHasDebt by decreasing currentMapId first
                    currentTickHasDebt = tickHasDebt[keyId_][--currentMapId];
                }
            }

            {
                if (collateralAbsorbed > 0) {
                    _handleSwap(
                        _key,
                        SwapParams({
                            zeroForOne: true,
                            amountSpecified: int256(collateralAbsorbed),
                            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                        })
                    );
                }
            }
        }

        return (IHooks.afterSwap.selector, 0);
    }

    function _getTickLower(int24 actualTick, int24 tickSpacing) public pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;
        if (actualTick < 0 && (actualTick % tickSpacing) != 0) {
            intervals--;
        }
        return intervals * tickSpacing;
    }

    function _handleSwap(PoolKey calldata _key, SwapParams memory _params) internal returns (BalanceDelta) {
        // conducting the swap inside the pool manager
        BalanceDelta delta = poolManager.swap(_key, _params, "");
        // if swap is zeroForOne
        // send token0 to poolManager , receive token1 from poolManager
        if (_params.zeroForOne) {
            // negative value -> token is transferred from user's wallet

            if (delta.amount0() < 0) {
                // settle it with poolManager
                _settle(_key.currency0, uint128(-delta.amount0()));
            }

            // positive value -> token is transfered from poolManager

            if (delta.amount1() > 0) {
                // take the token from poolManager
                _take(_key.currency1, uint128(delta.amount1()));
            }
        } else {
            // negative value -> token is transferred from user's wallet

            if (delta.amount1() < 0) {
                // settle it with poolManager
                _settle(_key.currency1, uint128(delta.amount1()));
            }

            // positive value -> token is transfered from poolManager

            if (delta.amount0() > 0) {
                // take the token from poolManager
                _take(_key.currency0, uint128(delta.amount0()));
            }
        }

        return delta;
    }

    function _settle(Currency _currency, uint128 _amount) internal {
        poolManager.sync(_currency);
        // transfer the toke to poolManager
        _currency.transfer(address(poolManager), _amount);
        // notify the poolManager
        poolManager.settle();
    }

    function _take(Currency _currency, uint128 _amount) internal {
        poolManager.take(_currency, address(this), _amount);
    }

    // function setLending(address _lender) public onlyOwner {
    //     lending = Lending(_lender);
    // }

    function getHookData(address _user) public pure returns (bytes memory) {
        return abi.encode(_user);
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "yangit-lend.com";
    }

    function supply(
        ISignatureTransfer.PermitTransferFrom memory permitTransferFrom,
        ISignatureTransfer.SignatureTransferDetails calldata transferDetails,
        bytes calldata signature,
        uint256 _nftId,
        PoolKey calldata _key,
        uint256 _amt
    ) external {
        // check if that nftId exists if not create nft and give it to msg.sender

        permit2.permitTransferFrom(permitTransferFrom, transferDetails, msg.sender, signature);
        // IERC20(Currency.unwrap(_key.currency0)).transferFrom(msg.sender, address(this), _amt);

        PoolId _keyId = _key.toId();

        {
            // case for accounting for existing liquidations
            if (fetchPosition(_nftId, _keyId).isFullyLiquidated) {
                positionData[_keyId][_nftId] =
                    Position({isInitialized: true, isSupply: true, userTick: 0, userTickId: 0, supplyAmount: _amt});
                return;
            }
        }

        {
            Position memory _positionInfo = positionData[_keyId][_nftId];
            if (_positionInfo.isInitialized) {
                if (_positionInfo.isSupply) {
                    positionData[_keyId][_nftId] = Position({
                        isInitialized: true,
                        isSupply: _positionInfo.isSupply,
                        userTick: 0,
                        userTickId: _positionInfo.userTickId,
                        supplyAmount: _positionInfo.supplyAmount + _amt
                    });
                } else {
                    VaultVariablesState memory vaultVariables_ = vaultVariables[_keyId];

                    uint256 _debt =
                        _positionInfo.supplyAmount * RatioTickMath.getRatioAtTick(_positionInfo.userTick) >> 96;
                    uint256 _newRatioX96 = (_debt * TickMath.getSqrtPriceAtTick(lastTicks[_keyId]))
                        / (_positionInfo.supplyAmount + _amt)
                        * (TickMath.getSqrtPriceAtTick(lastTicks[_keyId]) / RatioTickMath.ZERO_TICK_SCALED_RATIO);
                    (int256 _newRatioTick,) = RatioTickMath.getTickAtRatio(_newRatioX96);

                    TickData memory _tickData = tickData[_keyId][_newRatioTick];

                    // remove old tick from tickHasDebt
                    _updateTickHasDebt(
                        _keyId,
                        _positionInfo.userTick + vaultVariables_.tickAdjustmentFactor / ADJUSTMENT_CONSTANT_X96,
                        false
                    );
                    // add new tick to tickHasDebt
                    _updateTickHasDebt(
                        _keyId, _newRatioTick + vaultVariables_.tickAdjustmentFactor / ADJUSTMENT_CONSTANT_X96, true
                    );

                    if (_tickData.isLiquidated) {
                        tickId[_keyId][_newRatioTick][_tickData.totalIds] = TickId({isFullyLiquidated: true});
                        // new tick was liquidated at some point so move it to tickId
                    }
                    tickData[_keyId][_newRatioTick] = TickData({
                        isLiquidated: false,
                        totalIds: _tickData.totalIds + 1,
                        rawDebt: _tickData.rawDebt + _debt
                    });
                    positionData[_keyId][_nftId] = Position({
                        isInitialized: true,
                        isSupply: _positionInfo.isSupply,
                        userTick: _newRatioTick,
                        userTickId: _tickData.totalIds + 1,
                        supplyAmount: _positionInfo.supplyAmount + _amt
                    });
                }
            } else {
                positionData[_keyId][_nftId] =
                    Position({isInitialized: true, isSupply: true, userTick: 0, userTickId: 0, supplyAmount: _amt});

                _safeMint(msg.sender, _nftId);
            }
        }
    }

    function borrow(uint256 _nftId, PoolKey calldata _key, uint256 _amt) external {
        // check if nft is owned by msg.sender
        require(ownerOf(_nftId) == msg.sender, "invalid owner");

        Position memory _existingPosition = positionData[_key.toId()][_nftId];

        PoolId keyId_ = _key.toId();

        if (_existingPosition.isSupply) {
            VaultVariablesState memory vaultVariables_ = vaultVariables[keyId_];

            // RatioTickMath.ZERO_TICK_SCALED_RATIO
            uint256 ratioX96 = (_amt * TickMath.getSqrtPriceAtTick(lastTicks[keyId_]))
                / (_existingPosition.supplyAmount)
                * (TickMath.getSqrtPriceAtTick(lastTicks[keyId_]) / RatioTickMath.ZERO_TICK_SCALED_RATIO);
            (int256 tick_,) = RatioTickMath.getTickAtRatio(ratioX96);
            int256 adjustedTick_ = tick_ + vaultVariables_.tickAdjustmentFactor / ADJUSTMENT_CONSTANT_X96;

            _checkAndUpdateTopTick(adjustedTick_, vaultVariables_.topMostTick, keyId_);

            // TODO: check if the ratio is within limits?
            // max ratio 0.95
            // threshold ratio 0.9

            TickData memory _tickData = tickData[keyId_][tick_];

            tickData[keyId_][adjustedTick_] = TickData({
                isLiquidated: _tickData.isLiquidated,
                totalIds: _tickData.totalIds + 1,
                rawDebt: _tickData.rawDebt + _amt
            });
            positionData[keyId_][_nftId] = Position({
                isInitialized: true,
                isSupply: false,
                userTick: tick_,
                userTickId: _tickData.totalIds + 1,
                supplyAmount: _existingPosition.supplyAmount
            });
            _updateTickHasDebt(keyId_, adjustedTick_, true);
        } else {
            TickData memory _tickData = tickData[keyId_][_existingPosition.userTick];

            if (fetchPosition(_nftId, keyId_).isFullyLiquidated) {
                revert AccountLiquidatedNoNewCollateral();
            }
            // TODO: check if the new ratio is within limits? if not liquidated already
            // max ratio 0.95
            // threshold ratio 0.9

            tickData[keyId_][_existingPosition.userTick] = TickData({
                isLiquidated: _tickData.isLiquidated,
                totalIds: _tickData.totalIds - 1,
                rawDebt: _tickData.rawDebt + _amt
            });
        }

        // last step
        IERC20(Currency.unwrap(_key.currency1)).transfer(msg.sender, _amt);
    }

    function _checkAndUpdateTopTick(int256 _adjustedTickToCompare, int256 _topMostTick, PoolId _keyId) internal {
        if (_adjustedTickToCompare > _topMostTick || _topMostTick == 0) {
            // update
            vaultVariables[_keyId].topMostTick = _adjustedTickToCompare;
            emit LogTopMostTickModified(_keyId, _topMostTick, _adjustedTickToCompare);
        }
        // do nothing
    }

    function repay() external {}

    function withdraw() external {}

    function earn(
        ISignatureTransfer.PermitTransferFrom memory permitTransferFrom,
        ISignatureTransfer.SignatureTransferDetails calldata transferDetails,
        bytes calldata signature,
        PoolKey calldata _key,
        uint256 _amt,
        address _receiver
    ) external {
        // use _key to pull curreny1 funds
        // TODO: think about handling interest for this later need to figure out how to do interest logic on loans too
        // IERC20(Currency.unwrap(_key.currency1)).transferFrom(msg.sender, address(this), _amt);
        permit2.permitTransferFrom(permitTransferFrom, transferDetails, msg.sender, signature);

        liquidity[_key.toId()][_receiver].deposited += _amt;
    }

    function displayEarnPosition(PoolKey calldata _key, address _user) public view returns (Liquidity memory) {
        return liquidity[_key.toId()][_user];
    }

    function modifyVaultVariables(VaultVariablesState memory _vaultVariablesState, PoolKey calldata _key) public {
        vaultVariables[_key.toId()] = _vaultVariablesState;
    }

    function fetchPosition(uint256 _nftId, PoolId _keyId) public view returns (LatestPositionData memory) {
        // TODO: interest calculation needs to be done,etc
        Position memory _existingPosition = positionData[_keyId][_nftId];
        VaultVariablesState memory vaultVariables_ = vaultVariables[_keyId];

        console.log("debug: tick adjustment factor", vaultVariables_.tickAdjustmentFactor);

        if (
            tickData[_keyId][_existingPosition.userTick].isLiquidated
                || tickData[_keyId][_existingPosition.userTick].totalIds > _existingPosition.userTickId
                || tickId[_keyId][_existingPosition.userTick][_existingPosition.userTickId].isFullyLiquidated
        ) {
            return LatestPositionData({isFullyLiquidated: true, collateralAmt: 0, borrowedAmt: 0});
        }

        return LatestPositionData({
            isFullyLiquidated: false,
            collateralAmt: _existingPosition.supplyAmount,
            borrowedAmt: _existingPosition.supplyAmount * RatioTickMath.getRatioAtTick(_existingPosition.userTick) >> 96
        });
    }

    function absorbBadDebt(PoolKey calldata _key) external {
        PoolId keyId_ = _key.toId();
        VaultVariablesState memory vaultVariables_ = vaultVariables[keyId_];

        int24 _newTick = lastTicks[keyId_];

        {
            int256 priceX96 = getPrice(keyId_);
            int256 sqrtPrice = int256(uint256(TickMath.getSqrtPriceAtTick(_newTick)));
            // (sqrtPrice * sqrtPrice) >> 96;
            int256 uniswapPriceX96 = int256((sqrtPrice ** 2) >> 96);
            int256 diff = uniswapPriceX96 - priceX96 > 0 ? uniswapPriceX96 - priceX96 : priceX96 - uniswapPriceX96;

            console.log("values", (diff) * 100 / priceX96);
            console.log("oracle price", priceX96);
            console.log("uniswap price", uniswapPriceX96);
            console.log("maxDeviation[keyId_]", maxDeviation[keyId_]);

            if ((diff) * 100 / priceX96 > int256(maxDeviation[keyId_])) {
                // if deviation breached return
                return;
            }
        }

        int256 _adjustedLiqLimit;
        // calculate adjusted liquidation limit
        {
            int256 _adjustmentFactorX96 =
                _getRatioTickAdjustmentFactorX96(lastTicks[keyId_], _newTick, vaultVariables_.tickAdjustmentFactor);
            vaultVariables[keyId_].tickAdjustmentFactor = _adjustmentFactorX96;
            (int256 _liqLimit,) =
                RatioTickMath.getTickAtRatio((liquidationLimit * RatioTickMath.ZERO_TICK_SCALED_RATIO) / 100);

            _adjustedLiqLimit = _liqLimit - _adjustmentFactorX96 / ADJUSTMENT_CONSTANT_X96;
        }

        uint256 collateralAbsorbed = 0;
        {
            int256 currentMapId = vaultVariables_.topMostTick < 0
                ? ((vaultVariables_.topMostTick + 1) / 256) - 1
                : vaultVariables_.topMostTick / 256;

            uint256 currentTickHasDebt = tickHasDebt[keyId_][currentMapId];

            int256 nextTick_ = RatioTickMath.MAX_TICK;

            // set tickHasDebt words to 0 where it gets liquidated
            // TODO: do the branch stuff so that user will know they are liquidated
            while (true) {
                if (currentTickHasDebt > 0) {
                    uint256 mostSigBit = currentTickHasDebt.mostSignificantBit();
                    nextTick_ = currentMapId * 256 + int256(mostSigBit) - 1;

                    while (nextTick_ > _adjustedLiqLimit) {
                        TickData memory temp = tickData[keyId_][nextTick_];

                        collateralAbsorbed +=
                            (temp.rawDebt * initialPrice_X96 / RatioTickMath.getRatioAtTick(nextTick_));
                        tickData[keyId_][nextTick_] =
                            TickData({isLiquidated: true, totalIds: temp.totalIds, rawDebt: 0});

                        uint256 temp3 = 257 - mostSigBit;
                        currentTickHasDebt = (currentTickHasDebt << temp3) >> temp3;
                        if (currentTickHasDebt == 0) break;

                        mostSigBit = currentTickHasDebt.mostSignificantBit();
                        nextTick_ = currentMapId * 256 + int256(mostSigBit) - 1;
                    }
                    tickHasDebt[keyId_][currentMapId] = currentTickHasDebt;
                }

                if (nextTick_ <= _adjustedLiqLimit) {
                    break;
                }

                if (currentMapId < -129) {
                    nextTick_ = type(int256).min;
                    break;
                }

                // Fetching next tickHasDebt by decreasing currentMapId first
                currentTickHasDebt = tickHasDebt[keyId_][--currentMapId];
            }
        }

        {
            if (collateralAbsorbed > 0) {
                // swap
            }
        }
    }
}
