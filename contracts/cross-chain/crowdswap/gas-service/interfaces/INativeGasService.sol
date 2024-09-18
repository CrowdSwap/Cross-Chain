// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

interface INativeGasService {
    /**
     * @notice Handles payment for cross-chain contract execution fees, accommodating both a fixed network fee and a variable token fee.
     * @param payer The address making the payment
     * @param destinationChain The target chain where the contract call will be made
     * @param destinationAddress The target address on the destination chain
     * @param payload Data payload for the contract call
     * @param variableFeeToken Address of the ERC20 token used for the variable fee payment. It can be network coin also.
     * @param variableFeeAmount The amount of ERC20 tokens to be paid as the variable fee.
     * @param refundAddress The address where refunds, if any, should be sent
     */
    function payFee(
        address payer,
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        address variableFeeToken,
        uint256 variableFeeAmount,
        address refundAddress
    ) external payable;

    /**
     * @notice Add additional fee payment for cross-chain contract execution fees, accommodating both a fixed network fee and a variable token fee.
     * @param txHash The transaction hash of the cross-chain call
     * @param logIndex The log index for the cross-chain call
     * @param refundAddress The address where refunds, if any, should be sent
     */
    function addFee(
        bytes32 txHash,
        uint256 logIndex,
        address refundAddress
    ) external payable;

    /**
     * @notice Finds the applicable fee percentage based on the provided value in USD.
     * @param value The value in USD with 1e6 precision to determine the applicable fee percentage.
     * @return fee The fee percentage with 1e18 precision associated with the value threshold.
     */
    function findApplicableFeePercentage(
        uint256 value
    ) external view returns (uint256 fee);
}
