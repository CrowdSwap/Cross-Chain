// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ICrowdSwapGateway {
    /**********\
    |* Structs *|
    \**********/
    struct VerificationRequest {
        address addr;
        bool isVerified;
    }

    /**********\
    |* Errors *|
    \**********/

    error NotSelf();
    error InvalidAuthModule();
    error InvalidChainId();
    error InvalidCommands();
    error CallerIsNotVerified();

    /**********\
    |* Events *|
    \**********/

    event ContractCall(
        address indexed sender,
        string destinationChain,
        string destinationContractAddress,
        bytes32 indexed payloadHash,
        bytes payload
    );

    event Executed(bytes32 indexed commandId);

    event ContractCallApproved(
        bytes32 indexed commandId,
        string sourceChain,
        string sourceAddress,
        address indexed contractAddress,
        bytes32 indexed payloadHash,
        bytes32 sourceTxHash,
        uint256 sourceEventIndex
    );

    event ContractCallExecuted(bytes32 indexed commandId);

    event OperatorshipTransferred(bytes newOperatorsData);

    event VerifiedListUpdated(address caller, bool isVerified);

    /********************\
    |* Public Functions *|
    \********************/

    function callContract(
        string calldata destinationChain,
        string calldata contractAddress,
        bytes calldata payload
    ) external;

    function isContractCallApproved(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        address contractAddress,
        bytes32 payloadHash
    ) external view returns (bool);

    function validateContractCall(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes32 payloadHash
    ) external returns (bool);

    /***********\
    |* Getters *|
    \***********/

    function authModule() external view returns (address);

    function isCommandExecuted(bytes32 commandId) external view returns (bool);

    /**********************\
    |* External Functions *|
    \**********************/

    function execute(bytes calldata input) external;
}
