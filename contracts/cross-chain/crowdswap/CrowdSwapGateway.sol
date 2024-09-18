// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./ECDSA.sol";
import "./EternalStorage.sol";
import "./interfaces/IAuthWeighted.sol";
import "./interfaces/ICrowdSwapGateway.sol";
import "./interfaces/IOwnableUpgradeable.sol";
import "../../helpers/OwnableUpgradeable.sol";

/**
 * @title CrowdSwapGateway Contract
 * @notice This contract serves as the gateway for cross-chain contract calls.
 * It includes functions for calling contracts, and validating contract calls.
 * @dev EternalStorage is used to simplify storage for upgradability.
 */
contract CrowdSwapGateway is
    ICrowdSwapGateway,
    EternalStorage,
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{
    bytes32 internal constant PREFIX_COMMAND_EXECUTED =
        keccak256("command-executed");
    bytes32 internal constant PREFIX_CONTRACT_CALL_APPROVED =
        keccak256("contract-call-approved");

    bytes32 internal constant SELECTOR_APPROVE_CONTRACT_CALL =
        keccak256("approveContractCall");
    bytes32 internal constant SELECTOR_TRANSFER_OPERATORSHIP =
        keccak256("transferOperatorship");

    /******************\
    |* State variables *|
    \******************/
    address public authModule;
    mapping(address => bool) public isVerified;

    /******************\
    |*    Modifiers    *|
    \******************/
    /**
     * @notice Ensures that the caller of the function is the gateway contract itself.
     */
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();

        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Constructs the CrowdSwapGateway contract.
     * @param authModule_ The address of the authentication module
     */
    function initialize(address authModule_) public initializer {
        PausableUpgradeable.__Pausable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        OwnableUpgradeable.initialize();

        setAuthModule(authModule_);
    }

    /******************\
    |* Public Methods *|
    \******************/

    /**
     * @notice Calls a contract on the specified destination chain with a given payload.
     * This function is the entry point for general message passing between chains.
     * @param destinationChain The chain where the destination contract exists. A registered chain name on CrowdSwap must be used here
     * @param destinationContractAddress The address of the contract to call on the destination chain
     * @param payload The payload to be sent to the destination contract, usually representing an encoded function call with arguments
     */
    function callContract(
        string calldata destinationChain,
        string calldata destinationContractAddress,
        bytes calldata payload
    ) external {
        if (!isVerified[msg.sender]) {
            revert CallerIsNotVerified();
        }
        emit ContractCall(
            msg.sender,
            destinationChain,
            destinationContractAddress,
            keccak256(payload),
            payload
        );
    }

    /**
     * @notice Checks whether a contract call has been approved by the gateway.
     * @param commandId The gateway command ID
     * @param sourceChain The source chain of the contract call
     * @param sourceAddress The source address of the contract call
     * @param contractAddress The contract address that will be called
     * @param payloadHash The hash of the payload for that will be sent with the call
     * @return bool A boolean value indicating whether the contract call has been approved by the gateway.
     */
    function isContractCallApproved(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        address contractAddress,
        bytes32 payloadHash
    ) external view override returns (bool) {
        return
            getBool(
                _getIsContractCallApprovedKey(
                    commandId,
                    sourceChain,
                    sourceAddress,
                    contractAddress,
                    payloadHash
                )
            );
    }

    /**
     * @notice Called on the destination chain gateway by the recipient of the cross-chain contract call to validate it and only allow execution
     * if this function returns true.
     * @dev Once validated, the gateway marks the message as executed so the contract call is not executed twice.
     * @param commandId The gateway command ID
     * @param sourceChain The source chain of the contract call
     * @param sourceAddress The source address of the contract call
     * @param payloadHash The hash of the payload for that will be sent with the call
     * @return valid True if the contract call is approved, false otherwise
     */
    function validateContractCall(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes32 payloadHash
    ) external override returns (bool valid) {
        bytes32 key = _getIsContractCallApprovedKey(
            commandId,
            sourceChain,
            sourceAddress,
            msg.sender,
            payloadHash
        );
        valid = getBool(key);
        if (valid) {
            _setBool(key, false);

            emit ContractCallExecuted(commandId);
        }
    }

    function verify(VerificationRequest[] memory requests_) public onlyOwner {
        for (uint i = 0; i < requests_.length; i++) {
            address addr_ = requests_[i].addr;
            bool isVerified_ = requests_[i].isVerified;
            isVerified[addr_] = isVerified_;
            emit VerifiedListUpdated(addr_, isVerified_);
        }
    }

    /***********\
    |* Getters *|
    \***********/

    /**
     * @notice Checks whether a command with a given command ID has been executed.
     * @param commandId The command ID to check
     * @return bool True if the command has been executed, false otherwise
     */
    function isCommandExecuted(
        bytes32 commandId
    ) public view override returns (bool) {
        return getBool(_getIsCommandExecutedKey(commandId));
    }

    /************************\
    |* Ownership Functions *|
    \************************/

    function transferOwnershipOfAuthModule(address newOwner) public onlyOwner {
        IOwnableUpgradeable(authModule).transferOwnership(newOwner);
    }

    function claimOwnershipOfAuthModule() public onlyOwner {
        IOwnableUpgradeable(authModule).claimOwnership();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**********************\
    |* External Functions *|
    \**********************/

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function version() external pure returns (string memory) {
        return "V1.0";
    }

    /**
     * @notice Executes a batch of commands signed by the CrowdSwap network. There are a finite set of command types that can be executed.
     * @param input The encoded input containing the data for the batch of commands, as well as the proof that verifies the integrity of the data.
     * @dev Each command has a corresponding commandID that is guaranteed to be unique from the CrowdSwap network.
     * @dev This function allows retrying a commandID if the command initially failed to be processed.
     * @dev Ignores unknown commands or duplicate commandIDs.
     * @dev Emits an Executed event for successfully executed commands.
     */
    function execute(bytes calldata input) external override {
        (bytes memory data, bytes memory proof) = abi.decode(
            input,
            (bytes, bytes)
        );

        bytes32 messageHash = ECDSA.toEthSignedMessageHash(keccak256(data));

        // returns true for current operators
        bool allowOperatorshipTransfer = IAuthWeighted(authModule)
            .validateProof(messageHash, proof);

        uint256 chainId;
        bytes32[] memory commandIds;
        string[] memory commands;
        bytes[] memory params;

        (chainId, commandIds, commands, params) = abi.decode(
            data,
            (uint256, bytes32[], string[], bytes[])
        );

        if (chainId != block.chainid) revert InvalidChainId();

        uint256 commandsLength = commandIds.length;

        if (
            commandsLength != commands.length || commandsLength != params.length
        ) revert InvalidCommands();

        for (uint256 i; i < commandsLength; ++i) {
            bytes32 commandId = commandIds[i];

            // Ignore if duplicate commandId received
            if (isCommandExecuted(commandId)) continue;

            bytes4 commandSelector;
            bytes32 commandHash = keccak256(abi.encodePacked(commands[i]));

            if (commandHash == SELECTOR_APPROVE_CONTRACT_CALL) {
                commandSelector = CrowdSwapGateway.approveContractCall.selector;
            } else if (commandHash == SELECTOR_TRANSFER_OPERATORSHIP) {
                if (!allowOperatorshipTransfer) continue;

                allowOperatorshipTransfer = false;
                commandSelector = CrowdSwapGateway
                    .transferOperatorship
                    .selector;
            } else {
                // Ignore unknown commands
                continue;
            }

            // Prevent a re-entrancy from executing this command before it can be marked as successful.
            _setCommandExecuted(commandId, true);

            (bool success, ) = address(this).call(
                abi.encodeWithSelector(commandSelector, params[i], commandId)
            );

            if (success) emit Executed(commandId);
            else _setCommandExecuted(commandId, false);
        }
    }

    /******************\
    |* external setters *|
    \******************/

    function setAuthModule(address authModule_) public onlyOwner {
        if (authModule_.code.length == 0) revert InvalidAuthModule();

        authModule = authModule_;
    }

    /******************\
    |* Self Functions *|
    \******************/

    /**
     * @notice Approves a contract call.
     * @param params Encoded parameters including the source chain, source address, contract address, payload hash, transaction hash, and event index
     * @param commandId to associate with the approval
     */
    function approveContractCall(
        bytes calldata params,
        bytes32 commandId
    ) external onlySelf {
        (
            string memory sourceChain,
            string memory sourceAddress,
            address contractAddress,
            bytes32 payloadHash,
            bytes32 sourceTxHash,
            uint256 sourceEventIndex
        ) = abi.decode(
                params,
                (string, string, address, bytes32, bytes32, uint256)
            );

        _setContractCallApproved(
            commandId,
            sourceChain,
            sourceAddress,
            contractAddress,
            payloadHash
        );
        emit ContractCallApproved(
            commandId,
            sourceChain,
            sourceAddress,
            contractAddress,
            payloadHash,
            sourceTxHash,
            sourceEventIndex
        );
    }

    /**
     * @notice Transfers operatorship with the provided data by calling the transferOperatorship function on the auth module.
     * @param newOperatorsData Encoded data for the new operators
     */
    function transferOperatorship(
        bytes calldata newOperatorsData,
        bytes32
    ) external onlySelf {
        emit OperatorshipTransferred(newOperatorsData);

        IAuthWeighted(authModule).transferOperatorship(newOperatorsData);
    }

    /********************\
    |* Internal Methods *|
    \********************/

    /********************\
    |* Pure Key Getters *|
    \********************/

    function _getIsCommandExecutedKey(
        bytes32 commandId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PREFIX_COMMAND_EXECUTED, commandId));
    }

    function _getIsContractCallApprovedKey(
        bytes32 commandId,
        string memory sourceChain,
        string memory sourceAddress,
        address contractAddress,
        bytes32 payloadHash
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    PREFIX_CONTRACT_CALL_APPROVED,
                    commandId,
                    sourceChain,
                    sourceAddress,
                    contractAddress,
                    payloadHash
                )
            );
    }

    /********************\
    |* Internal Getters *|
    \********************/

    /********************\
    |* Internal Setters *|
    \********************/

    function _setCommandExecuted(bytes32 commandId, bool executed) internal {
        _setBool(_getIsCommandExecutedKey(commandId), executed);
    }

    function _setContractCallApproved(
        bytes32 commandId,
        string memory sourceChain,
        string memory sourceAddress,
        address contractAddress,
        bytes32 payloadHash
    ) internal {
        _setBool(
            _getIsContractCallApprovedKey(
                commandId,
                sourceChain,
                sourceAddress,
                contractAddress,
                payloadHash
            ),
            true
        );
    }
}
