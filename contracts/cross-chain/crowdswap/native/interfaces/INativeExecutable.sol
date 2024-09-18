// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

interface INativeExecutable {
    error InvalidAddress();
    error NotApprovedByGateway();

    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external;
}
