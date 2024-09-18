// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

interface IUniswapV2Pair {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (uint256 reserve0, uint256 reserve1, uint32 blockTimestampLast);

    function swapFee() external view returns (uint8);
}
