// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IChainLink {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);

    function setPrice(int256) external;
}

contract MockChainLink is IChainLink {
    int256 price = 99993000;

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, 0, 0, 0);
    }

    function decimals() external view returns (uint8) {
        return (8);
    }

    function setPrice(int256 newPrice) public {
        price = newPrice;
    }
}
