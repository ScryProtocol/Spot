// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Spot
 * @notice A simple lending contract that supports time-based interest
 *         plus an optional platform fee *on the actual repay amount*.
 *
 *         1) Accrued interest is tracked separately in `interestAccrued`.
 *         2) Fee is `fee%` of the *repayAmount* (i.e., how much the user is paying now).
 *         3) Repayments go to interest first, then principal, then fee is sent to `feeAddress`.
 */
interface IERC20Metadata {
    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

contract Spot {
    using SafeERC20 for IERC20;

    // ~1 year in seconds (365 days).
    uint256 private constant YEAR = 365 days;

    struct BorrowDetails {
        address lender;
        address friend;
        address token;

        uint256 totalBorrowed;         // total principal ever borrowed
        uint256 outstanding;           // current principal (no accrued interest included)
        uint256 allowable;             // max principal allowed

        uint256 interestRate;          // annual interest rate in BPS out of 1000 (e.g. 50 => 5% APR)
        uint256 lastAccrualTimestamp;  // last time we updated interestAccrued
        uint256 interestAccrued;       // accrued interest (unpaid) tracked separately
    }

    /// Mapping of (lender, token, friend) => BorrowDetails
    mapping(bytes32 => BorrowDetails) public borrowDetails;
    mapping(address => bytes32[]) public borrowDetailsByLender;
    mapping(address => bytes32[]) public borrowDetailsByFriend;

    /// @dev Address that collects the platform fee
    address payable public feeAddress;
    /// @dev Global platform fee in basis points out of 1000 (e.g. 50 = 5%)
    uint256 public fee;

    // ------------------------------------------------------------------------
    // EVENTS
    // ------------------------------------------------------------------------
    event BorrowAllowed(
        address indexed lender,
        address indexed token,
        address indexed friend,
        uint256 amount,
        uint256 interestRate
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

    // ------------------------------------------------------------------------
    // ERRORS
    // ------------------------------------------------------------------------
    error TokenNotZero();
    error FriendZero();
    error LenderZero();
    error NotEnoughAllowableAmount();
    error NotFriend();
    error NotFeeAddress();
    error AmountIsZero();
    error FeeAddressIsZero();

    // ------------------------------------------------------------------------
    // CONSTRUCTOR
    // ------------------------------------------------------------------------
    constructor(address payable feeAddrs) {
        feeAddress = feeAddrs;
    }

    // ------------------------------------------------------------------------
    // CORE FUNCTIONS
    // ------------------------------------------------------------------------
    /**
     * @dev Helper to compute the unique hash for a (lender, token, friend).
     */
    function computeHash(
        address lender,
        address token,
        address friend
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(lender, token, friend));
    }

    /**
     * @notice Lender sets allowable borrow amount for a friend, with an annual interestRate.
     * @param token ERC20 token address
     * @param friend The friend (borrower)
     * @param amount The maximum principal allowed
     * @param interestRate Annual interest rate in BPS out of 1000 (e.g. 50 => 5% APR)
     */
    function allowBorrow(
        address token,
        address friend,
        uint256 amount,
        uint256 interestRate
    ) external {
        if (token == address(0)) revert TokenNotZero();
        if (friend == address(0)) revert FriendZero();

        bytes32 hash = computeHash(msg.sender, token, friend);
        BorrowDetails storage details = borrowDetails[hash];

        // If new relationship, initialize
        if (details.lender == address(0)) {
            details.lender = msg.sender;
            details.friend = friend;
            details.token = token;
            details.totalBorrowed = 0;
            details.outstanding = 0;
            details.allowable = amount;
            details.interestRate = interestRate;
            details.lastAccrualTimestamp = block.timestamp;
            details.interestAccrued = 0;

            borrowDetailsByLender[msg.sender].push(hash);
            borrowDetailsByFriend[friend].push(hash);
        } else {
            // If already exists, let's accrue interest first
            _accrueInterest(hash);

            // Then update allowable & interestRate
            details.allowable = amount;
            details.interestRate = interestRate;
        }

        emit BorrowAllowed(msg.sender, token, friend, amount, interestRate);
    }

    /**
     * @notice Borrower borrows some amount from a lender's allowable
     */
    function borrow(
        address token,
        address lender,
        uint256 amount
    ) external {
        if (token == address(0)) revert TokenNotZero();
        if (lender == address(0)) revert LenderZero();
        if (amount == 0) revert AmountIsZero();

        bytes32 hash = computeHash(lender, token, msg.sender);
        BorrowDetails storage details = borrowDetails[hash];

        // Must be correct friend
        if (details.friend != msg.sender) revert NotFriend();

        // Accrue interest so interest is up to date
        _accrueInterest(hash);

        // Check leftover allowable
        if (details.allowable < details.outstanding + amount) {
            revert NotEnoughAllowableAmount();
        }

        // Increase outstanding & totalBorrowed
        details.totalBorrowed += amount;
        details.outstanding += amount;

        // Update accrual timestamp
        details.lastAccrualTimestamp = block.timestamp;

        // Transfer from lender to borrower
        IERC20(token).safeTransferFrom(lender, msg.sender, amount);

        emit Borrowed(token, lender, msg.sender, amount);
    }

    /**
     * @notice Repay `amount`, with fee on the repay amount (not the total owed).
     *
     *  1) feePayment = (amount * fee) / 1000
     *  2) amountForLender = amount - feePayment
     *  3) Pay off interest first, then principal from `amountForLender`.
     */
    function repay(
        address token,
        address lender,
        uint256 amount
    ) external {
        if (token == address(0)) revert TokenNotZero();
        if (lender == address(0)) revert LenderZero();
        if (amount == 0) revert AmountIsZero();

        bytes32 hash = computeHash(lender, token, msg.sender);
        BorrowDetails storage details = borrowDetails[hash];

        // Bring interest current
        _accrueInterest(hash);

        uint256 principalOwed = details.outstanding;
        uint256 interestOwed = details.interestAccrued;

        // ------------------------------------------------------
        // Step 1: Calculate fee on the repay amount
        // ------------------------------------------------------
        uint256 feePayment = 0;
        if (fee > 0) {
            feePayment = (amount * fee) / 1000;
        }
        // Ensure we don't overflow
        if (feePayment > amount) {
            feePayment = amount;
        }

        // Transfer fee first from msg.sender -> feeAddress
        if (feePayment > 0) {
            IERC20(token).safeTransferFrom(msg.sender, feeAddress, feePayment);
        }

        // ------------------------------------------------------
        // Step 2: Use leftover to pay interest first, then principal
        // ------------------------------------------------------
        uint256 amountForLender = amount - feePayment;
        if (amountForLender == 0) {
            // Nothing left to pay interest or principal
            emit Repaid(token, lender, msg.sender, amount);
            return;
        }

        // Interest payment
        uint256 interestPayment = (amountForLender > interestOwed)
            ? interestOwed
            : amountForLender;

        // Then whatever is left goes to principal
        uint256 principalPayment = 0;
        if (interestPayment < amountForLender) {
            principalPayment = amountForLender - interestPayment;
            if (principalPayment > principalOwed) {
                principalPayment = principalOwed;
            }
        }

        // Transfer interest+principal to lender
        uint256 totalToLender = interestPayment + principalPayment;
        if (totalToLender > 0) {
            IERC20(token).safeTransferFrom(msg.sender, lender, totalToLender);
        }

        // Update storage
        details.interestAccrued = interestOwed - interestPayment;
        details.outstanding = principalOwed - principalPayment;

        // If fully paid, reset last accrual
        if (details.interestAccrued == 0 && details.outstanding == 0) {
            details.lastAccrualTimestamp = 0;
        } else {
            details.lastAccrualTimestamp = block.timestamp;
        }

        emit Repaid(token, lender, msg.sender, amount);
    }

    /**
     * @dev Internal function to accrue time-based interest into `interestAccrued`.
     *
     * Formula:
     *   newInterest = outstanding * (interestRate/1000) * (timeElapsed / YEAR)
     *
     * Where `interestRate` is out of 1000 (e.g. 50 => 5%).
     */
    function _accrueInterest(bytes32 hash) internal {
        BorrowDetails storage details = borrowDetails[hash];

        // If there's no prior timestamp or no outstanding principal => no interest
        if (details.lastAccrualTimestamp == 0 || details.outstanding == 0) {
            if (details.outstanding > 0 && details.lastAccrualTimestamp == 0) {
                details.lastAccrualTimestamp = block.timestamp;
            }
            return;
        }

        uint256 timeElapsed = block.timestamp - details.lastAccrualTimestamp;
        if (timeElapsed == 0) {
            return; // no time passed
        }

        // interestRate out of 1000, e.g. 50 => 5% APR
        uint256 newInterest = (
            (details.outstanding * details.interestRate * timeElapsed)
            / (YEAR * 1000)
        );

        if (newInterest > 0) {
            details.interestAccrued += newInterest;
        }

        details.lastAccrualTimestamp = block.timestamp;
    }

    // ------------------------------------------------------------------------
    // VIEW FUNCTIONS
    // ------------------------------------------------------------------------
    function viewLenderAllowances(address lender) external view returns (bytes32[] memory) {
        return borrowDetailsByLender[lender];
    }

    function viewFriendAllowances(address friend) external view returns (bytes32[] memory) {
        return borrowDetailsByFriend[friend];
    }

    function getSpotInfo(
        bytes32[] memory hashes
    )
        external
        view
        returns (
            BorrowDetails[] memory detailsArray,
            uint256[] memory updatedInterest,
            uint256[] memory updatedTotalOwed,
            uint256[] memory decimalsArr,
            string[] memory names,
            string[] memory symbols
        )
    {
        uint256 length = hashes.length;

        detailsArray = new BorrowDetails[](length);
        updatedInterest = new uint256[](length);
        updatedTotalOwed = new uint256[](length);
        decimalsArr = new uint256[](length);
        names = new string[](length);
        symbols = new string[](length);

        for (uint256 i = 0; i < length; i++) {
            bytes32 hash = hashes[i];
            BorrowDetails memory detail = borrowDetails[hash];
            detailsArray[i] = detail;

            // If no lender, then just default
            if (detail.lender == address(0)) {
                updatedInterest[i] = 0;
                updatedTotalOwed[i] = 0;
                decimalsArr[i] = 18;
                names[i] = "Unknown";
                symbols[i] = "UNKNOWN";
                continue;
            }

            // Calculate how much interest would be accrued if we do it now
            uint256 extraInterest = 0;
            if (detail.lastAccrualTimestamp != 0 && detail.outstanding > 0) {
                uint256 timeElapsed = block.timestamp - detail.lastAccrualTimestamp;
                extraInterest = (
                    (detail.outstanding * detail.interestRate * timeElapsed)
                    / (YEAR * 1000)
                );
            }
            updatedInterest[i] = detail.interestAccrued + extraInterest;
            updatedTotalOwed[i] = detail.outstanding + updatedInterest[i];

            // Token metadata
            try IERC20Metadata(detail.token).decimals() returns (uint8 dec) {
                decimalsArr[i] = uint256(dec);
            } catch {
                decimalsArr[i] = 18; // fallback
            }

            try IERC20Metadata(detail.token).name() returns (string memory _name) {
                names[i] = _name;
            } catch {
                names[i] = "Unknown";
            }

            try IERC20Metadata(detail.token).symbol() returns (string memory _symbol) {
                symbols[i] = _symbol;
            } catch {
                symbols[i] = "UNKNOWN";
            }
        }
    }

    // ------------------------------------------------------------------------
    // ADMIN FUNCTIONS
    // ------------------------------------------------------------------------
    /**
     * @notice Set platform fee (only feeAddress can call)
     * @param newFee Fee in basis points out of 1000 (e.g. 50 = 5%)
     */
    function setFee(uint256 newFee) external {
        if (msg.sender != feeAddress) {
            revert NotFeeAddress();
        }

        uint256 oldFee = fee;
        // example: cap fee at 50 => 5%
        fee = newFee <= 50 ? newFee : 50;
        emit NewFee(oldFee, fee);
    }

    /**
     * @notice Set the address that collects the platform fee.
     * @param newFeeAddress The new fee-collector address
     */
    function setFeeAddress(address newFeeAddress) external {
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
