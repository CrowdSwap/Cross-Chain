// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

interface ICrowdSwapPriceFeed {
    function getPrice(address tokenAddress_) external view returns (uint256);
}
