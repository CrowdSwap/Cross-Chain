// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "./NativeBaseRouter.sol";
import "./interfaces/ICrowdSwapLock.sol";

contract NativeBridgeRouter is NativeBaseRouter {
    using UniERC20Upgradeable for IERC20Upgradeable;

    /* ========== STATE VARIABLES ========== */

    mapping(address => address) public lockContracts;
    mapping(address => mapping(uint64 => address)) public tokenPeers;

    function initialize(
        NativeRouterLib.BridgeInitializeParams memory initParams_
    ) public initializer {
        NativeBaseRouter._initialize(
            initParams_.gateway,
            initParams_.gasService,
            initParams_.priceFeed,
            initParams_.supportedChainIds,
            initParams_.supportedChainNames
        );

        setLockContracts(
            initParams_.bridgingTokens,
            initParams_.lockingContracts
        );
        setTokenPeers(initParams_.tokenPeers);
    }

    /* ========== EXTERNALS ========== */

    function sendMessage(
        NativeRouterLib.MessageRequest calldata messageRequest_
    ) external payable override whenNotPaused nonReentrant {
        if (msg.value != messageRequest_.gas)
            revert NativeRouterLib.InvalidMsgValue();

        NativeRouterLib.Chain memory _destinationChain = supportedChainsById[
            messageRequest_.destinationChainId
        ];
        if (_destinationChain.id == 0) revert NativeRouterLib.InvalidChain();

        (
            NativeRouterLib.Message memory _message,
            NativeRouterLib.BridgeDetails memory _details,
            uint256 variableFeeAmount_
        ) = _handleSendBridge(messageRequest_);

        bytes32 _messageId = NativeRouterLib.getMessageId(_message);

        _saveSentMessage(
            _destinationChain.id,
            _details.sourceAmount,
            _details.sourceTokenAddress,
            _message.sender,
            _messageId
        );

        _callNative(
            NativeRouterLib.CallNativeParams(
                _message,
                _destinationChain.name,
                messageRequest_.gas,
                _details.sourceTokenAddress,
                variableFeeAmount_
            )
        );

        emit NativeRouterLib.MessageSent(
            _messageId,
            _details.sourceAmount,
            _details.destinationAmount,
            _details.destinationAmount,
            _details.sourceTokenAddress,
            _details.destinationTokenAddress,
            _message.sender,
            _destinationChain.id
        );
    }

    /* ========== PUBLICS ========== */

    function setLockContracts(
        address[] memory bridgingTokens_,
        address[] memory lockingContracts_
    ) public onlyOwner {
        uint256 count = bridgingTokens_.length;
        if (count != lockingContracts_.length)
            revert NativeRouterLib.MismatchArraysLength();

        if (count > 0) {
            for (uint8 i = 0; i < count; i++) {
                emit NativeRouterLib.SetLockContract(
                    msg.sender,
                    bridgingTokens_[i],
                    lockContracts[bridgingTokens_[i]],
                    lockingContracts_[i]
                );
                lockContracts[bridgingTokens_[i]] = lockingContracts_[i];
            }
        }
    }

    function setTokenPeers(
        NativeRouterLib.TokenPeers[] memory tokenPeers_
    ) public onlyOwner {
        for (uint256 i = 0; i < tokenPeers_.length; i++) {
            if (
                tokenPeers_[i].chainIdList.length !=
                tokenPeers_[i].destinationTokenAddressList.length
            ) revert NativeRouterLib.MismatchArraysLength();
            for (uint256 j = 0; j < tokenPeers_[i].chainIdList.length; j++) {
                emit NativeRouterLib.SetTokenPeer(
                    msg.sender,
                    tokenPeers_[i].sourceTokenAddress,
                    tokenPeers_[i].chainIdList[j],
                    tokenPeers[tokenPeers_[i].sourceTokenAddress][
                        tokenPeers_[i].chainIdList[j]
                    ],
                    tokenPeers_[i].destinationTokenAddressList[j]
                );
                tokenPeers[tokenPeers_[i].sourceTokenAddress][
                    tokenPeers_[i].chainIdList[j]
                ] = tokenPeers_[i].destinationTokenAddressList[j];
            }
        }
    }

    /* ========== INTERNALS ========== */

    function _execute(
        string calldata sourceChain_,
        string calldata sourceAddress_,
        bytes calldata payload_
    ) internal override whenNotPaused nonReentrant {
        if (supportedChainsByName[sourceChain_].id == 0)
            revert NativeRouterLib.InvalidChain();

        if (NativeRouterLib.toAddress(sourceAddress_) != address(this))
            revert NativeRouterLib.InvalidSourceRouterAddress();

        NativeRouterLib.Message memory _message = NativeRouterLib.decodeMessage(
            payload_
        );
        bytes32 _messageId = NativeRouterLib.getMessageId(_message);

        NativeRouterLib.HandleParams memory _handleParams = NativeRouterLib
            .HandleParams(
                _messageId,
                _message,
                sourceChain_,
                sourceAddress_,
                payload_
            );

        if (_message.destinationChainId != uint64(block.chainid)) {
            _sendCancelMessage(_handleParams, "InvalidChain");
            return;
        }

        if (_message.actionType == NativeRouterLib.ActionType.CANCEL) {
            _handleReceiveCancel(_message, sourceChain_);
        } else {
            NativeRouterLib.ReceivedMessage
                storage receivedMessage = receivedMessages[_messageId];
            if (receivedMessage.status != NativeRouterLib.MessageStatus.NOTSET)
                revert NativeRouterLib.InvalidMessageStatus();

            receivedMessage.sourceChainId = _message.sourceChainId;

            _handleReceiveBridge(_handleParams);
        }
    }

    /* ========== PRIVATES ========== */

    function _handleSendBridge(
        NativeRouterLib.MessageRequest calldata messageRequest_
    )
        private
        returns (
            NativeRouterLib.Message memory,
            NativeRouterLib.BridgeDetails memory,
            uint256
        )
    {
        NativeRouterLib.BridgeDetails memory _details = NativeRouterLib
            .decodeBridgeDetails(messageRequest_.details);

        IERC20Upgradeable _sourceToken = IERC20Upgradeable(
            _details.sourceTokenAddress
        );
        if (_sourceToken.isETH())
            revert NativeRouterLib.InvalidSourceTokenAddress();

        if (
            tokenPeers[_details.sourceTokenAddress][
                messageRequest_.destinationChainId
            ] == address(0)
        ) revert NativeRouterLib.InvalidSourceTokenAddress();

        if (
            _details.destinationTokenAddress !=
            tokenPeers[_details.sourceTokenAddress][
                messageRequest_.destinationChainId
            ]
        ) revert NativeRouterLib.InvalidDestinationTokenAddress();

        (uint256 _variableFeeAmount, uint256 usdValueAfterFee_) = _calculateFee(
            _details.sourceTokenAddress,
            _details.sourceAmount
        );
        _details.sourceAmount -= _variableFeeAmount;

        if (_details.sourceAmount < _details.destinationAmount)
            revert NativeRouterLib.InvalidDestinationAmount();

        NativeRouterLib._transferFrom(
            msg.sender,
            address(this),
            _sourceToken,
            _variableFeeAmount
        );
        _burnOrLock(
            _details.sourceTokenAddress,
            msg.sender,
            _details.sourceAmount
        );

        NativeRouterLib.Message memory _message;
        _message.actionType = NativeRouterLib.ActionType.BRIDGE;
        _message.nonce = userNonce[msg.sender]++;
        _message.sourceChainId = uint64(block.chainid);
        _message.destinationChainId = messageRequest_.destinationChainId;
        _message.usdValue = usdValueAfterFee_;
        _message.sender = msg.sender;
        _message.receiver = messageRequest_.receiver;
        _message.details = messageRequest_.details;

        return (_message, _details, _variableFeeAmount);
    }

    function _handleReceiveBridge(
        NativeRouterLib.HandleParams memory handleParams_
    ) private {
        NativeRouterLib.BridgeDetails memory _details = NativeRouterLib
            .decodeBridgeDetails(handleParams_.message.details);

        if (
            tokenPeers[_details.destinationTokenAddress][
                handleParams_.message.sourceChainId
            ] == address(0)
        ) {
            _sendCancelMessage(handleParams_, "InvalidDestinationTokenAddress");
            return;
        }

        if (
            _details.sourceTokenAddress !=
            tokenPeers[_details.destinationTokenAddress][
                handleParams_.message.sourceChainId
            ]
        ) {
            _sendCancelMessage(handleParams_, "InvalidSourceTokenAddress");
            return;
        }

        _mintOrUnlock(
            _details.destinationTokenAddress,
            handleParams_.message.receiver,
            _details.destinationAmount
        );

        _updateReceivedMessage(
            handleParams_.messageId,
            _details.destinationAmount,
            _details.destinationTokenAddress,
            handleParams_.message.receiver
        );
    }

    function _handleReceiveCancel(
        NativeRouterLib.Message memory message_,
        string calldata sourceChain_
    ) private {
        bytes32 _messageId = NativeRouterLib.getMessageId(message_);
        NativeRouterLib.SentMessage storage sentMessage = sentMessages[
            _messageId
        ];

        if (
            sentMessage.destinationChainId !=
            supportedChainsByName[sourceChain_].id
        ) {
            revert NativeRouterLib.InvalidChain();
        }

        if (sentMessage.status != NativeRouterLib.MessageStatus.SENT)
            revert NativeRouterLib.InvalidMessageStatus();
        sentMessage.status = NativeRouterLib.MessageStatus.CANCELED;

        _mintOrUnlock(
            sentMessage.sourceTokenAddress,
            sentMessage.sender,
            sentMessage.sourceAmount
        );
    }

    function _mintOrUnlock(
        address tokenAddress_,
        address receiver_,
        uint256 amount_
    ) private {
        address _lockContract = lockContracts[tokenAddress_]; //gas savings
        if (_lockContract == address(0)) {
            IERC20(tokenAddress_).mint(receiver_, amount_);
        } else {
            ICrowdSwapLock(_lockContract).unlock(receiver_, amount_);
        }
    }

    function _burnOrLock(
        address tokenAddress_,
        address sender_,
        uint256 amount_
    ) private {
        address _lockContract = lockContracts[tokenAddress_]; // gas savings
        if (_lockContract == address(0)) {
            IERC20(tokenAddress_).burnFrom(sender_, amount_);
        } else {
            NativeRouterLib._transferFrom(
                sender_,
                _lockContract,
                IERC20Upgradeable(tokenAddress_),
                amount_
            );
        }
    }

    /* ========== Version Control ========== */

    /// @dev The contract's version
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
