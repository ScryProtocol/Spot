// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============================================
// OpenZeppelin Imports (only IERC20 now)
// ============================================
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ============================================
// Chainlink Price Feed Interface
// ============================================
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

// ============================================
// Minimal Interfaces
// ============================================
interface ISpotIOULoan {
    function drawDown(uint256 amount) external;
    function totalOwed() external view returns (uint256);
    function repayLoan(uint256 amount) external;
    function loanToken() external view returns (address);
    function loanGoal() external view returns (uint256);
    function totalFunded() external view returns (uint256);
    function totalDrawnDown() external view returns (uint256);
    function annualInterestRate() external view returns (uint256);
    function redeemIOUs(uint256 iouAmount) external;
    function drop(uint256 iouAmount) external;
    function fundLoan(uint256 amount) external;
    function updateGoal(uint256 newGoal) external;
    function decimals() external view returns (uint8);
}

interface IOUMint {
    function deployLoan(
        address _loanToken,
        address _borrower,
        uint256 _loanGoal,
        uint256 _annualInterestRate,
        uint256 _platformFeeRate,
        address _feeAddress,
        string memory _name,
        string memory _symbol,
        bool flexible
    ) external returns (address);
}

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}

/**
 * @title DAOLoanManager with AccessControl, per-loan buy/sell/profit tracking
 *
 * @notice Example that:
 *  - Uses a MANAGER_ROLE (AccessControl) for loan creation / drawdown / repay / etc.
 *  - Tracks buyETH, soldETH, profitETH for each loan individually.
 *  - Updates the calls to accept a `loanIndex` for buyETH.
 */
