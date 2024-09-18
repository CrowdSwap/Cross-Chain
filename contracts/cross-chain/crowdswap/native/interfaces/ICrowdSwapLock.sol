// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

interface ICrowdSwapLock {
    function unlock(address _receiver, uint256 _amount) external;
}
