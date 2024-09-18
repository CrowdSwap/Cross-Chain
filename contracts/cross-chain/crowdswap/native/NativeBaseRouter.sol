// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "./NativeExecutableUpgradeable.sol";
import "./interfaces/ICrowdSwapPriceFeed.sol";
import "./interfaces/IERC20.sol";
import "./libraries/NativeRouterLib.sol";
import "../gas-service/interfaces/INativeGasService.sol";
import "../../../libraries/UniERC20Upgradeable.sol";

abstract contract NativeBaseRouter is NativeExecutableUpgradeable {
    using UniERC20Upgradeable for IERC20Upgradeable;

    /* ========== STATE VARIABLES ========== */

    INativeGasService public gasService;
    ICrowdSwapPriceFeed public priceFeed;

    mapping(uint64 => NativeRouterLib.Chain) public supportedChainsById;
    mapping(string => NativeRouterLib.Chain) public supportedChainsByName;
    mapping(address => uint64) public userNonce;
    mapping(bytes32 => NativeRouterLib.SentMessage) public sentMessages;
    mapping(bytes32 => NativeRouterLib.ReceivedMessage) public receivedMessages;

    uint256[50] private __gap;

    function _initialize(
        address gateway_,
        address gasService_,
        address priceFeed_,
        uint64[] memory supportedChainIds_,
        string[] memory supportedChainNames_
    ) internal onlyInitializing {
        OwnableUpgradeable.initialize();
        PausableUpgradeable.__Pausable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        NativeExecutableUpgradeable._initialize(gateway_);
        gasService = INativeGasService(gasService_);

        setPriceFeed(priceFeed_);
        setSupportedChains(supportedChainIds_, supportedChainNames_);
    }

    /* ========== EXTERNALS ========== */

    function sendMessage(
        NativeRouterLib.MessageRequest calldata messageRequest_
    ) external payable virtual;

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ========== PUBLICS ========== */

    function setPriceFeed(address priceFeed_) public onlyOwner {
        // emit NativeRouterLib.SetPriceFeed(msg.sender, address(priceFeed), priceFeed_);
        priceFeed = ICrowdSwapPriceFeed(priceFeed_);
    }

    function setSupportedChains(
        uint64[] memory supportedChainIds_,
        string[] memory supportedChainNames_
    ) public onlyOwner {
        uint256 _count = supportedChainIds_.length;
        if (_count != supportedChainNames_.length)
            revert NativeRouterLib.MismatchArraysLength();

        for (uint8 i; i < _count; i++) {
            NativeRouterLib.Chain memory _newChain = NativeRouterLib.Chain(
                supportedChainIds_[i],
                supportedChainNames_[i]
            );
            supportedChainsById[supportedChainIds_[i]] = _newChain;
            supportedChainsByName[supportedChainNames_[i]] = _newChain;
            // emit NativeRouterLib.SetSupportedChain(msg.sender, _newChain);
        }
    }

    /* ========== VIEWS ========== */
    function _findFeeBasedOnValue(
        uint256 tokenAmount_,
        uint256 usdValue_
    ) internal view returns (uint256) {
        uint256 applicableFeePercentage_ = gasService
            .findApplicableFeePercentage(usdValue_);

        return
            NativeRouterLib._calculateFee(
                tokenAmount_,
                applicableFeePercentage_
            );
    }

    /* ========== INTERNALS ========== */

    function _saveSentMessage(
        uint64 destinationId_,
        uint256 sourceAmount_,
        address sourceTokenAddress_,
        address sender_,
        bytes32 messageId_
    ) internal {
        NativeRouterLib.SentMessage storage sentMessage = sentMessages[
            messageId_
        ];
        if (sentMessage.status != NativeRouterLib.MessageStatus.NOTSET)
            revert NativeRouterLib.InvalidMessageStatus();

        sentMessage.status = NativeRouterLib.MessageStatus.SENT;
        sentMessage.sourceTokenAddress = sourceTokenAddress_;
        sentMessage.sourceAmount = sourceAmount_;
        sentMessage.destinationChainId = destinationId_;
        sentMessage.sender = sender_;
    }

    function _updateReceivedMessage(
        bytes32 messageId_,
        uint256 destinationAmount_,
        address destinationTokenAddress_,
        address receiver_
    ) internal {
        NativeRouterLib.ReceivedMessage
            storage receivedMessage = receivedMessages[messageId_];
        receivedMessage.status = NativeRouterLib.MessageStatus.COMPLETED;
        emit NativeRouterLib.MessageCompleted(
            messageId_,
            destinationAmount_,
            destinationTokenAddress_,
            receiver_
        );
    }

    function _callNative(
        NativeRouterLib.CallNativeParams memory params_
    ) internal {
        string memory _destinationAddress = NativeRouterLib.toString(
            address(this)
        );
        bytes memory _payload = abi.encode(params_.message);
        uint256 msgValueForCallingPayFee_;
        {
            IERC20Upgradeable variableFeeToken__ = IERC20Upgradeable(
                params_.variableFeeToken
            );

            if (variableFeeToken__.isETH()) {
                msgValueForCallingPayFee_ =
                    params_.fixedFeeAmount +
                    params_.variableFeeAmount;
            } else {
                msgValueForCallingPayFee_ = params_.fixedFeeAmount;

                variableFeeToken__.uniApprove(
                    address(gasService),
                    params_.variableFeeAmount
                );
            }
        }

        gasService.payFee{value: msgValueForCallingPayFee_}(
            address(this),
            params_.destinationChain,
            _destinationAddress,
            _payload,
            params_.variableFeeToken,
            params_.variableFeeAmount,
            params_.message.sender
        );

        gateway.callContract(
            params_.destinationChain,
            _destinationAddress,
            _payload
        );
    }

    function _sendCancelMessage(
        NativeRouterLib.HandleParams memory handleParams_,
        string memory reason_
    ) internal {
        NativeRouterLib.ReceivedMessage
            storage receivedMessage = receivedMessages[handleParams_.messageId];
        receivedMessage.status = NativeRouterLib.MessageStatus.CANCELED;
        emit NativeRouterLib.MessageCanceled(handleParams_.messageId, reason_);

        handleParams_.message.actionType = NativeRouterLib.ActionType.CANCEL;
        gateway.callContract(
            handleParams_.sourceChain,
            handleParams_.sourceAddress,
            abi.encode(handleParams_.message)
        );
    }

    function _calculateFee(
        address feeTokenAddress_,
        uint256 amount_
    ) internal view returns (uint256 feeAmount_, uint256 usdValueAfterFee_) {
        uint256 _price = priceFeed.getPrice(feeTokenAddress_);
        uint8 _decimals = NativeRouterLib.getTokenDecimals(feeTokenAddress_);
        uint256 _usdValueBeforeFee = NativeRouterLib.calculateUsdValue(
            _price,
            amount_,
            _decimals
        );

        feeAmount_ = _findFeeBasedOnValue(amount_, _usdValueBeforeFee);
        usdValueAfterFee_ = NativeRouterLib.calculateUsdValue(
            _price,
            amount_ - feeAmount_,
            _decimals
        );
    }
}
