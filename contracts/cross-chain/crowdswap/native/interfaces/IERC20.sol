// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

interface IERC20 {
    function mint(address to, uint256 amount) external;

    function burnFrom(address account, uint256 amount) external;

    function decimals() external view returns (uint8);
}