abstract contract ERC20 {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error TotalSupplyOverflow();
    error AllowanceOverflow();
    error AllowanceUnderflow();
    error InsufficientBalance();
    error InsufficientAllowance();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    // keccak256("Transfer(address,address,uint256)")
    uint256 private constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    // keccak256("Approval(address,address,uint256)")
    uint256 private constant _APPROVAL_EVENT_SIGNATURE =
        0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    uint256 private constant _TOTAL_SUPPLY_SLOT = 0x05345cdf77eb68f44c;
    uint256 private constant _BALANCE_SLOT_SEED = 0x87a211a2;
    uint256 private constant _ALLOWANCE_SLOT_SEED = 0x7f5e9f20;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       ERC20 METADATA                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function name() public view virtual returns (string memory);
    function symbol() public view virtual returns (string memory);
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           ERC20                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function totalSupply() public view virtual returns (uint256 result) {
        assembly {
            result := sload(_TOTAL_SUPPLY_SLOT)
        }
    }

    function balanceOf(
        address owner
    ) public view virtual returns (uint256 result) {
        assembly {
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, owner)
            result := sload(keccak256(0x0c, 0x20))
        }
    }

    function allowance(
        address owner,
        address spender
    ) public view virtual returns (uint256 result) {
        assembly {
            mstore(0x20, spender)
            mstore(0x0c, _ALLOWANCE_SLOT_SEED)
            mstore(0x00, owner)
            result := sload(keccak256(0x0c, 0x34))
        }
    }

    function approve(
        address spender,
        uint256 amount
    ) public virtual returns (bool) {
        assembly {
            mstore(0x20, spender)
            mstore(0x0c, _ALLOWANCE_SLOT_SEED)
            mstore(0x00, caller())
            sstore(keccak256(0x0c, 0x34), amount)

            mstore(0x00, amount)
            log3(
                0x00,
                0x20,
                _APPROVAL_EVENT_SIGNATURE,
                caller(),
                shr(96, mload(0x2c))
            )
        }
        return true;
    }

    function transfer(
        address to,
        uint256 amount
    ) public virtual returns (bool) {
        assembly {
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, caller())
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8)
                revert(0x1c, 0x04)
            }
            sstore(fromBalanceSlot, sub(fromBalance, amount))

            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            sstore(toBalanceSlot, add(sload(toBalanceSlot), amount))

            mstore(0x20, amount)
            log3(
                0x20,
                0x20,
                _TRANSFER_EVENT_SIGNATURE,
                caller(),
                shr(96, mload(0x0c))
            )
        }
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual returns (bool) {
        assembly {
            let from_ := shl(96, from)
            mstore(0x20, caller())
            mstore(0x0c, or(from_, _ALLOWANCE_SLOT_SEED))
            let allowanceSlot := keccak256(0x0c, 0x34)
            let allowance_ := sload(allowanceSlot)

            if not(allowance_) {
                if gt(amount, allowance_) {
                    mstore(0x00, 0x13be252b)
                    revert(0x1c, 0x04)
                }
                sstore(allowanceSlot, sub(allowance_, amount))
            }

            mstore(0x0c, or(from_, _BALANCE_SLOT_SEED))
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8)
                revert(0x1c, 0x04)
            }
            sstore(fromBalanceSlot, sub(fromBalance, amount))

            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            sstore(toBalanceSlot, add(sload(toBalanceSlot), amount))

            mstore(0x20, amount)
            log3(
                0x20,
                0x20,
                _TRANSFER_EVENT_SIGNATURE,
                shr(96, from_),
                shr(96, mload(0x0c))
            )
        }
        return true;
    }

    /* INTERNAL MINT FUNCTIONS */
    function _mint(address to, uint256 amount) internal virtual {
        assembly {
            let totalSupplyBefore := sload(_TOTAL_SUPPLY_SLOT)
            let totalSupplyAfter := add(totalSupplyBefore, amount)
            if lt(totalSupplyAfter, totalSupplyBefore) {
                mstore(0x00, 0xe5cfe957)
                revert(0x1c, 0x04)
            }
            sstore(_TOTAL_SUPPLY_SLOT, totalSupplyAfter)

            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            sstore(toBalanceSlot, add(sload(toBalanceSlot), amount))

            mstore(0x20, amount)
            log3(0x20, 0x20, _TRANSFER_EVENT_SIGNATURE, 0, shr(96, mload(0x0c)))
        }
    }

    /* INTERNAL BURN FUNCTIONS */
    function _burn(address from, uint256 amount) internal virtual {
        assembly {
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, from)
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8)
                revert(0x1c, 0x04)
            }
            sstore(fromBalanceSlot, sub(fromBalance, amount))
            sstore(_TOTAL_SUPPLY_SLOT, sub(sload(_TOTAL_SUPPLY_SLOT), amount))

            mstore(0x00, amount)
            log3(
                0x00,
                0x20,
                _TRANSFER_EVENT_SIGNATURE,
                shr(96, shl(96, from)),
                0
            )
        }
    }

    /* INTERNAL TRANSFER FUNCTIONS */
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        assembly {
            let from_ := shl(96, from)
            mstore(0x0c, or(from_, _BALANCE_SLOT_SEED))
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8)
                revert(0x1c, 0x04)
            }
            sstore(fromBalanceSlot, sub(fromBalance, amount))

            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            sstore(toBalanceSlot, add(sload(toBalanceSlot), amount))

            mstore(0x20, amount)
            log3(
                0x20,
                0x20,
                _TRANSFER_EVENT_SIGNATURE,
                shr(96, from_),
                shr(96, mload(0x0c))
            )
        }
    }

    /* INTERNAL ALLOWANCE FUNCTIONS */
    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        assembly {
            mstore(0x20, spender)
            mstore(0x0c, _ALLOWANCE_SLOT_SEED)
            mstore(0x00, owner)
            let allowanceSlot := keccak256(0x0c, 0x34)
            let allowance_ := sload(allowanceSlot)
            if not(allowance_) {
                if gt(amount, allowance_) {
                    mstore(0x00, 0x13be252b)
                    revert(0x1c, 0x04)
                }
                sstore(allowanceSlot, sub(allowance_, amount))
            }
        }
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        assembly {
            let owner_ := shl(96, owner)
            mstore(0x20, spender)
            mstore(0x0c, or(owner_, _ALLOWANCE_SLOT_SEED))
            sstore(keccak256(0x0c, 0x34), amount)
            mstore(0x00, amount)
            log3(
                0x00,
                0x20,
                _APPROVAL_EVENT_SIGNATURE,
                shr(96, owner_),
                shr(96, mload(0x2c))
            )
        }
    }
}

