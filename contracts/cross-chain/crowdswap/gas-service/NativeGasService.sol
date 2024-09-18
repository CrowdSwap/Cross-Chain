// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "./interfaces/INativeGasService.sol";
import "../../../helpers/OwnableUpgradeable.sol";
import "../../../libraries/UniERC20Upgradeable.sol";
import "../../crowdswap/native/interfaces/INativeGateway.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/**
 * @title NativeGasService
 * @notice This contract manages gas payments and refunds for cross-chain communication on the Native network.
 * @dev The owner address of this contract should be the microservice that pays for gas.
 * @dev Users pay gas for cross-chain calls, and the gasCollector can collect accumulated fees and/or refund users if needed.
 */
contract NativeGasService is
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    INativeGasService
{
    /**
     * @dev A struct representing fee percentages based on input value in USD.
     * @member valueIn The value threshold in USD with 1e6 precision.
     * @member fee The fee percentage associated with the value threshold with 1e18 precision.
     */
    struct FeePercentage {
        uint256 valueIn;
        uint256 fee;
    }

    event FeeAdded(
        address indexed payer,
        bytes32 indexed txHash,
        uint256 indexed logIndex,
        uint256 fixedFeeAmount,
        address refundAddress
    );
    event FeePaidForContractCall(
        address indexed payer,
        string indexed destinationChain,
        string destinationAddress,
        bytes32 indexed payloadHash,
        address variableFeeToken,
        uint256 variableFeeAmount,
        uint256 fixedFeeAmount,
        address refundAddress
    );
    event Refunded(
        bytes32 indexed txHash,
        uint256 indexed logIndex,
        address payable receiver,
        address fixedFeeToken,
        uint256 fixedFeeAmount,
        address variableFeeToken,
        uint256 variableFeeAmount
    );
    event FeesCollected(
        string sourceAddress,
        address receiver,
        address[] tokens,
        uint256[] amounts
    );
    event ApproveFeeTransfered(address receiver, uint256 amount);

    event GasCollectorSet(address gasCollector);
    event FixedFeeSet(uint256 fixedFee);
    event ApproveFeeSet(uint256 approveFee);
    event FeePercentageSet(address indexed user, uint256 valueIn, uint256 fee);

    error ApproveFeeTransferFailed();
    error InsufficientApproveFee();
    error InsufficientFixedFee();
    error InsufficientGasPayment(
        address gasToken,
        uint256 required,
        uint256 provided
    );
    error InvalidAddress();
    error InvalidAmounts();
    error InvalidGasUpdates();
    error NotCollector();
    error NotApprovedByGateway();

    /**
     * @notice Modifier that ensures the caller is the designated gas collector.
     */
    modifier onlyCollector() {
        if (msg.sender != gasCollector) revert NotCollector();
        _;
    }

    address public gasCollector;
    uint256 public fixedFee; // The fixed network fee in native currency units, set to a value equivalent to x USD. This value is based on the prevailing exchange rate of the source network's coin.
    FeePercentage[] public feePercentages;

    INativeGateway public gateway;
    uint256 public approveFee; // The gas fee paid for calling `gateway.approveContractCall(...)` when a validator wants to withdraw rewards

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the NativeGasService contract.
     * @param gasCollector_ The address of the gas collector
     */

    function initialize(
        address gateway_,
        address gasCollector_,
        uint256 fixedFee_,
        uint256 approveFee_,
        FeePercentage[] memory feePercentages_
    ) public initializer {
        OwnableUpgradeable.initialize();
        PausableUpgradeable.__Pausable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        gateway = INativeGateway(gateway_);

        setGasCollector(gasCollector_);
        _setFixedFee(fixedFee_);
        _setApproveFee(approveFee_);
        _setFeePercentages(feePercentages_);
    }

    /**
     * @notice Handles payment for cross-chain contract execution fees, accommodating both a fixed network fee and a variable token fee.
     * @dev Initiates fee payment process on the source chain before triggering a gateway for remote contract execution on a specified chain.
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
    ) external payable nonReentrant {
        uint256 fixedFeeAmount_ = _handleFeePayment(
            variableFeeToken,
            variableFeeAmount
        );
        if (fixedFeeAmount_ < fixedFee) {
            revert InsufficientFixedFee();
        }

        emit FeePaidForContractCall(
            payer,
            destinationChain,
            destinationAddress,
            keccak256(payload),
            variableFeeToken,
            variableFeeAmount,
            fixedFeeAmount_,
            refundAddress
        );
    }

    /**
     * @notice Add additional fee payment for cross-chain contract execution fees, accommodating both a fixed network fee and a variable token fee.
     * @dev This function can be called on the source chain after calling the gateway to execute a remote contract.
     * @param txHash The transaction hash of the cross-chain call
     * @param logIndex The log index for the cross-chain call
     * @param refundAddress The address where refunds, if any, should be sent
     */
    function addFee(
        bytes32 txHash,
        uint256 logIndex,
        address refundAddress
    ) external payable nonReentrant {
        emit FeeAdded(msg.sender, txHash, logIndex, msg.value, refundAddress);
    }

    /**
     * @notice Allows the gasCollector to collect accumulated fees from the contract.
     * @param receiver The address to receive the collected fees
     * @param tokens Array of token addresses to be collected
     * @param amounts Array of amounts to be collected for each respective token address
     */
    function collectFees(
        address payable receiver,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external onlyCollector nonReentrant {
        if (receiver == address(0)) revert InvalidAddress();

        uint256 tokensLength = tokens.length;
        if (tokensLength != amounts.length) revert InvalidAmounts();

        for (uint256 i; i < tokensLength; i++) {
            address token = tokens[i];
            uint256 amount = amounts[i];
            if (amount == 0) revert InvalidAmounts();

            ERC20Upgradeable token_ = ERC20Upgradeable(token);
            uint256 balance = UniERC20Upgradeable.uniBalanceOf(
                token_,
                address(this)
            );
            if (amount <= balance)
                UniERC20Upgradeable.uniTransfer(token_, receiver, amount);
        }
    }

    /**
     * @notice Refunds gas payment and additional variable fees to the receiver in relation to a specific cross-chain transaction.
     * @dev Only callable by the gasCollector. Handles different tokens for fixed and variable fees.
     * @param txHash The transaction hash of the cross-chain call
     * @param logIndex The log index for the cross-chain call
     * @param receiver The address to receive the refund
     * @param fixedFeeToken The token address for the fixed fee refund
     * @param fixedFeeAmount The amount of the fixed fee to refund
     * @param variableFeeToken The token address for the variable fee refund
     * @param variableFeeAmount The amount of the variable fee to refund
     */
    function refund(
        bytes32 txHash,
        uint256 logIndex,
        address payable receiver,
        address fixedFeeToken,
        uint256 fixedFeeAmount,
        address variableFeeToken,
        uint256 variableFeeAmount
    ) external onlyCollector nonReentrant {
        if (receiver == address(0)) revert InvalidAddress();

        // Ensure different tokens can be refunded separately
        if (fixedFeeAmount > 0) {
            UniERC20Upgradeable.uniTransfer(
                ERC20Upgradeable(fixedFeeToken),
                receiver,
                fixedFeeAmount
            );
        }

        if (variableFeeAmount > 0) {
            UniERC20Upgradeable.uniTransfer(
                ERC20Upgradeable(variableFeeToken),
                receiver,
                variableFeeAmount
            );
        }

        emit Refunded(
            txHash,
            logIndex,
            receiver,
            fixedFeeToken,
            fixedFeeAmount,
            variableFeeToken,
            variableFeeAmount
        );
    }

    function version() external pure returns (string memory) {
        return "V1.0.1";
    }

    function findApplicableFeePercentage(
        uint256 value_
    ) public view whenNotPaused returns (uint256) {
        FeePercentage[] memory feePercentages_ = feePercentages;
        for (uint256 i = 0; i < feePercentages_.length; i++) {
            if (value_ < feePercentages_[i].valueIn) {
                return feePercentages_[i].fee;
            }
        }

        revert("No applicable fee percentage found.");
    }

    function setGasCollector(address gasCollector_) public onlyOwner {
        if (gasCollector_ == address(0)) revert InvalidAddress();

        gasCollector = gasCollector_;
        emit GasCollectorSet(gasCollector_);
    }

    function setFixedFee(uint256 fixedFee_) external whenPaused onlyOwner {
        _setFixedFee(fixedFee_);
    }

    function setApproveFee(uint256 approveFee_) external whenPaused onlyOwner {
        _setApproveFee(approveFee_);
    }

    function setFeePercentages(
        FeePercentage[] memory feePercentages_
    ) external whenPaused onlyOwner {
        _setFeePercentages(feePercentages_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setGateway(address gateway_) external onlyOwner {
        if (gateway_ == address(0)) revert InvalidAddress();

        gateway = INativeGateway(gateway_);
    }

    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external payable {
        bytes32 payloadHash = keccak256(payload);

        if (
            !gateway.validateContractCall(
                commandId,
                sourceChain,
                sourceAddress,
                payloadHash
            )
        ) revert NotApprovedByGateway();

        _execute(sourceAddress, payload);
    }

    function _execute(
        string calldata sourceAddress_,
        bytes calldata payload_
    ) internal whenNotPaused nonReentrant {
        if (msg.value < approveFee) {
            revert InsufficientApproveFee();
        }

        (
            address payable receiver,
            address[] memory tokens,
            uint256[] memory amounts
        ) = abi.decode(payload_, (address, address[], uint256[]));

        if (receiver == address(0)) revert InvalidAddress();

        uint256 tokensLength = tokens.length;
        if (tokensLength != amounts.length) revert InvalidAmounts();

        for (uint256 i; i < tokensLength; i++) {
            address token = tokens[i];
            uint256 amount = amounts[i];
            if (amount == 0) revert InvalidAmounts();

            ERC20Upgradeable token_ = ERC20Upgradeable(token);
            uint256 balance = UniERC20Upgradeable.uniBalanceOf(
                token_,
                address(this)
            );
            if (amount <= balance)
                UniERC20Upgradeable.uniTransfer(token_, receiver, amount);
        }

        emit FeesCollected(sourceAddress_, receiver, tokens, amounts);

        (bool success, ) = gasCollector.call{value: msg.value}("");
        if (!success) {
            revert ApproveFeeTransferFailed();
        }
        emit ApproveFeeTransfered(gasCollector, msg.value);
    }

    function _handleFeePayment(
        address variableFeeToken,
        uint256 variableFeeAmount
    ) internal returns (uint256 fixedFeeAmount_) {
        ERC20Upgradeable variableFeeToken_ = ERC20Upgradeable(variableFeeToken);
        fixedFeeAmount_ = msg.value;

        if (UniERC20Upgradeable.isETH(variableFeeToken_)) {
            if (variableFeeAmount > msg.value) {
                revert InsufficientGasPayment(
                    variableFeeToken,
                    variableFeeAmount,
                    msg.value
                );
            }
            fixedFeeAmount_ = msg.value - variableFeeAmount;
        } else {
            SafeERC20Upgradeable.safeTransferFrom(
                variableFeeToken_,
                msg.sender,
                address(this),
                variableFeeAmount
            );
        }
    }

    function _setFixedFee(uint256 fixedFee_) internal {
        fixedFee = fixedFee_;
        emit FixedFeeSet(fixedFee_);
    }

    function _setApproveFee(uint256 approveFee_) internal {
        approveFee = approveFee_;
        emit ApproveFeeSet(approveFee);
    }

    function _setFeePercentages(
        FeePercentage[] memory feePercentages_
    ) internal {
        delete feePercentages;
        uint256 lastIndex = feePercentages_.length - 1;
        for (uint256 i = 0; i < lastIndex; i++) {
            feePercentages.push(feePercentages_[i]);
            emit FeePercentageSet(
                msg.sender,
                feePercentages_[i].valueIn,
                feePercentages_[i].fee
            );
        }

        feePercentages.push(
            FeePercentage(type(uint256).max, feePercentages_[lastIndex].fee)
        );
        emit FeePercentageSet(
            msg.sender,
            type(uint256).max,
            feePercentages_[lastIndex].fee
        );
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
