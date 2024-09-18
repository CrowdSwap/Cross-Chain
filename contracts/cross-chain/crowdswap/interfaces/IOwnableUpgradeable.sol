// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IOwnableUpgradeable {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function claimOwnership() external;
}
