// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "./NativeBaseRouter.sol";

contract NativeSwapRouter is NativeBaseRouter {
    using UniERC20Upgradeable for IERC20Upgradeable;

    /* ========== STATE VARIABLES ========== */

    address public crowdAddress;
    address public aggregator;

    uint256 public tvlPercentage;
    uint256 public usdMaxSubsidy;
    NativeRouterLib.SubsidyPercentage[] public subsidyPercentages;

    mapping(address => bool) public supportedTokens;
    mapping(address => bool) public isVerified;
    mapping(address => bool) public isBuybackerVerified;

    uint256 public crowdDebtThreshold;
    uint256 public totalCrowdSellAmount;
    uint256 public totalCrowdBuyBakedAmount;

    function initialize(
        NativeRouterLib.SwapInitializeParams memory initParams_
    ) public initializer {
        NativeBaseRouter._initialize(
            initParams_.gateway,
            initParams_.gasService,
            initParams_.priceFeed,
            initParams_.supportedChainIds,
            initParams_.supportedChainNames
        );

        crowdAddress = initParams_.crowdAddress;
        setAggregator(initParams_.aggregator);
        setTvlPercentage(initParams_.tvlPercentage);
        setSubsidyConfiguration(
            initParams_.subsidyPercentages,
            initParams_.maxSubsidy
        );
        setSupportedTokens(
            initParams_.supportedTokens,
            initParams_.isSupportedList
        );
    }

    /* ========== EXTERNALS ========== */

    function sendMessage(
        NativeRouterLib.MessageRequest calldata messageRequest_
    ) external payable override whenNotPaused nonReentrant {
        if (msg.value < messageRequest_.gas)
            revert NativeRouterLib.InvalidMsgValue();

        NativeRouterLib.Chain memory _destinationChain = supportedChainsById[
            messageRequest_.destinationChainId
        ];
        if (_destinationChain.id == 0) revert NativeRouterLib.InvalidChain();

        (
            NativeRouterLib.Message memory _message,
            NativeRouterLib.SwapDetails memory _details,
            uint256 variableFeeAmount_
        ) = _handleSendSwap(messageRequest_);

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
            _details.destinationMinAmount,
            _details.sourceTokenAddress,
            _details.destinationTokenAddress,
            _message.sender,
            _destinationChain.id
        );
    }

    function buybackCrowd(
        IERC20Upgradeable fromToken_,
        uint256 amount_,
        bytes[] memory swapDataParts_
    ) external whenNotPaused nonReentrant {
        if (!isBuybackerVerified[msg.sender])
            revert NativeRouterLib.InvalidCaller();

        bytes memory swapData_ = abi.encodePacked(
            swapDataParts_[0],
            abi.encode(address(this)), //receiver address
            swapDataParts_[1]
        );

        (
            bool success_,
            uint256 crowdAmount_,
            string memory errorMessage_
        ) = NativeRouterLib._callAggregator(
                aggregator,
                fromToken_,
                amount_,
                swapData_
            );

        if (success_) {
            totalCrowdBuyBakedAmount += crowdAmount_;
        } else {
            revert(errorMessage_);
        }
    }

    function spend(
        address tokenAddress_,
        address receiver_,
        uint256 amount_
    ) external whenNotPaused nonReentrant {
        if (!isVerified[msg.sender]) revert NativeRouterLib.InvalidCaller();
        NativeRouterLib._spend(tokenAddress_, receiver_, amount_);
    }

    function verify(address address_, bool isVerified_) external onlyOwner {
        isVerified[address_] = isVerified_;
    }
    function verifyBuybacker(
        address address_,
        bool isVerified_
    ) external onlyOwner {
        isBuybackerVerified[address_] = isVerified_;
    }

    /**
     * @dev If you want to set/change one of the variables, set the other input to -1
     * @param crowdDebtThreshold_ New value of crowdDebtThreshold
     * @param totalCrowdSellAmount_ New value of totalCrowdSellAmount
     * @param totalCrowdBuyBakedAmount_ New value of totalCrowdBuyBakedAmount
     */
    function setConfiguration(
        int256 crowdDebtThreshold_,
        int256 totalCrowdSellAmount_,
        int256 totalCrowdBuyBakedAmount_
    ) external onlyOwner {
        if (crowdDebtThreshold_ >= 0) {
            crowdDebtThreshold = uint256(crowdDebtThreshold_);
        }
        if (totalCrowdSellAmount_ >= 0) {
            totalCrowdSellAmount = uint256(totalCrowdSellAmount_);
        }
        if (totalCrowdBuyBakedAmount_ >= 0) {
            totalCrowdBuyBakedAmount = uint256(totalCrowdBuyBakedAmount_);
        }
    }

    /* ========== PUBLICS ========== */

    function isCrowdSellUnderThreshold(
        uint256 newCrowdAmount_
    ) public view returns (bool) {
        return
            totalCrowdSellAmount + newCrowdAmount_ <
            totalCrowdBuyBakedAmount + crowdDebtThreshold;
    }

    function setSupportedTokens(
        address[] memory supportedTokens_,
        bool[] memory isSupportedList_
    ) public onlyOwner {
        uint256 _count = supportedTokens_.length;
        if (_count != isSupportedList_.length)
            revert NativeRouterLib.MismatchArraysLength();
        for (uint256 i = 0; i < _count; i++) {
            supportedTokens[supportedTokens_[i]] = isSupportedList_[i];
        }
    }

    function setTvlPercentage(uint256 newPercentage_) public onlyOwner {
        require(newPercentage_ <= NativeRouterLib.MAX_PERCENTAGE, "ce32");
        // emit NativeRouterLib.SetTvlPercentage(
        //     msg.sender,
        //     tvlPercentage,
        //     newPercentage_
        // );
        tvlPercentage = newPercentage_;
    }

    function setSubsidyConfiguration(
        NativeRouterLib.SubsidyPercentage[] memory subsidyPercentages_,
        uint256 newMaxSubsidy_
    ) public onlyOwner {
        usdMaxSubsidy = newMaxSubsidy_;
        // emit NativeRouterLib.SetUsdMaxSubsidy(
        //     msg.sender,
        //     usdMaxSubsidy,
        //     newMaxSubsidy_
        // );

        delete subsidyPercentages;
        uint256 lastIndex = subsidyPercentages_.length - 1;
        for (uint256 i = 0; i < lastIndex; i++) {
            subsidyPercentages.push(subsidyPercentages_[i]);
            // emit NativeRouterLib.SetSubsidyPercentage(
            //     msg.sender,
            //     subsidyPercentages_[i].valueIn,
            //     subsidyPercentages_[i].subsidy
            // );
        }

        //handle last element
        subsidyPercentages.push(
            NativeRouterLib.SubsidyPercentage(
                type(uint256).max,
                subsidyPercentages_[lastIndex].subsidy
            )
        );
        // emit NativeRouterLib.SetSubsidyPercentage(
        //     msg.sender,
        //     type(uint256).max,
        //     subsidyPercentages_[lastIndex].subsidy
        // );
    }

    function setAggregator(address aggregator_) public onlyOwner {
        // emit NativeRouterLib.SetAggregator(
        //     msg.sender,
        //     address(aggregator),
        //     aggregator_
        // );
        aggregator = aggregator_;
    }

    function getMaxAllowedSubsidy(
        uint256 usdValue_,
        uint256 crowdPrice_
    ) public view returns (uint256) {
        return
            (NativeRouterLib.calculateUsdSubsidy(
                subsidyPercentages,
                usdMaxSubsidy,
                usdValue_
            ) * 1e18) / crowdPrice_;
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

        if (_message.actionType == NativeRouterLib.ActionType.CANCEL) {
            _handleReceiveCancel(_message, sourceChain_);
        } else {
            if (_message.destinationChainId != uint64(block.chainid)) {
                _sendCancelMessage(_handleParams, "ce33");
                return;
            }
            NativeRouterLib.ReceivedMessage
                storage receivedMessage = receivedMessages[_messageId];
            if (receivedMessage.status != NativeRouterLib.MessageStatus.NOTSET)
                revert NativeRouterLib.InvalidMessageStatus();

            receivedMessage.sourceChainId = _message.sourceChainId;

            _handleReceiveSwap(_handleParams);
        }
    }

    /* ========== PRIVATES ========== */

    function _handleSendSwap(
        NativeRouterLib.MessageRequest calldata messageRequest_
    )
        private
        returns (
            NativeRouterLib.Message memory,
            NativeRouterLib.SwapDetails memory,
            uint256
        )
    {
        NativeRouterLib.SwapDetails memory _details = NativeRouterLib
            .decodeSwapDetails(messageRequest_.details);

        if (!supportedTokens[_details.sourceTokenAddress])
            revert NativeRouterLib.InvalidSourceTokenAddress();

        IERC20Upgradeable _sourceToken = IERC20Upgradeable(
            _details.sourceTokenAddress
        );
        if (_sourceToken.isETH()) {
            if (msg.value != messageRequest_.gas + _details.sourceAmount)
                revert NativeRouterLib.InvalidMsgValue();
        } else {
            NativeRouterLib._transferFrom(
                msg.sender,
                address(this),
                _sourceToken,
                _details.sourceAmount
            );
        }

        (uint256 _variableFeeAmount, uint256 usdValueAfterFee_) = _calculateFee(
            _details.sourceTokenAddress,
            _details.sourceAmount
        );
        _details.sourceAmount -= _variableFeeAmount;

        NativeRouterLib.Message memory _message = NativeRouterLib.Message(
            NativeRouterLib.ActionType.SWAP,
            userNonce[msg.sender]++,
            uint64(block.chainid),
            messageRequest_.destinationChainId,
            usdValueAfterFee_,
            msg.sender,
            messageRequest_.receiver,
            messageRequest_.details
        );

        return (_message, _details, _variableFeeAmount);
    }

    function _handleReceiveSwap(
        NativeRouterLib.HandleParams memory handleParams_
    ) private {
        NativeRouterLib.SwapDetails memory _details = NativeRouterLib
            .decodeSwapDetails(handleParams_.message.details);

        address _crowdAddress = crowdAddress; // gas savings
        uint256 _crowdPrice = priceFeed.getPrice(_crowdAddress);

        address _tokenXAddress = NativeRouterLib._getTokenX(
            _details.destinationPairAddress,
            _crowdAddress
        );
        uint256 _tokenXPrice = priceFeed.getPrice(_tokenXAddress);

        uint256 _crowdAmount;
        uint256 _tokenXAmount;

        if (_details.destinationTokenAddress == _crowdAddress) {
            (
                bool _isValid,
                uint256 _crowdAmountTemp,
                uint256 _tokenXAmountTemp
            ) = NativeRouterLib._isValidCrowdBuy(
                    handleParams_.message.usdValue,
                    _tokenXPrice,
                    _details.destinationMinAmount,
                    _tokenXAddress,
                    _details.destinationPairAddress
                );
            if (!_isValid) {
                _sendCancelMessage(handleParams_, "ce35");
                return;
            }
            _crowdAmount = _crowdAmountTemp;
            _tokenXAmount = _tokenXAmountTemp;

            _validateThreshold(_crowdAmount);
            IERC20Upgradeable(_details.destinationTokenAddress).uniTransfer(
                payable(handleParams_.message.receiver),
                _crowdAmount
            );
        } else {
            (
                NativeRouterLib.ResultParams memory _resultParams,
                uint256 _crowdAmountTemp,
                uint256 _tokenXAmountTemp
            ) = NativeRouterLib._validateAndGetAmountIn(
                    NativeRouterLib.ValidateAndGetAmountInParams(
                        handleParams_.message.usdValue,
                        _tokenXPrice,
                        tvlPercentage,
                        _details.destinationPairAddress,
                        _tokenXAddress
                    )
                );
            if (!_resultParams.success) {
                _sendCancelMessage(handleParams_, _resultParams.errorMessage);
                return;
            }
            _crowdAmount = _crowdAmountTemp;
            _tokenXAmount = _tokenXAmountTemp;

            //validate _details.destinationCrowdAmount
            {
                uint256 _maxAllowedCrowd = _crowdAmount +
                    getMaxAllowedSubsidy(
                        handleParams_.message.usdValue,
                        _crowdPrice
                    );

                _crowdAmount = MathUpgradeable.min(
                    _details.destinationCrowdAmount,
                    _maxAllowedCrowd
                );
            }

            _validateThreshold(_crowdAmount);
            _resultParams = _callAggregator(
                IERC20Upgradeable(_crowdAddress),
                _crowdAmount,
                NativeRouterLib._updateAmountInInData(
                    _details.data,
                    _crowdAmount
                )
            );
            if (!_resultParams.success) {
                _sendCancelMessage(handleParams_, _resultParams.errorMessage);
                return;
            }
        }

        totalCrowdSellAmount += _crowdAmount;
        emit NativeRouterLib.Sold(
            handleParams_.messageId,
            _details.sourceTokenAddress,
            _details.sourceAmount,
            handleParams_.message.usdValue,
            _crowdAddress,
            _crowdAmount,
            _crowdPrice,
            _tokenXAddress,
            _tokenXAmount,
            _tokenXPrice
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
        NativeRouterLib.SentMessage storage sentMessage = sentMessages[
            NativeRouterLib.getMessageId(message_)
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

        IERC20Upgradeable(sentMessage.sourceTokenAddress).uniTransfer(
            payable(sentMessage.sender),
            sentMessage.sourceAmount
        );
    }

    function _callAggregator(
        IERC20Upgradeable fromToken_,
        uint256 amount_,
        bytes memory swapData_
    ) private returns (NativeRouterLib.ResultParams memory) {
        address _aggregator = aggregator; // gas savings
        if (!fromToken_.isETH()) {
            fromToken_.uniApprove(_aggregator, amount_);
        }

        (bool success, bytes memory returnData) = _aggregator.call(swapData_);
        if (!success) {
            string memory reason;
            if (returnData.length < 68) {
                reason = "ce35";
            } else {
                assembly {
                    returnData := add(returnData, 0x04)
                }
                reason = abi.decode(returnData, (string));
            }
            return NativeRouterLib.ResultParams(false, reason);
        }
        return NativeRouterLib.ResultParams(true, "");
    }

    function _validateThreshold(uint256 crowdAmount_) private {
        require(
            isCrowdSellUnderThreshold(crowdAmount_),
            "NativeSwapRouter: Threshold Reached!"
        );
    }

    /* ========== Version Control ========== */

    /// @dev The contract's version
    // function version() external pure returns (string memory) {
    //     return "1.0.0";
    // }
}
