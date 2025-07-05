// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";
import {Variables} from "../Variables.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

abstract contract Helpers is Variables {
    function _updateTickHasDebt(PoolId _id, int256 _tick, bool _addOrRemove) internal {
        unchecked {
            int256 mapId_ = _tick < 0 ? ((_tick + 1) / 256) - 1 : _tick / 256;

            // in case of removing:
            // (tick == 255) tickHasDebt[mapId_] - 1 << 255
            // (tick == 0) tickHasDebt[mapId_] - 1 << 0
            // (tick == -1) tickHasDebt[mapId_] - 1 << 255
            // (tick == -256) tickHasDebt[mapId_] - 1 << 0
            // in case of adding:
            // (tick == 255) tickHasDebt[mapId_] - 1 << 255
            // (tick == 0) tickHasDebt[mapId_] - 1 << 0
            // (tick == -1) tickHasDebt[mapId_] - 1 << 255
            // (tick == -256) tickHasDebt[mapId_] - 1 << 0
            uint256 position_ = uint256(_tick - (mapId_ * 256));

            tickHasDebt[_id][mapId_] = _addOrRemove
                ? tickHasDebt[_id][mapId_] | (1 << position_)
                : tickHasDebt[_id][mapId_] & ~(1 << position_);
        }
    }
}
