// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Spot is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct BorrowDetails {
        address lender;
        address friend;
        address token;
        uint256 totalBorrowed;
        uint256 outstanding;
        uint256 allowable;
    }

    mapping(bytes32 => BorrowDetails) public borrowDetails;
    mapping(address => bytes32[]) public borrowDetailsByLender;
    mapping(address => bytes32[]) public borrowDetailsByFriend;
    address payable public feeAddress;
    uint256 public fee;

    event BorrowAllowed(
        address indexed lender,
        address indexed token,
        address indexed friend,
        uint256 amount
    );
    event Borrowed(
        address indexed token,
        address indexed lender,
        address indexed borrower,
        uint256 amount
    );
    event Repaid(
        address indexed token,
        address indexed lender,
        address indexed borrower,
        uint256 amount
    );

    event NewFeeAddress(address indexed oldFeeAddress, address indexed newFeeAddress);
    event NewFee(uint256 oldFee, uint256 newFee);

    error TokenNotZero();
    error FriendZero();
    error LenderZero();
    error NotEnoughAllowableAmount();
    error NotFriend();
    error NotFeeAddress();
    error AmountIsZero();
    error FeeAddressIsZero();

    constructor(address payable feeAddrs) {
        feeAddress = feeAddrs;
    }

    function computeHash(
        address lender,
        address token,
        address friend
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(lender, token, friend));
    }

    function allowBorrow(
        address token,
        address friend,
        uint256 amount
    ) external {
        if (token == address(0)) {
            revert TokenNotZero();
        }
        if (friend == address(0)) {
            revert FriendZero();
        }

        bytes32 hash = computeHash(msg.sender, token, friend);

        if (borrowDetails[hash].lender == address(0)) {
            borrowDetails[hash] = BorrowDetails({
                lender: msg.sender,
                friend: friend,
                token: token,
                totalBorrowed: 0,
                outstanding: 0,
                allowable: amount
            });

            borrowDetailsByLender[msg.sender].push(hash);
            borrowDetailsByFriend[friend].push(hash);
        } else {
            borrowDetails[hash].allowable = amount;
        }
        emit BorrowAllowed(msg.sender, token, friend, amount);
    }

    function borrow(address token, address lender, uint256 amount) external nonReentrant {
        if (token == address(0)) {
            revert TokenNotZero();
        }
        if (lender == address(0)) {
            revert LenderZero();
        }

        bytes32 hash = computeHash(lender, token, msg.sender);

        if (borrowDetails[hash].allowable - borrowDetails[hash].outstanding < amount) {
            revert NotEnoughAllowableAmount();
        }
        if (borrowDetails[hash].friend != msg.sender) {
            revert NotFriend();
        }

        borrowDetails[hash].totalBorrowed += amount;
        borrowDetails[hash].outstanding += amount;
        IERC20(token).safeTransferFrom(lender, msg.sender, amount);

        emit Borrowed(token, lender, msg.sender, amount);
    }

    function repay(address token, address lender, uint256 amount) external nonReentrant {
        if (token == address(0)) {
            revert TokenNotZero();
        }
        if (lender == address(0)) {
            revert LenderZero();
        }
        if (amount == 0) {
            revert AmountIsZero();
        }

        bytes32 hash = computeHash(lender, token, msg.sender);
        if (fee == 0) {
            if (borrowDetails[hash].outstanding <= amount) {
                amount = borrowDetails[hash].outstanding;
            }

            IERC20(token).safeTransferFrom(msg.sender, lender, amount);
            borrowDetails[hash].outstanding -= amount;
        } else {
            if (
                borrowDetails[hash].outstanding +
                (borrowDetails[hash].outstanding * fee) /
                1000 <=
                amount
            ) {
                IERC20(token).safeTransferFrom(
                    msg.sender,
                    lender,
                    borrowDetails[hash].outstanding
                );

                IERC20(token).safeTransferFrom(
                    msg.sender,
                    feeAddress,
                    (borrowDetails[hash].outstanding * fee) / 1000
                );
                borrowDetails[hash].outstanding -= borrowDetails[hash]
                    .outstanding;
            } else {
                IERC20(token).safeTransferFrom(
                    msg.sender,
                    lender,
                    amount - (amount * fee) / 1000
                );
                IERC20(token).safeTransferFrom(
                    msg.sender,
                    feeAddress,
                    (amount * fee) / 1000
                );
                borrowDetails[hash].outstanding -=
                    amount -
                    (amount * fee) /
                    1000;
            }
        }
        emit Repaid(token, lender, msg.sender, amount);
    }

    function viewLenderAllowances(
        address lender
    ) public view returns (bytes32[] memory) {
        return borrowDetailsByLender[lender];
    }

    function viewFriendAllowances(
        address friend
    ) public view returns (bytes32[] memory) {
        return borrowDetailsByFriend[friend];
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
