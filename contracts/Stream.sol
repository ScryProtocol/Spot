// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Address.sol";

// Custom IERC20 interface with additional functions for token details
interface IERC20 {
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}
/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using Address for address;

    function safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value
    ) internal {
        _callOptionalReturn(
            token,
            abi.encodeWithSelector(token.transferFrom.selector, from, to, value)
        );
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(
            data,
            "SafeERC20: low-level call failed"
        );
        if (returndata.length > 0) {
            // Return data is optional
            require(
                abi.decode(returndata, (bool)),
                "SafeERC20: ERC20 operation did not succeed"
            );
        }
    }
}

contract Stream {
    using SafeERC20 for IERC20;

    struct StreamDetails {
        address streamer;
        address recipient;
        address token;
        uint256 totalStreamed;
        uint256 outstanding;
        uint256 allowable;
        uint256 window;
        uint256 timestamp;
        bool once;
    }

    mapping(bytes32 => StreamDetails) public streamDetails;
    mapping(address => bytes32[]) public streamDetailsByStreamer;
    mapping(address => bytes32[]) public streamDetailsByRecipient;
    address payable public feeAddress;
    uint public fee;

    event StreamAllowed(
        address indexed streamer,
        address indexed token,
        address indexed recipient,
        uint256 amount
    );
    event Streamed(
        address indexed token,
        address indexed streamer,
        address indexed recipient,
        uint256 amount
    );
    event StreamFailure(
        address indexed token,
        address indexed streamer,
        address indexed recipient,
        string message
    );
    constructor(address payable feeAddrs) {
        feeAddress = feeAddrs;
    }

    function computeHash(
        address streamer,
        address token,
        address recipient
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(streamer, token, recipient));
    }

    function allowStream(
        address token,
        address recipient,
        uint256 amount,
        uint256 window,
        bool once
    ) public {
        bytes32 hash = computeHash(msg.sender, token, recipient);
        if (streamDetails[hash].streamer == address(0)) {
            streamDetails[hash] = StreamDetails({
                streamer: msg.sender,
                recipient: recipient,
                token: token,
                totalStreamed: 0,
                outstanding: amount,
                allowable: amount,
                window: window,
                timestamp: block.timestamp,
                once: once
            });
            streamDetailsByStreamer[msg.sender].push(hash);
            streamDetailsByRecipient[recipient].push(hash);
        } else {
            streamDetails[hash].allowable = amount;
            streamDetails[hash].outstanding = amount;
            streamDetails[hash].window = window;
            streamDetails[hash].timestamp = block.timestamp;
            streamDetails[hash].once = once;
        }
        emit StreamAllowed(msg.sender, token, recipient, amount);
    }

    function stream(address token, address streamer, address recipient) public {
        bytes32 hash = computeHash(streamer, token, recipient);
        StreamDetails storage details = streamDetails[hash];
        require(details.streamer != address(0), "Stream does not exist");

        uint256 currentTime = block.timestamp;
        uint256 elapsedTime = currentTime - details.timestamp;
        uint256 allowableAmount = (details.allowable * elapsedTime) /
            details.window;

        if (allowableAmount > details.outstanding && details.once == true) {
            allowableAmount = details.outstanding;
        }

        require(allowableAmount > 0, "No allowable amount to withdraw");

        if (details.once) {
            details.outstanding -= allowableAmount;
        }

        details.totalStreamed += allowableAmount;
        details.timestamp = currentTime;
        IERC20(token).safeTransferFrom(streamer, recipient, allowableAmount);

        if (fee > 0) {
            uint256 feeAmount = (allowableAmount * fee) / 1000;
            IERC20(token).safeTransferFrom(streamer, feeAddress, feeAmount);
        }
        emit Streamed(token, streamer, recipient, allowableAmount);
    }

    function batchAllowStream(
        address[] calldata tokens,
        address[] calldata recipients,
        uint256[] calldata amounts,
        uint256[] calldata windows,
        bool[] calldata onces
    ) external {
        require(
            tokens.length == recipients.length &&
                recipients.length == amounts.length &&
                amounts.length == windows.length &&
                windows.length == onces.length,
            "Input arrays length mismatch"
        );

        for (uint256 i = 0; i < tokens.length; i++) {
            allowStream(
                tokens[i],
                recipients[i],
                amounts[i],
                windows[i],
                onces[i]
            );
        }
    }

    function batchStream(
        address[] calldata tokens,
        address[] calldata streamers,
        address[] calldata recipients
    ) external {
        require(
            tokens.length == streamers.length &&
                streamers.length == recipients.length,
            "Input arrays length mismatch"
        );

        for (uint256 i = 0; i < tokens.length; i++) {
            stream(tokens[i], streamers[i], recipients[i]);
        }
    }

    function batchStreamAvailable(
        address[] memory tokens,
        address[] memory streamers,
        address[] memory recipients
    ) public {
        require(
            tokens.length == streamers.length &&
                streamers.length == recipients.length,
            "Input arrays length mismatch"
        );

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            address streamer = streamers[i];
            address recipient = recipients[i];

            bytes32 hash = computeHash(streamer, token, recipient);
            StreamDetails storage details = streamDetails[hash];

            // Check if the stream exists, if not log and continue to the next one
            if (details.streamer == address(0)) {
                emit StreamFailure(
                    token,
                    streamer,
                    recipient,
                    "Stream does not exist"
                );
                continue;
            }

            uint256 currentTime = block.timestamp;
            uint256 elapsedTime = currentTime - details.timestamp;
            uint256 allowableAmount = (details.allowable * elapsedTime) /
                details.window;

            if (allowableAmount > details.outstanding && details.once == true) {
                allowableAmount = details.outstanding;
            }

            // If there's no allowable amount to withdraw, log and continue to the next one
            if (allowableAmount == 0) {
                emit StreamFailure(
                    token,
                    streamer,
                    recipient,
                    "No allowable amount to withdraw"
                );
                continue;
            }

            // Calculate fee if applicable
            uint256 feeAmount  = 0;
            if (fee > 0) {
                feeAmount = (allowableAmount * fee) / 1000;
            }
            uint256 totalAmountToTransfer = allowableAmount + feeAmount;

            // Check if streamer has sufficient balance, log and continue if insufficient
            uint256 streamerBalance = IERC20(token).balanceOf(streamer);
            if (streamerBalance < totalAmountToTransfer) {
                emit StreamFailure(
                    token,
                    streamer,
                    recipient,
                    "Insufficient balance for streaming"
                );
                continue;
            }

            // Check if contract has sufficient allowance to transfer tokens, log and continue if insufficient
            uint256 allowance = IERC20(token).allowance(
                streamer,
                address(this)
            );
            if (allowance < totalAmountToTransfer) {
                emit StreamFailure(
                    token,
                    streamer,
                    recipient,
                    "Insufficient allowance for streaming"
                );
                continue;
            }

            // Proceed with streaming logic
            if (details.once) {
                details.outstanding -= allowableAmount;
            }

            details.totalStreamed += allowableAmount;
            details.timestamp = currentTime;

            // Transfer allowable amount to recipient
            IERC20(token).safeTransferFrom(
                streamer,
                recipient,
                allowableAmount
            );

            // Transfer the fee to feeAddress if applicable
            if (feeAmount > 0) {
                IERC20(token).safeTransferFrom(streamer, feeAddress, feeAmount);
            }

            emit Streamed(token, streamer, recipient, allowableAmount);
        }
    }
    function batchStreamAvailableAllowances(bytes32[] memory hashes) external {
        address[] memory tokens = new address[](hashes.length);
        address[] memory streamers = new address[](hashes.length);
        address[] memory recipients = new address[](hashes.length);
        for (uint256 i = 0; i < hashes.length; i++) {
            StreamDetails storage details = streamDetails[hashes[i]];
            tokens[i] = details.token;
            streamers[i] = details.streamer;
            recipients[i] = details.recipient;
        }
        batchStreamAvailable(tokens, streamers, recipients);
    }
    function cancelStreams(
        address[] calldata tokens,
        address[] calldata streamers,
        address[] calldata recipients
    ) external {
        require(
            tokens.length == streamers.length &&
                streamers.length == recipients.length,
            "Input arrays length mismatch"
        );

        for (uint256 i = 0; i < tokens.length; i++) {
            require(
                msg.sender == streamers[i] || msg.sender == recipients[i],
                "You are not the streamer or recipient"
            );
            bytes32 hash = computeHash(streamers[i], tokens[i], recipients[i]);
            StreamDetails storage details = streamDetails[hash];
            require(details.streamer != address(0), "Stream does not exist");
            details.allowable = 0;
            details.outstanding = 0;
            emit StreamAllowed(streamers[i], tokens[i], recipients[i], 0);
        }
    }
    function getAvailable(
        address token,
        address streamer,
        address recipient
    ) public view returns (uint256) {
        bytes32 hash = computeHash(streamer, token, recipient);
        StreamDetails storage details = streamDetails[hash];
        //require(details.streamer != address(0), "Stream does not exist");

        uint256 currentTime = block.timestamp;
        uint256 elapsedTime = currentTime - details.timestamp;
        uint256 allowableAmount = details.window>0?(details.allowable * elapsedTime) /
            details.window:0;

        if (allowableAmount > details.outstanding && details.once == true) {
            allowableAmount = details.outstanding;
        }

        return allowableAmount;
    }

    function getStreamDetails(
        bytes32[] calldata hashes
    )
        public
        view
        returns (
            uint[] memory availableAmounts,
            uint8[] memory decimals,
            string[] memory tokenNames,
            string[] memory tokenSymbols,
            StreamDetails[] memory details
        )
    {
        uint length = hashes.length;
        details = new StreamDetails[](length);
        availableAmounts = new uint[](length);
        decimals = new uint8[](length);
        tokenNames = new string[](length);
        tokenSymbols = new string[](length);

        for (uint256 i = 0; i < length; i++) {
            details[i] = streamDetails[hashes[i]];
            availableAmounts[i] = getAvailable(
                details[i].token,
                details[i].streamer,
                details[i].recipient
            );

            // Getting the ERC20 token details
(bool success, bytes memory data) = details[i].token.staticcall(
                abi.encodeWithSignature("decimals()")
            );
            decimals[i] = data.length==32 ? abi.decode(data, (uint8)) : 0;
            (success, data) = details[i].token.staticcall(
                abi.encodeWithSignature("name()")
            );
            tokenNames[i] = data.length>0 ? abi.decode(data, (string)) : "";
            (success, data) = details[i].token.staticcall(
                abi.encodeWithSignature("symbol()")
            );
            tokenSymbols[i] = data.length>0 ? abi.decode(data, (string)) : "";
        }
        return (availableAmounts, decimals, tokenNames, tokenSymbols, details);
    }
    function getStreamable(
        bytes32[] calldata hashes
    ) public view returns (bool[] memory canStream,uint[] memory balances, uint[] memory allowances) {
        uint length = hashes.length;
        canStream = new bool[](length);
        balances = new uint[](length);
        allowances = new uint[](length);
        for (uint256 i = 0; i < length; i++) {
            StreamDetails storage details = streamDetails[hashes[i]];
            require(details.streamer != address(0), "Stream does not exist");
            uint amount = getAvailable(
                details.token,
                details.streamer,
                details.recipient
            );
            balances[i] = IERC20(details.token).balanceOf(details.streamer);
            allowances[i] = IERC20(details.token).allowance(
                details.streamer,
                address(this)
            );
            canStream[i] = amount + (amount * fee) / 1000 <= balances[i] &&amount + (amount * fee) / 1000 <= allowances[i];
        }

        return (canStream, balances, allowances);
    }
    function batchComputeHash(
        address[] calldata streamers,
        address[] calldata tokens,
        address[] calldata recipients
    ) public pure returns (bytes32[] memory) {
        require(
            streamers.length == tokens.length &&
                tokens.length == recipients.length,
            "Input arrays length mismatch"
        );
        uint length = streamers.length;
        bytes32[] memory hashes = new bytes32[](length);
        for (uint256 i = 0; i < length; i++) {
            hashes[i] = computeHash(streamers[i], tokens[i], recipients[i]);
        }
        return hashes;
    }

    function viewStreamerAllowances(
        address streamer
    ) public view returns (bytes32[] memory) {
        return streamDetailsByStreamer[streamer];
    }

    function viewRecipientAllowances(
        address recipient
    ) public view returns (bytes32[] memory) {
        return streamDetailsByRecipient[recipient];
    }
