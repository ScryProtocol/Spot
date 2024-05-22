// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Stream is ReentrancyGuard {
    using SafeERC20 for IERC20;
    struct StreamDetails {
        address streamer;
        address friend;
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
    mapping(address => bytes32[]) public streamDetailsByFriend;

    address payable public feeAddress;
    uint public fee;

    event StreamAllowed(
        address indexed streamer,
        address indexed token,
        address indexed friend,
        uint256 amount
    );
    event Streamed(
        address indexed token,
        address indexed streamer,
        address indexed friend,
        uint256 amount
    );

    event NewFeeAddress(address indexed oldFeeAddress, address indexed newFeeAddress);
    event NewFee(uint256 oldFee, uint256 newFee);

    error TokenNotZero();
    error FriendZero();
    error StreamerZero();
    error StreamNotExisting();
    error NoAllowableAmountToWithdraw();
    error NotFeeAddress();
    error AmountIsZero();
    error FeeAddressIsZero();

    constructor(address payable feeAddrs) {
        feeAddress = feeAddrs;
    }

    function computeHash(
        address streamer,
        address token,
        address friend
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(streamer, token, friend));
    }

    function allowStream(
        address token,
        address friend,
        uint256 amount,
        uint256 window,
        bool once
    ) external {
        if (token == address(0)) {
            revert TokenNotZero();
        }
        if (friend == address(0)) {
            revert FriendZero();
        }

        bytes32 hash = computeHash(msg.sender, token, friend);
        if (streamDetails[hash].streamer == address(0)) {
            streamDetails[hash] = StreamDetails({
                streamer: msg.sender,
                friend: friend,
                token: token,
                totalStreamed: 0,
                outstanding: amount,
                allowable: amount,
                window: window,
                timestamp: block.timestamp,
                once: once
            });
            streamDetailsByStreamer[msg.sender].push(hash);
            streamDetailsByFriend[friend].push(hash);
        } else {
            streamDetails[hash].allowable = amount;
            streamDetails[hash].outstanding = amount;
            streamDetails[hash].window = window;
            streamDetails[hash].timestamp = block.timestamp;
            streamDetails[hash].once = once;
        }

        emit StreamAllowed(msg.sender, token, friend, amount);
    }

    function stream(address token, address streamer, address friend) external nonReentrant {
        if (token == address(0)) {
            revert TokenNotZero();
        }
        if (streamer == address(0)) {
            revert StreamerZero();
        }
        if (friend == address(0)) {
            revert FriendZero();
        }

        bytes32 hash = computeHash(streamer, token, friend);
        StreamDetails storage details = streamDetails[hash];

        if (details.streamer == address(0)) {
            revert StreamNotExisting();
        }

        uint256 currentTime = block.timestamp;
        uint256 elapsedTime = currentTime - details.timestamp;
        uint256 allowableAmount = (details.allowable * elapsedTime) /
                        details.window;

        if (allowableAmount > details.outstanding && details.once == true) {
            allowableAmount = details.outstanding;
        }


        if (allowableAmount == 0) {
            revert NoAllowableAmountToWithdraw();
        }

        if (details.once) {
            details.outstanding -= allowableAmount;
        }

        details.totalStreamed += allowableAmount;
        details.timestamp = currentTime;
        IERC20(token).safeTransferFrom(streamer, friend, allowableAmount);

        if (fee > 0) {
            uint256 feeAmount = (allowableAmount * fee) / 1000;
            IERC20(token).safeTransferFrom(streamer, feeAddress, feeAmount);
        }

        emit Streamed(token, streamer, friend, allowableAmount);
    }

    function getAvailable(
        address token,
        address streamer,
        address friend
    ) external view returns (uint256) {
        if (token == address(0)) {
            revert TokenNotZero();
        }
        if (streamer == address(0)) {
            revert StreamerZero();
        }
        if (friend == address(0)) {
            revert FriendZero();
        }

        bytes32 hash = computeHash(streamer, token, friend);
        StreamDetails storage details = streamDetails[hash];

        if (details.streamer == address(0)) {
            revert StreamNotExisting();
        }

        uint256 currentTime = block.timestamp;
        uint256 elapsedTime = currentTime - details.timestamp;
        uint256 allowableAmount = (details.allowable * elapsedTime) /
                        details.window;

        if (allowableAmount > details.outstanding && details.once) {
            allowableAmount = details.outstanding;
        }

        return allowableAmount;
    }

    function viewStreamerAllowances(
        address streamer
    ) public view returns (bytes32[] memory) {
        return streamDetailsByStreamer[streamer];
    }

    function viewFriendAllowances(
        address friend
    ) public view returns (bytes32[] memory) {
        return streamDetailsByFriend[friend];
    }

    function setFee(uint newFee) public {
        if (msg.sender != feeAddress) {
            revert NotFeeAddress();
        }

        uint256 oldFee = fee;
        fee = newFee <= 50 ? newFee : 50;

        emit NewFee(oldFee, newFee);
    }

    function setFeeAddress(address newFeeAddress) public {
        if (msg.sender != feeAddress) {
            revert NotFeeAddress();
        }
        if (newFeeAddress == address(0)) {
            revert FeeAddressIsZero();
        }

        address oldFeeAddress = feeAddress;
        feeAddress = payable(newFeeAddress);

        emit NewFeeAddress(oldFeeAddress, newFeeAddress);
    }
}
