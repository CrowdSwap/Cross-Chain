// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title EternalStorage
 * @dev This contract holds all the necessary state variables to carry out the storage of any contract.
 */
contract EternalStorage {
    mapping(bytes32 => bool) private _boolStorage;
    
    uint256[50] private __gap;

    function getBool(bytes32 key) public view returns (bool) {
        return _boolStorage[key];
    }

    function _setBool(bytes32 key, bool value) internal {
        _boolStorage[key] = value;
    }

    function _deleteBool(bytes32 key) internal {
        delete _boolStorage[key];
    }
}