function viewStreamerAllowancesCount(
        address streamer
    ) public view returns (uint) {
        return streamDetailsByStreamer[streamer].length;
    }
function viewRecipientAllowancesCount(
        address recipient
    ) public view returns (uint) {
        return streamDetailsByRecipient[recipient].length;
    }
    function viewStreamerAllowances(address streamer, uint[] calldata indexes) public view returns (bytes32[] memory) {
        bytes32[] memory allowances = new bytes32[](indexes.length);
        for (uint i = 0; i < indexes.length; i++) {
            allowances[i] = streamDetailsByStreamer[streamer][indexes[i]];
        }
        return allowances;
    }
    function viewRecipientAllowances(address recipient, uint[] calldata indexes) public view returns (bytes32[] memory) {
        bytes32[] memory allowances = new bytes32[](indexes.length);
        for (uint i = 0; i < indexes.length; i++) {
            allowances[i] = streamDetailsByRecipient[recipient][indexes[i]];
        }
        return allowances;
    }
    function setFee(uint _fee, address newFeeAddress) public {
        require(msg.sender == feeAddress, "You are not the owner");
        fee = _fee <= 50 ? _fee : 50;
        feeAddress = newFeeAddress != address(0)
            ? payable(newFeeAddress)
            : feeAddress;
    }
}
