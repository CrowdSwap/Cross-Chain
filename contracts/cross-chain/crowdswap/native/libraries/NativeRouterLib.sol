// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../interfaces/ICrowdSwapPriceFeed.sol";
import "../interfaces/IERC20.sol";
import "../../../../interfaces/IUniswapV2Pair.sol";
import "../../../../libraries/UniERC20Upgradeable.sol";

library NativeRouterLib {
    using UniERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256 public constant MAX_PERCENTAGE = 1e20; //100%

    /* ========== ENUMS ========== */

    /**
     * @dev Enum defining the supported actions.
     * - `BRIDGE`: Represents cross-chain bridge (0)
     * - `SWAP`: Represents cross-chain swap (1)
     * - `CANCEL`: Represents canceling the cross-chain message (2)
     */
    enum ActionType {
        BRIDGE,
        SWAP,
        CANCEL
    }

    /**
     * @dev Enum defining the status of a message in the source chain.
     * - `NOTSET`: Indicates that the message does not exist (0)
     * - `SENT`: Indicates that the message has been sent to the destination chain (1)
     * - `COMPLETED`: Indicates that the message has been completed on the destination chain (2)
     * - `CANCELED`: Indicates that the message has been canceled (3)
     */
    enum MessageStatus {
        NOTSET,
        SENT,
        COMPLETED,
        CANCELED
    }

    /* ========== STRUCTS ========== */

    /**
     * @dev Struct representing a network.
     * @member id chainId
     * @member name chainName
     */
    struct Chain {
        uint64 id;
        string name;
    }

    /**
     * @dev A struct representing subsidy percentages based on input value in USD.
     * @member valueIn The value threshold in USD with 1e6 precision.
     * @member subsidy The subsidy percentage associated with the value threshold with 1e18 precision.
     */
    struct SubsidyPercentage {
        uint256 valueIn;
        uint256 subsidy;
    }

    /**
     * @dev Struct representing a message.
     */
    struct MessageRequest {
        uint64 destinationChainId;
        uint256 gas;
        address receiver;
        bytes details;
    }

    /**
     * @dev Struct representing a unique message.
     */
    struct Message {
        ActionType actionType;
        uint64 nonce;
        uint64 sourceChainId;
        uint64 destinationChainId;
        uint256 usdValue;
        address sender;
        address receiver;
        bytes details;
    }

    /**
     * @dev Struct representing the status of a message in the source chain.
     */
    struct SentMessage {
        MessageStatus status;
        address sourceTokenAddress;
        uint256 sourceAmount;
        uint64 destinationChainId;
        address sender;
    }

    /**
     * @dev Struct representing the status of a message in the destination chain.
     */
    struct ReceivedMessage {
        MessageStatus status;
        uint64 sourceChainId;
    }

    /**
     * @dev Struct representing a bridge details.
     */
    struct BridgeDetails {
        address sourceTokenAddress;
        address destinationTokenAddress;
        uint256 sourceAmount;
        uint256 destinationAmount;
    }

    /**
     * @dev Struct representing a swap details.
     * @note Changing the order of fields affects `encodeSwapDetails` function
     */
    struct SwapDetails {
        address sourceTokenAddress;
        address destinationTokenAddress;
        address destinationPairAddress;
        uint256 sourceAmount;
        uint256 destinationAmount;
        uint256 destinationMinAmount;
        uint256 destinationCrowdAmount;
        bytes data;
    }

    struct TokenPeers {
        address sourceTokenAddress;
        uint64[] chainIdList;
        address[] destinationTokenAddressList;
    }

    /**
     * @dev Initialize parameters of BridgeRouter
     */
    struct BridgeInitializeParams {
        address gateway;
        address gasService;
        address priceFeed;
        uint64[] supportedChainIds;
        string[] supportedChainNames;
        address[] bridgingTokens;
        address[] lockingContracts;
        TokenPeers[] tokenPeers;
    }

    /**
     * @dev Initialize parameters of SwapRouter grouped into a struct to get rid of `Stack too deep` error
     */
    struct SwapInitializeParams {
        address gateway;
        address gasService;
        address priceFeed;
        address crowdAddress;
        uint64[] supportedChainIds;
        string[] supportedChainNames;
        address aggregator;
        uint256 tvlPercentage;
        SubsidyPercentage[] subsidyPercentages;
        uint256 maxSubsidy;
        address[] supportedTokens;
        bool[] isSupportedList;
    }

    struct CallNativeParams {
        NativeRouterLib.Message message;
        string destinationChain;
        uint256 fixedFeeAmount;
        address variableFeeToken;
        uint256 variableFeeAmount;
    }

    struct HandleParams {
        bytes32 messageId;
        Message message;
        string sourceChain;
        string sourceAddress;
        bytes payload;
    }

    struct ResultParams {
        bool success;
        string errorMessage;
    }

    struct ValidateAndGetAmountInParams {
        uint256 tokenXValue;
        uint256 tokenXPrice;
        uint256 tvlPercentage;
        address pairAddress;
        address tokenXAddress;
    }

    /* ========== EVENTS ========== */

    event MessageSent(
        bytes32 indexed messageId,
        uint256 sourceAmount,
        uint256 destinationAmount,
        uint256 destinationMinAmount,
        address sourceTokenAddress,
        address destinationTokenAddress,
        address sender,
        uint64 indexed destinationChainId
    );

    event MessageCompleted(
        bytes32 indexed messageId,
        uint256 destinationAmount,
        address destinationTokenAddress,
        address receiver
    );

    event MessageCanceled(bytes32 indexed messageId, string reason);

    event Sold(
        bytes32 indexed messageId,
        address sourceTokenAddress,
        uint256 sourceAmount,
        uint256 usdValue,
        address crowdAddress,
        uint256 crowdAmount,
        uint256 crowdPrice,
        address tokenXAddress,
        uint256 tokenXAmount,
        uint256 tokenXPrice
    );

    event SetTvlPercentage(
        address indexed user,
        uint256 oldPercentage,
        uint256 newPercentage
    );

    event SetPriceFeed(
        address indexed user,
        address oldPriceFeed,
        address newPriceFeed
    );

    event SetAggregator(
        address indexed user,
        address oldAggregator,
        address newAggregator
    );

    event SetSubsidyPercentage(
        address indexed user,
        uint256 valueIn,
        uint256 subsidy
    );
    event SetUsdMaxSubsidy(
        address indexed user,
        uint256 oldUsdMaxSubsidy,
        uint256 newUsdMaxSubsidy
    );

    event SetSupportedChain(address indexed user, Chain chain);

    event SetLockContract(
        address indexed user,
        address indexed token,
        address oldLockContract,
        address newLockContract
    );

    event SetTokenPeer(
        address indexed user,
        address indexed sourceTokenAddress,
        uint256 chainId,
        address oldDestinationTokenAddress,
        address newDestinationTokenAddress
    );

    event Spent(
        address indexed user,
        address indexed token,
        address receiver,
        uint256 amount
    );

    /* ========== ERRORS ========== */

    error MismatchArraysLength();
    error MismatchAmounts();
    error InvalidSourceRouterAddress();
    error InvalidChain();
    error InvalidActionType();
    error InvalidMessageStatus();
    error InvalidTokenAddress();
    error InvalidSourceTokenAddress();
    error InvalidDestinationTokenAddress();
    error InvalidDestinationAmount();
    error InvalidMsgValue();
    error InvalidDataLength();
    error InvalidCaller();
    error InvalidAddressString();

    /* ========== UTILS ========== */

    function getMessageId(
        Message memory message_
    ) internal pure returns (bytes32) {
        return keccak256(_encodeMessage(message_));
    }

    function _encodeMessage(
        Message memory message_
    ) internal pure returns (bytes memory encoded) {
        // | Bytes | Bits | Field              |
        // | ----- | ---- | ------------------ |
        // | 8     | 64   | nonce              |
        // | 8     | 64   | sourceChainId      |
        // | 8     | 64   | destinationChainId |
        // | 32    | 256  | usdValue           |
        // | 20    | 160  | sender             |
        // | 20    | 160  | receiver           |
        // | 1     | 8    | details Size       |
        // | N     | 8*N  | details            |

        encoded = abi.encodePacked(
            message_.nonce,
            message_.sourceChainId,
            message_.destinationChainId,
            message_.usdValue,
            message_.sender,
            message_.receiver,
            (uint8)(message_.details.length),
            message_.details
        );
    }

    function decodeMessage(
        bytes calldata payload_
    ) internal pure returns (Message memory message) {
        message = abi.decode(payload_, (Message));
    }

    function decodeBridgeDetails(
        bytes memory data_
    ) internal pure returns (BridgeDetails memory details) {
        details = abi.decode(data_, (BridgeDetails));
    }

    function decodeSwapDetails(
        bytes memory data_
    ) internal pure returns (SwapDetails memory) {
        SwapDetails memory _details;
        (
            _details.sourceTokenAddress,
            _details.destinationTokenAddress,
            _details.destinationPairAddress,
            _details.sourceAmount,
            _details.destinationAmount,
            _details.destinationMinAmount,
            _details.destinationCrowdAmount,
            _details.data
        ) = abi.decode(
            data_,
            (
                address,
                address,
                address,
                uint256,
                uint256,
                uint256,
                uint256,
                bytes
            )
        );
        return _details;
    }

    function _getTVLBasedOnTokenX(
        address pairAddress_,
        address tokenXAddress_
    ) internal view returns (uint256 tvl) {
        IUniswapV2Pair _pair = IUniswapV2Pair(pairAddress_);

        (uint256 _reserve0, uint256 _reserve1, ) = _pair.getReserves();

        address _address0 = _pair.token0();
        address _address1 = _pair.token1();
        if (tokenXAddress_ == _address0) {
            tvl = _reserve0;
        } else if (tokenXAddress_ == _address1) {
            tvl = _reserve1;
        }
    }

    function _getTokenX(
        address pairAddress_,
        address tokenAddress_
    ) internal view returns (address tokenXAddress) {
        IUniswapV2Pair _pair = IUniswapV2Pair(pairAddress_);

        address _address0 = _pair.token0();
        address _address1 = _pair.token1();

        if (tokenAddress_ == _address0) {
            tokenXAddress = _address1;
        } else if (tokenAddress_ == _address1) {
            tokenXAddress = _address0;
        } else {
            tokenXAddress = address(0);
        }
    }

    function _validateAndGetAmountIn(
        ValidateAndGetAmountInParams memory params_
    ) internal view returns (ResultParams memory, uint256, uint256) {
        uint256 _tokenXAmount = ((params_.tokenXValue) *
            (10 ** IERC20(params_.tokenXAddress).decimals())) /
            params_.tokenXPrice;

        // validate base on TVL
        uint256 _maxAllowedTokenXAmount = (_getTVLBasedOnTokenX(
            params_.pairAddress,
            params_.tokenXAddress
        ) * params_.tvlPercentage) / MAX_PERCENTAGE;
        if (_tokenXAmount > _maxAllowedTokenXAmount) {
            return (ResultParams(false, "TVL threshold exceeded"), 0, 0);
        }

        uint256 _amountIn = _getAmountIn(
            params_.pairAddress,
            params_.tokenXAddress,
            _tokenXAmount
        );

        return (ResultParams(true, ""), _amountIn, _tokenXAmount);
    }

    function _getAmountIn(
        address pair_,
        address tokenOut_,
        uint256 amountOut_
    ) internal view returns (uint256 amountIn) {
        IUniswapV2Pair _pair = IUniswapV2Pair(pair_);
        (uint256 _reserve0, uint256 _reserve1, ) = _pair.getReserves();

        uint256 _reserveIn;
        uint256 _reserveOut;
        if (tokenOut_ == _pair.token0()) {
            _reserveIn = _reserve1;
            _reserveOut = _reserve0;
        } else {
            _reserveIn = _reserve0;
            _reserveOut = _reserve1;
        }

        uint8 _swapFee = _pair.swapFee();
        uint256 _numerator = _reserveIn * amountOut_ * 1000;
        uint256 _denominator = (_reserveOut - amountOut_) * (1000 - _swapFee);
        amountIn = (_numerator / _denominator) + 1;
    }

    function _isValidCrowdBuy(
        uint256 usdValue_,
        uint256 tokenXPrice_,
        uint256 destinationMinAmount_,
        address tokenXAddress_,
        address destinationPairAddress_
    ) internal returns (bool, uint256, uint256) {
        uint256 _tokenXAmount = ((usdValue_) *
            (10 ** IERC20(tokenXAddress_).decimals())) / tokenXPrice_;
        uint256 _crowdAmount = _getAmountOut(
            destinationPairAddress_,
            tokenXAddress_,
            _tokenXAmount
        );
        if (_crowdAmount < destinationMinAmount_) {
            return (false, 0, 0);
        }

        return (true, _crowdAmount, _tokenXAmount);
    }

    function _getAmountOut(
        address pair_,
        address tokenIn_,
        uint256 amountIn_
    ) internal view returns (uint256 amountOut) {
        IUniswapV2Pair _pair = IUniswapV2Pair(pair_);
        (uint256 _reserve0, uint256 _reserve1, ) = _pair.getReserves();

        uint256 _reserveIn;
        uint256 _reserveOut;
        if (tokenIn_ == _pair.token0()) {
            _reserveIn = _reserve0;
            _reserveOut = _reserve1;
        } else {
            _reserveIn = _reserve1;
            _reserveOut = _reserve0;
        }

        uint8 _swapFee = _pair.swapFee();
        uint256 amountInWithFee = amountIn_ * (1000 - _swapFee);
        uint256 _numerator = amountInWithFee * _reserveOut;
        uint256 _denominator = (_reserveIn * 1000) + amountInWithFee;
        amountOut = _numerator / _denominator;
    }

    /**
     * @notice Updates the second parameter (uint256 amountIn) in the given data byte array that represents CrossDexParams in CrowdSwapV3 aggregator.
     * @dev 100 bytes = 4 (Function Selector) + 32 (Dynamic Data Offset) + 32 (first parameter, address receiverAddress) + 32 (second parameter, uint256 amountIn)
     * @param data_ The input byte array containing the data.
     * @param newAmountIn_ The new value of the uint256 parameter.
     * @return The modified data byte array.
     */
    function _updateAmountInInData(
        bytes memory data_,
        uint256 newAmountIn_
    ) internal pure returns (bytes memory) {
        if (data_.length < 100) revert InvalidDataLength();

        assembly {
            mstore(add(data_, 100), newAmountIn_)
        }

        return data_;
    }

    function _transferFrom(
        address from_,
        address to_,
        IERC20Upgradeable token_,
        uint256 amount_
    ) internal {
        uint256 _beforeBalance = token_.uniBalanceOf(to_);
        token_.safeTransferFrom(from_, to_, amount_);
        uint256 _afterBalance = token_.uniBalanceOf(to_);
        if (_afterBalance - _beforeBalance != amount_) revert MismatchAmounts();
    }

    function _spend(
        address tokenAddress_,
        address receiver_,
        uint256 amount_
    ) internal {
        IERC20Upgradeable(tokenAddress_).uniTransfer(
            payable(receiver_),
            amount_
        );
        emit Spent(msg.sender, tokenAddress_, receiver_, amount_);
    }

    function _calculateFee(
        uint256 tokenAmount_,
        uint256 applicableFeePercentage_
    ) internal pure returns (uint256 fee) {
        fee = (tokenAmount_ * applicableFeePercentage_) / MAX_PERCENTAGE;
    }

    function getTokenDecimals(
        address tokenAddress_
    ) internal view returns (uint8 decimals) {
        if (IERC20Upgradeable(tokenAddress_).isETH()) {
            decimals = 18;
        } else {
            decimals = IERC20(tokenAddress_).decimals();
        }
    }

    function calculateUsdValue(
        uint256 tokenPrice_,
        uint256 tokenAmount_,
        uint8 decimals
    ) internal pure returns (uint256 usdValue) {
        usdValue = (tokenAmount_ * tokenPrice_) / (10 ** decimals);
    }

    function calculateUsdSubsidy(
        SubsidyPercentage[] memory subsidyPercentages_,
        uint256 usdMaxSubsidy_,
        uint256 usdValue_
    ) internal pure returns (uint256 subsidy) {
        uint256 calculatedSubsidy_ = (usdValue_ *
            NativeRouterLib.findApplicableSubsidyPercentage(
                subsidyPercentages_,
                usdValue_
            )) / MAX_PERCENTAGE;
        subsidy = MathUpgradeable.min(calculatedSubsidy_, usdMaxSubsidy_);
    }

    function findApplicableSubsidyPercentage(
        SubsidyPercentage[] memory subsidyPercentages_,
        uint256 value_
    ) internal pure returns (uint256) {
        for (uint256 i = 0; i < subsidyPercentages_.length; i++) {
            if (value_ <= subsidyPercentages_[i].valueIn) {
                return subsidyPercentages_[i].subsidy;
            }
        }

        revert("No applicable subsidy percentage found.");
    }

    function toAddress(
        string memory addressString
    ) internal pure returns (address) {
        bytes memory stringBytes = bytes(addressString);
        uint160 addressNumber = 0;
        uint8 stringByte;

        if (
            stringBytes.length != 42 ||
            stringBytes[0] != "0" ||
            stringBytes[1] != "x"
        ) revert InvalidAddressString();

        for (uint256 i = 2; i < 42; ++i) {
            stringByte = uint8(stringBytes[i]);

            if ((stringByte >= 97) && (stringByte <= 102)) stringByte -= 87;
            else if ((stringByte >= 65) && (stringByte <= 70)) stringByte -= 55;
            else if ((stringByte >= 48) && (stringByte <= 57)) stringByte -= 48;
            else revert InvalidAddressString();

            addressNumber |= uint160(uint256(stringByte) << ((41 - i) << 2));
        }

        return address(addressNumber);
    }

    function toString(address address_) internal pure returns (string memory) {
        bytes memory addressBytes = abi.encodePacked(address_);
        bytes memory characters = "0123456789abcdef";
        bytes memory stringBytes = new bytes(42);

        stringBytes[0] = "0";
        stringBytes[1] = "x";

        for (uint256 i; i < 20; ++i) {
            stringBytes[2 + i * 2] = characters[uint8(addressBytes[i] >> 4)];
            stringBytes[3 + i * 2] = characters[uint8(addressBytes[i] & 0x0f)];
        }

        return string(stringBytes);
    }
}