contract Gigastrat5 is ERC20 {
    // =========================
    //  Structs / Storage
    // =========================
    struct LoanInfo {
        address loanAddress;
        uint256 loanGoal;
        uint256 totalDrawnDown;
        bool loanDrawn;
        uint256 loanDrawnTime;
        bool fullyRepaid;
        uint256 iouConversionRate;
        uint256 totalBuyETH;
        uint256 soldETH;
        uint256 profitETH;
        uint256 lossETH;
    }

    LoanInfo[] public loans;

    IOUMint public ioUMint;
    address public usdcToken;
    ISwapRouter public swapRouter;
    address public wethAddress;
    AggregatorV3Interface public priceFeed;
address feeAddress = 0x9D31e30003f253563Ff108BC60B16Fdf2c93abb5;
    uint256 public ethFromMint;

    uint256 public constant SLIPPAGE = 1e16;
    uint256 public constant NO_DEADLINE = type(uint256).max;
    uint24 public constant POOL_FEE = 500;

    mapping(address => uint256) public role;

    event LoanStarted(address indexed loanAddress, uint256 loanIndex);
    event LoanDrawn(uint256 amount, uint256 drawTime, uint256 loanIndex);
    event BoughtETH(uint256 loanIndex, uint256 usdcSpent, uint256 ethReceived);
    event LoanRepaid(uint256 loanIndex, uint256 usdcUsed);
    event IOUSwapped(
        address indexed user,
        address indexed loanAddress,
        uint256 iouAmount,
        uint256 daoMinted,
        uint256 loanIndex
    );
    event ConversionRateUpdated(uint256 loanIndex, uint256 newRate);
    event RedeemedAndSwapped(
        uint256 iouRedeemed,
        uint256 usdcReceived,
        uint256 ethReceived
    );
    event BurnedForETH(
        address indexed user,
        uint256 daoBurned,
        uint256 ethReceived
    );
    event ProfitFinalized(uint256 loanIndex, uint256 profitETH);

    constructor(
        address _ioUMint,
        address _usdcToken,
        address _uniswapV3Router,
        address _wethAddress,
        address _priceFeedAddress
    ) {
        ioUMint = IOUMint(_ioUMint);
        usdcToken = _usdcToken;
        swapRouter = ISwapRouter(_uniswapV3Router);
        wethAddress = _wethAddress;
        priceFeed = AggregatorV3Interface(_priceFeedAddress);

        // Example initial state
        role[address(this)] = 2;
        role[0x9D31e30003f253563Ff108BC60B16Fdf2c93abb5] = 2;
        role[0x00000000000000C0D7D3017B342ff039B55b0879] = 1;

        // Start 1 example loan for demonstration
        role[msg.sender] = 2;
        startLoan(50000000000000, usdcToken, 0, 0, address(this), 1e18);
        role[msg.sender] = 0;
    }

    // =========================
    //     Price Feed
    // =========================
    function getLatestPrice() public view returns (int256) {
        (, int256 answer, , , ) = priceFeed.latestRoundData();
        return answer;
    }

    modifier onlyRole(uint256 _role) {
        require(role[msg.sender] == _role, "Not authorized");
        _;
    }

    function setRole(address _address, uint256 _role) external onlyRole(1) {
        role[_address] = _role;
        _role==3?feeAddress=_address:feeAddress=feeAddress;
    }

    // =========================
    //  Multi-Loan Management
    // =========================
    function startLoan(
        uint256 _loanGoal,
        address _token,
        uint256 _annualInterestRate,
        uint256 _platformFeeRate,
        address _feeAddress,
        uint256 _loanIOUConversionRate
    ) public onlyRole(2) {
        address deployedLoan = ioUMint.deployLoan(
            _token,
            address(this),
            _loanGoal,
            _annualInterestRate,
            _platformFeeRate,
            _feeAddress,
            "GigaStrat",
            "GG",
            false
        );

        loans.push(
            LoanInfo({
                loanAddress: deployedLoan,
                loanGoal: _loanGoal,
                totalDrawnDown: 0,
                loanDrawn: false,
                loanDrawnTime: 0,
                fullyRepaid: false,
                iouConversionRate: _loanIOUConversionRate,
                totalBuyETH: 0,
                soldETH: 0,
                profitETH: 0,
                lossETH: 0
            })
        );

        emit LoanStarted(deployedLoan, loans.length - 1);
    }

    function openLoan() external {
        require(
            ISpotIOULoan(loans[loans.length - 1].loanAddress).loanGoal() -
                ISpotIOULoan(loans[loans.length - 1].loanAddress)
                    .totalFunded() ==
                0
        );
        uint256 _loanGoal;
        uint256 _annualInterestRate;
        uint256 _iouConversionRate;
        uint256 totalDistribution = getProfit();
        _iouConversionRate =
            (((uint256(getLatestPrice()) * 10 ** 10 * totalDistribution) /
                totalSupply()) * 15) /
            10;

        _loanGoal = 10000000000000000;
  //          (uint256(getLatestPrice()) * address(this).balance) /
  //          (10 ** 20) /
  //          10;
  //      _loanGoal = _loanGoal < 10000000000000 ? 10000000000000 : _loanGoal;

        _annualInterestRate = ISpotIOULoan(loans[loans.length - 1].loanAddress)
            .annualInterestRate();

        address deployedLoan = ioUMint.deployLoan(
            usdcToken,
            address(this),
            _loanGoal,
            _annualInterestRate,
            0,
            address(this),
            "GigaStrat",
            "GG",
            false
        );

        loans.push(
            LoanInfo({
                loanAddress: deployedLoan,
                loanGoal: _loanGoal,
                totalDrawnDown: 0,
                loanDrawn: false,
                loanDrawnTime: 0,
                fullyRepaid: false,
                iouConversionRate: _iouConversionRate,
                totalBuyETH: 0,
                soldETH: 0,
                profitETH: 0,
                lossETH: 0
            })
        );

        emit LoanStarted(deployedLoan, loans.length - 1);
    }

    function fundLoan(uint256 loanIndex, uint amount) external {
        IERC20(usdcToken).transferFrom(msg.sender, address(this), amount);
        IERC20(usdcToken).approve(loans[loanIndex].loanAddress, amount);
        ISpotIOULoan(loans[loanIndex].loanAddress).fundLoan(amount);
        IERC20(loans[loanIndex].loanAddress).transfer(
            msg.sender,
            IERC20(loans[loanIndex].loanAddress).balanceOf(address(this))
        );
        this.drawDownLoan(loanIndex, amount);
        this.buyETH(loanIndex, amount);
    }

    function drawDownLoan(
        uint256 loanIndex,
        uint256 amount
    ) public onlyRole(2) {
        require(loanIndex < loans.length, "Invalid loan index");
        LoanInfo storage ln = loans[loanIndex];

        ISpotIOULoan(ln.loanAddress).drawDown(amount);
        ln.totalDrawnDown += amount;

        if (!ln.loanDrawn) {
            ln.loanDrawn = true;
            ln.loanDrawnTime = block.timestamp;
        }

        emit LoanDrawn(amount, block.timestamp, loanIndex);
    }

    // =========================
    //    Swapping / Repayment
    // =========================
    function buyETH(uint256 loanIndex, uint256 usdcAmount) public onlyRole(2) {
        require(loanIndex < loans.length, "Invalid loan index");
        require(usdcAmount > 0, "USDC amount must be > 0");

        // Approve the router
        IERC20(usdcToken).approve(address(swapRouter), usdcAmount);

        int256 latestPrice = getLatestPrice();
        require(latestPrice > 0, "Invalid oracle price");

        uint256 expectedETH = (usdcAmount * 1e20) / uint256(latestPrice);
        uint256 minETHOut = (expectedETH * (1e18 - SLIPPAGE)) / 1e18;

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: usdcToken,
                tokenOut: wethAddress,
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: usdcAmount,
                amountOutMinimum: minETHOut,
                sqrtPriceLimitX96: 0
            });

        uint256 wethReceived = swapRouter.exactInputSingle(params);

        IWETH(wethAddress).withdraw(wethReceived);

        loans[loanIndex].totalBuyETH += wethReceived;

        emit BoughtETH(loanIndex, usdcAmount, wethReceived);
    }

    function repayLoanUSDC(
        uint256 loanIndex,
        uint256 usdcAmount
    ) public onlyRole(2) {
        require(loanIndex < loans.length, "Invalid loan index");
        LoanInfo storage ln = loans[loanIndex];
        require(ln.loanDrawn, "Loan not drawn down");

        int256 latestPrice = getLatestPrice();
        require(latestPrice > 0, "Invalid price from oracle");

        uint256 requiredETHExact = (usdcAmount * 1e20) / uint256(latestPrice);
        uint256 requiredETH = (requiredETHExact * 1e18) / (1e18 - SLIPPAGE);

        IWETH(wethAddress).deposit{value: requiredETH}();
        IWETH(wethAddress).approve(address(swapRouter), requiredETH);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: wethAddress,
                tokenOut: usdcToken,
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: requiredETH,
                amountOutMinimum: usdcAmount,
                sqrtPriceLimitX96: 0
            });

        uint256 usdcReceived = swapRouter.exactInputSingle(params);
        require(usdcReceived >= usdcAmount, "Not enough USDC out");

        // Repay the loan
        IERC20(usdcToken).approve(ln.loanAddress, usdcReceived);
        ISpotIOULoan(ln.loanAddress).repayLoan(usdcReceived);

        emit LoanRepaid(loanIndex, usdcReceived);

        ln.soldETH += requiredETH;

        if (
            ISpotIOULoan(ln.loanAddress).totalOwed() == 0 &&
            ln.totalDrawnDown == ln.loanGoal
        ) {
            ln.fullyRepaid = true;
            if (ln.totalBuyETH > ln.soldETH) {
                ln.profitETH = ln.totalBuyETH - ln.soldETH;
            } else {
                ln.profitETH = 0;
                ln.lossETH = ln.soldETH - ln.totalBuyETH;
            }
            emit ProfitFinalized(loanIndex, ln.profitETH);
        }
    }

    mapping(uint256 => uint256) public repaid;

    function repayLoan(uint256 loanIndex) external {
        require(repaid[loanIndex] + 10 days <= block.timestamp);
        require(
            ISpotIOULoan(loans[loanIndex].loanAddress).totalOwed() > 0,
            "Loan fully repaid"
        );
        repaid[loanIndex] = block.timestamp;
        uint256 amount = ISpotIOULoan(loans[loanIndex].loanAddress)
            .totalFunded() / 100;
        amount = amount > ISpotIOULoan(loans[loanIndex].loanAddress).totalOwed()
            ? ISpotIOULoan(loans[loanIndex].loanAddress).totalOwed()
            : amount;
        this.repayLoanUSDC(loanIndex, amount);
    }

    function fill(
        uint256 loanIndex,
        uint256 amount,
        uint256 repayRedeemorBuy
    ) external payable {
        if (repayRedeemorBuy == 0) {
            // Repay portion
            require(
                ISpotIOULoan(loans[loanIndex].loanAddress).totalFunded() /
                    100 ==
                    amount,
                "Too much sent"
            );
            require(
                ISpotIOULoan(loans[loanIndex].loanAddress).totalOwed() > 0,
                "Loan fully repaid"
            );
            require(repaid[loanIndex] + 10 days <= block.timestamp);
            repaid[loanIndex] = block.timestamp;

            // Transfer USDC from user to this contract (no require check)
            IERC20(usdcToken).transferFrom(msg.sender, address(this), amount);

            // Repay loan
            IERC20(usdcToken).approve(loans[loanIndex].loanAddress, amount);
            ISpotIOULoan(loans[loanIndex].loanAddress).repayLoan(amount);

            // Send ETH to caller
            payable(msg.sender).transfer(
                (((amount * 10 ** 12) /
                    (uint256(getLatestPrice()) * 10 ** 10)) * 1005) / 1000
            );

            loans[loanIndex].soldETH +=
                (((amount * 10 ** 12) /
                    (uint256(getLatestPrice()) * 10 ** 10)) * 1005) /
                1000;

            emit LoanRepaid(loanIndex, amount);

            if (
                ISpotIOULoan(loans[loanIndex].loanAddress).totalOwed() == 0 &&
                loans[loanIndex].totalDrawnDown == loans[loanIndex].loanGoal
            ) {
                loans[loanIndex].fullyRepaid = true;
                if (loans[loanIndex].totalBuyETH > loans[loanIndex].soldETH) {
                    loans[loanIndex].profitETH =
                        loans[loanIndex].totalBuyETH -
                        loans[loanIndex].soldETH;
                } else {
                    loans[loanIndex].profitETH = 0;
                    loans[loanIndex].lossETH =
                        loans[loanIndex].soldETH -
                        loans[loanIndex].totalBuyETH;
                }
                emit ProfitFinalized(loanIndex, loans[loanIndex].profitETH);
            }
        } else if (repayRedeemorBuy == 1) {
            // Draw down from the loan
            require(
                (((uint256(getLatestPrice()) * 995) / 1000) * msg.value) /
                    10 ** 8 >=
                    amount,
                "Not enough sent"
            );
            require(
                ISpotIOULoan(loans[loanIndex].loanAddress).totalFunded() -
                    ISpotIOULoan(loans[loanIndex].loanAddress)
                        .totalDrawnDown() >=
                    amount,
                "Not enough funds"
            );

            this.drawDownLoan(loanIndex, amount);

            IERC20(usdcToken).transfer(msg.sender, amount);

            loans[loanIndex].totalBuyETH += msg.value;

            emit BoughtETH(loanIndex, amount, msg.value);
        }
    }

    // =========================
    //   IOU <-> DAO Swaps
    // =========================
    function swapIOUForMintTokens(
        uint256 loanIndex,
        uint256 iouAmount
    ) external {
        require(loanIndex < loans.length, "Invalid loan index");
        require(iouAmount > 0, "IOU amount must be > 0");

        LoanInfo storage ln = loans[loanIndex];

        // Transfer IOU from user to this contract
        IERC20(ln.loanAddress).transferFrom(
            msg.sender,
            address(this),
            iouAmount
        );

        // mintAmount = iouAmount * 1e18 / iouConversionRate
        uint256 mintAmount = (iouAmount * 10 ** 18) / ln.iouConversionRate;

        _mint(msg.sender, mintAmount);
        _mint(feeAddress, mintAmount / 10);
        uint amt = (iouAmount * loans[loanIndex].totalBuyETH) /
            IERC20(ln.loanAddress).totalSupply();
            loans[loanIndex].totalBuyETH -= amt;
        ISpotIOULoan(ln.loanAddress).drop(iouAmount);
        ISpotIOULoan(ln.loanAddress).updateGoal(
            ISpotIOULoan(ln.loanAddress).loanGoal() -
                iouAmount /
                10 **(18-
                    ISpotIOULoan(ISpotIOULoan(ln.loanAddress).loanToken()).decimals())
        );
        // Update ethFromMint
        ethFromMint += amt;
        emit IOUSwapped(
            msg.sender,
            ln.loanAddress,
            iouAmount,
            mintAmount,
            loanIndex
        );
    }

    // =========================
    //  DAO Token Redemption
    // =========================
    function burnForETH(uint256 daoTokenAmount) external {
        require(daoTokenAmount > 0, "DAO token amount must be > 0");
        require(
            balanceOf(msg.sender) >= daoTokenAmount,
            "Insufficient balance"
        );
        uint256 totalDistribution = getProfit();
        uint256 userShare = (daoTokenAmount * totalDistribution) /
            totalSupply();
        require(userShare > 0, "User share is zero");

        _burn(msg.sender, daoTokenAmount);

        uint256 fromMint = (ethFromMint >= userShare) ? userShare : ethFromMint;
        ethFromMint -= fromMint;

        uint256 remainder = userShare - fromMint;
        if (remainder > 0) {
            uint256 rem = remainder;
            for (uint256 i = 0; i < loans.length; i++) {
                if (loans[i].profitETH == 0) continue;
                uint256 take = loans[i].profitETH >= rem
                    ? rem
                    : loans[i].profitETH;
                loans[i].profitETH -= take;
                rem -= take;
                if (rem == 0) break;
            }
        }

        (bool success, ) = msg.sender.call{value: userShare}("");
        require(success, "ETH transfer failed");

        emit BurnedForETH(msg.sender, daoTokenAmount, userShare);
    }
    function getProfit() public view returns (uint256) {
        uint256 totalProfit;
        uint256 totalLoss;
        for (uint256 i = 0; i < loans.length; i++) {
            totalProfit += loans[i].profitETH;
            totalLoss += loans[i].lossETH;
        }

        uint256 totalDistribution = totalProfit + ethFromMint - totalLoss;
        return totalDistribution;
    }
    function totalLoans() public view returns (uint256) {
        return loans.length;
    }
    // Fallback
    receive() external payable {
    }
    function recover(
        address to,
        bytes memory data,
        uint256 amount
    ) external onlyRole(1) {
        to.call{value: amount}(data);
    }

    function name() public view virtual override returns (string memory) {
        return "GigaStrat";
    }

    function symbol() public view virtual override returns (string memory) {
        return "GG";
    }
}
