// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

abstract contract Events {
    event LogBorrow();
    event LogSupply();
    event LogWithdraw();
    event LogRepay();
    event LogLiquidation();
    event LogTopMostTickModified(PoolId keyId, int256 oldTopMostTick, int256 updatedTopMostTick);

    error AccountLiquidatedNoNewCollateral();
}
