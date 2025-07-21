// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Gigastrat Protocol
 * @author Gigastrat Team
 * @notice A decentralized lending protocol with dynamic profit distribution and IOU-to-governance token swapping
 * @dev Implements ERC20 with gas-optimized assembly operations and sophisticated loan management
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Chainlink price feed interface for ETH/USD oracle
 */
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

/**
 * @notice Interface for individual loan contracts that issue IOU tokens
 * @dev Each loan is deployed via IOUMint factory and represents a single borrowing instance
 */
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

/**
 * @notice Factory contract for deploying new loan instances
 */
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
        string memory _memo,
        bool flexible
    ) external returns (address);
}

/**
 * @notice Wrapped ETH interface for deposits and withdrawals
 */
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/**
 * @notice Uniswap V3 router interface for token swaps
 */
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
 * @title Gas-Optimized ERC20 Implementation
 * @notice Custom ERC20 with assembly-optimized storage operations for reduced gas costs
 * @dev Uses assembly for all storage operations and custom slot layout for efficiency
 */
abstract contract ERC20 {
    /// @notice Thrown when total supply would overflow
    error TotalSupplyOverflow();
    /// @notice Thrown when allowance would overflow
    error AllowanceOverflow();
    /// @notice Thrown when allowance would underflow
    error AllowanceUnderflow();
    /// @notice Thrown when balance is insufficient for transfer
    error InsufficientBalance();
    /// @notice Thrown when allowance is insufficient for transfer
    error InsufficientAllowance();

    /// @notice Emitted when tokens are transferred
    event Transfer(address indexed from, address indexed to, uint256 amount);
    /// @notice Emitted when allowance is set
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    // keccak256("Transfer(address,address,uint256)")
    uint256 private constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    // keccak256("Approval(address,address,uint256)")
    uint256 private constant _APPROVAL_EVENT_SIGNATURE =
        0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925;

    // Custom storage slots for gas optimization
    uint256 private constant _TOTAL_SUPPLY_SLOT = 0x05345cdf77eb68f44c;
    uint256 private constant _BALANCE_SLOT_SEED = 0x87a211a2;
    uint256 private constant _ALLOWANCE_SLOT_SEED = 0x7f5e9f20;

    /// @notice Returns the name of the token
    function name() public view virtual returns (string memory);
    
    /// @notice Returns the symbol of the token
    function symbol() public view virtual returns (string memory);
    
    /// @notice Returns the decimals of the token (always 18)
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /// @notice Returns the total token supply
    function totalSupply() public view virtual returns (uint256 result) {
        assembly {
            result := sload(_TOTAL_SUPPLY_SLOT)
        }
    }

    /// @notice Returns the token balance of an account
    /// @param owner The account to query
    function balanceOf(address owner) public view virtual returns (uint256 result) {
        assembly {
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, owner)
            result := sload(keccak256(0x0c, 0x20))
        }
    }

    /**
     * @notice Returns the allowance of spender for owner's tokens
     * @param owner The account that owns the tokens
     * @param spender The account that can spend the tokens
     * @return result The allowance amount
     */
    function allowance(address owner, address spender) public view virtual returns (uint256 result) {
        assembly {
            mstore(0x20, spender)
            mstore(0x0c, _ALLOWANCE_SLOT_SEED)
            mstore(0x00, owner)
            result := sload(keccak256(0x0c, 0x34))
        }
    }

    /**
     * @notice Approve spender to spend amount of tokens on behalf of caller
     * @param spender The account that will be approved to spend tokens
     * @param amount The amount of tokens to approve
     * @return Always returns true
     */
    function approve(address spender, uint256 amount) public virtual returns (bool) {
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

    /**
     * @notice Transfer tokens from caller to another address
     * @param to The recipient address
     * @param amount The amount of tokens to transfer
     * @return Always returns true
     */
    function transfer(address to, uint256 amount) public virtual returns (bool) {
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

    /**
     * @notice Transfer tokens from one address to another using allowance
     * @param from The address to transfer tokens from
     * @param to The address to transfer tokens to
     * @param amount The amount of tokens to transfer
     * @return Always returns true
     */
    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
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

    /**
     * @notice Internal function to mint new tokens to an address
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     * @dev Uses assembly for gas optimization, includes overflow protection
     */
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

    /**
     * @notice Internal function to burn tokens from an address
     * @param from The address to burn tokens from  
     * @param amount The amount of tokens to burn
     * @dev Uses assembly for gas optimization, includes balance validation
     */
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

    /**
     * @notice Internal function to transfer tokens between addresses
     * @param from The address to transfer tokens from
     * @param to The address to transfer tokens to
     * @param amount The amount of tokens to transfer
     * @dev Uses assembly for gas optimization, includes balance validation
     */
    function _transfer(address from, address to, uint256 amount) internal virtual {
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

    /**
     * @notice Internal function to spend allowance (reduce approved amount)
     * @param owner The token owner address
     * @param spender The address spending the tokens
     * @param amount The amount of allowance to spend
     * @dev Uses assembly for gas optimization, supports unlimited allowance (max uint256)
     */
    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
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

    /**
     * @notice Internal function to set allowance for spender
     * @param owner The token owner address
     * @param spender The address to approve for spending
     * @param amount The amount to approve
     * @dev Uses assembly for gas optimization, emits Approval event
     */
    function _approve(address owner, address spender, uint256 amount) internal virtual {
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

/**
 * @title Gigastrat Protocol - Main Contract
 * @notice Manages loans, profit distribution, and IOU-to-governance token conversions
 * @dev Implements a sophisticated DeFi lending protocol with dynamic pricing mechanisms
 * 
 * Key Features:
 * - Automated loan creation and management
 * - Dynamic IOU conversion rates based on ETH price and profit pools
 * - Dual-token system: IOUs (loan-specific) and GG tokens (governance/profit-sharing)
 * - ETH/USDC trading via Uniswap V3
 * - Role-based access control
 * 
 * Economic Model:
 * - Users fund loans and receive IOU tokens representing claims on loan profits
 * - IOUs can be swapped for GG tokens at dynamic rates
 * - GG tokens represent share of total protocol profit distribution
 * - Conversion creates game-theoretic dynamics between early vs late swappers
 */
contract Gigastrat5 is ERC20 {
    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Complete information about a loan instance
     * @param loanAddress The deployed loan contract address
     * @param loanGoal Target funding amount in loan token
     * @param totalDrawnDown Total amount withdrawn by borrower
     * @param loanDrawn Whether loan has been drawn down
     * @param loanDrawnTime Timestamp of first drawdown
     * @param fullyRepaid Whether loan is completely repaid
     * @param iouConversionRate Rate for converting IOUs to GG tokens (18 decimals)
     * @param totalBuyETH Total ETH purchased from loan funds
     * @param soldETH Total ETH sold for loan repayments
     * @param profitETH Net profit in ETH (totalBuyETH - soldETH if positive)
     * @param lossETH Net loss in ETH (soldETH - totalBuyETH if negative)
     */
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

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Array of all loans created by the protocol
    LoanInfo[] public loans;

    /// @notice Factory contract for deploying new loans
    IOUMint public immutable ioUMint;
    
    /// @notice USDC token contract address
    address public immutable usdcToken;
    
    /// @notice Uniswap V3 router for token swaps
    ISwapRouter public immutable swapRouter;
    
    /// @notice WETH contract address
    address public immutable wethAddress;
    
    /// @notice Chainlink price feed for ETH/USD
    AggregatorV3Interface public immutable priceFeed;
    
    /// @notice Address receiving protocol fees (10% of minted GG tokens)
    address public feeAddress = 0x9D31e30003f253563Ff108BC60B16Fdf2c93abb5;
    
    /// @notice ETH moved from loans to immediate profit pool via IOU swaps
    uint256 public ethFromMint;
    
    /// @notice Total ETH profits from completed loans
    uint256 public totalProfit;
    
    /// @notice Total ETH losses from completed loans
    uint256 public totalLoss;

    /// @notice Referral fee
    uint256 public refFee = 3;

    /// @notice Repayment delay (in days) for loans
    uint256 public repayDays = 10;

    /// @notice Conversion rate premium for IOU to GG token swaps
    uint256 public conversionRatePrem = 15;

    /// @notice Swap expiration
    uint256 public swapExp = 365;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum slippage tolerance for swaps (1%)
    uint256 public constant SLIPPAGE = 1e16;
    
    /// @notice Deadline for transactions (max uint256)
    uint256 public constant NO_DEADLINE = type(uint256).max;
    
    /// @notice Uniswap V3 pool fee tier (0.05%)
    uint24 public constant POOL_FEE = 500;

    /*//////////////////////////////////////////////////////////////
                               MAPPINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role-based access control (1=admin, 2=manager, 3=fee recipient)
    mapping(address => uint256) public role;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new loan is created
    event LoanStarted(address indexed loanAddress, uint256 loanIndex);
    
    /// @notice Emitted when loan funds are drawn down
    event LoanDrawn(uint256 amount, uint256 drawTime, uint256 loanIndex);
    
    /// @notice Emitted when USDC is swapped for ETH
    event BoughtETH(uint256 loanIndex, uint256 usdcSpent, uint256 ethReceived);
    
    /// @notice Emitted when loan is repaid
    event LoanRepaid(uint256 loanIndex, uint256 usdcUsed);
    
    /// @notice Emitted when IOUs are swapped for GG tokens
    event IOUSwapped(
        address indexed user,
        address indexed loanAddress,
        uint256 iouAmount,
        uint256 daoMinted,
        uint256 loanIndex
    );
    
    /// @notice Emitted when conversion rate is updated
    event ConversionRateUpdated(uint256 loanIndex, uint256 newRate);
    
    /// @notice Emitted when IOUs are redeemed and swapped
    event RedeemedAndSwapped(
        uint256 iouRedeemed,
        uint256 usdcReceived,
        uint256 ethReceived
    );
    
    /// @notice Emitted when GG tokens are burned for ETH
    event BurnedForETH(
        address indexed user,
        uint256 daoBurned,
        uint256 ethReceived
    );
    
    /// @notice Emitted when loan profit/loss is finalized
    event ProfitFinalized(uint256 loanIndex, uint256 profitETH);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the Gigastrat protocol with required dependencies
     * @param _ioUMint Address of the loan factory contract
     * @param _usdcToken Address of the USDC token contract
     * @param _uniswapV3Router Address of the Uniswap V3 router
     * @param _wethAddress Address of the WETH contract
     * @param _priceFeedAddress Address of the ETH/USD Chainlink price feed
     */
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

        // Initialize roles
        role[address(this)] = 2;  // Contract as manager
        role[0x9D31e30003f253563Ff108BC60B16Fdf2c93abb5] = 2;  // Manager
        role[0x00000000000000C0D7D3017B342ff039B55b0879] = 1;  // Admin
        role[msg.sender] = 2;
        startLoan(50000000000000, usdcToken, 0, 0, address(this), 1e18);
        role[msg.sender] = 0;
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Restricts function access to accounts with specific role
     * @param _role Required role (1=admin, 2=manager, 3=fee recipient)
     */
    modifier onlyRole(uint256 _role) {
        require(role[msg.sender] == _role, "Not authorized");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           ORACLE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the latest ETH price from Chainlink oracle
     * @return Latest ETH price in USD with 8 decimals
     */
    function getLatestPrice() public view returns (int256) {
        (, int256 answer, , , ) = priceFeed.latestRoundData();
        return answer;
    }

    /*//////////////////////////////////////////////////////////////
                           ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set role for an address (admin only)
     * @param _address Address to set role for
     * @param _role Role to assign (1=admin, 2=manager, 3=fee recipient)
     */
    function setRole(address _address, uint256 _role) external onlyRole(1) {
        role[_address] = _role;
        if (_role == 3) feeAddress = _address;
    }

    /*//////////////////////////////////////////////////////////////
                          LOAN MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create a new loan with specified parameters
     * @param _loanGoal Target funding amount
     * @param _token Loan token address (typically USDC)
     * @param _annualInterestRate Interest rate in basis points
     * @param _platformFeeRate Platform fee in basis points
     * @param _feeAddress Address to receive fees
     * @param _loanIOUConversionRate Initial conversion rate for IOUs to GG tokens
     */
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
            "Gigastrat Loan",
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

    /**
     * @notice Create a new loan with dynamic conversion rate (public)
     * @dev Conversion rate calculated based on current ETH price, profit distribution, and GG supply
     * Formula: rate = ((ethPrice * 1e10 * totalDistribution) / totalSupply) * 1.5
     */
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
                totalSupply()) * conversionRatePrem) /
            10;

        _loanGoal = 10000000000000000;

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
            "Gigastrat Loan",
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

    /**
     * @notice Fund a loan and receive IOU tokens, automatically execute drawdown and ETH purchase
     * @param loanIndex Index of the loan to fund
     * @param amount Amount of tokens to contribute
     */
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

    /*//////////////////////////////////////////////////////////////
                           TRADING OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Draw down funds from a loan for trading
     * @param loanIndex Index of the loan to draw from
     * @param amount Amount to draw down
     */
    function drawDownLoan(uint256 loanIndex, uint256 amount) public onlyRole(2) {
        require(loanIndex < loans.length, "Invalid loan index");
        LoanInfo storage ln = loans[loanIndex];

        ISpotIOULoan(ln.loanAddress).drawDown(amount);
        ln.totalDrawnDown += amount;

            ln.loanDrawnTime = block.timestamp;

        emit LoanDrawn(amount, block.timestamp, loanIndex);
    }

    /**
     * @notice Swap USDC for ETH using Uniswap V3 and track for loan
     * @param loanIndex Index of the loan this purchase is for
     * @param usdcAmount Amount of USDC to swap for ETH
     */
    function buyETH(uint256 loanIndex, uint256 usdcAmount) public onlyRole(2) {
        require(loanIndex < loans.length, "Invalid loan index");
        require(usdcAmount > 0, "USDC amount must be > 0");

        IERC20(usdcToken).approve(address(swapRouter), usdcAmount);

        int256 latestPrice = getLatestPrice();
        require(latestPrice > 0, "Invalid oracle price");

        uint256 expectedETH = (usdcAmount * 1e20) / uint256(latestPrice);
        uint256 minETHOut = (expectedETH * (1e18 - SLIPPAGE)) / 1e18;

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
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

    /**
     * @notice Repay loan by swapping ETH for USDC and paying down debt
     * @param loanIndex Index of the loan to repay
     * @param usdcAmount Amount of USDC debt to repay
     * @dev Calculates required ETH with slippage, swaps via Uniswap, and finalizes profit/loss on completion
     */
    function repayLoanUSDC(uint256 loanIndex, uint256 usdcAmount) public onlyRole(2) {
        require(loanIndex < loans.length, "Invalid loan index");
        LoanInfo storage ln = loans[loanIndex];
        require(ln.loanDrawn, "Loan not drawn down");
        if (ISpotIOULoan(ln.loanAddress).totalOwed() == 0) {
            return;
        }
        int256 latestPrice = getLatestPrice();
        require(latestPrice > 0, "Invalid price from oracle");

        uint256 requiredETHExact = (usdcAmount * 1e20) / uint256(latestPrice);
        uint256 requiredETH = (requiredETHExact * 1e18) / (1e18 - SLIPPAGE);

        IWETH(wethAddress).deposit{value: requiredETH}();
        IWETH(wethAddress).approve(address(swapRouter), requiredETH);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
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
            totalProfit += ln.profitETH;
            totalLoss += ln.lossETH;
            emit ProfitFinalized(loanIndex, ln.profitETH);
        }
    }

    /// @notice Tracks last repayment timestamp for each loan (for 10-day cooldown)
    mapping(uint256 => uint256) public repaid;

    /**
     * @notice Public function to make small loan repayments (1% of total funded)
     * @param loanIndex Index of the loan to repay
     * @dev Has 10-day cooldown between calls, automatically calculates 1% repayment amount
     */
    function repayLoan(uint256 loanIndex) external {
        require(repaid[loanIndex] + repayDays * 1 days <= block.timestamp);
        if (ISpotIOULoan(loans[loanIndex].loanAddress).totalOwed() == 0) {
            return;
        }
        repaid[loanIndex] = block.timestamp;
        uint256 amount = ISpotIOULoan(loans[loanIndex].loanAddress).totalFunded() / 100;
        amount = amount > ISpotIOULoan(loans[loanIndex].loanAddress).totalOwed()
            ? ISpotIOULoan(loans[loanIndex].loanAddress).totalOwed()
            : amount;
        this.repayLoanUSDC(loanIndex, amount);
    }

    /**
     * @notice Allow external parties to repay loans in exchange for ETH at oracle price + 0.5% premium
     * @param loanIndex Index of the loan to repay
     * @param amount Amount of USDC to repay (must equal 1% of total funded)
     * @dev Incentivizes third-party loan repayments by offering slight ETH premium over market price
     */
    function fill(uint256 loanIndex, uint256 amount) external payable {
        require(
            ISpotIOULoan(loans[loanIndex].loanAddress).totalFunded() / 100 == amount,
            "Too much sent"
        );
        if (ISpotIOULoan(loans[loanIndex].loanAddress).totalOwed() == 0) {
            return;
        }
        require(repaid[loanIndex] + repayDays * 1 days <= block.timestamp);
        repaid[loanIndex] = block.timestamp;

        IERC20(usdcToken).transferFrom(msg.sender, address(this), amount);
        IERC20(usdcToken).approve(loans[loanIndex].loanAddress, amount);
        ISpotIOULoan(loans[loanIndex].loanAddress).repayLoan(amount);

        payable(msg.sender).transfer(
            (((amount * 10 ** 12) / (uint256(getLatestPrice()) * 10 ** 10)) * 1005) / 1000
        );

        loans[loanIndex].soldETH +=
            (((amount * 10 ** 12) / (uint256(getLatestPrice()) * 10 ** 10)) * 1005) / 1000;

        emit LoanRepaid(loanIndex, amount);

        if (
            ISpotIOULoan(loans[loanIndex].loanAddress).totalOwed() == 0 &&
            loans[loanIndex].totalDrawnDown == loans[loanIndex].loanGoal
        ) {
            loans[loanIndex].fullyRepaid = true;
            if (loans[loanIndex].totalBuyETH > loans[loanIndex].soldETH) {
                loans[loanIndex].profitETH =
                    loans[loanIndex].totalBuyETH - loans[loanIndex].soldETH;
            } else {
                loans[loanIndex].profitETH = 0;
                loans[loanIndex].lossETH =
                    loans[loanIndex].soldETH - loans[loanIndex].totalBuyETH;
            }
            totalProfit += loans[loanIndex].profitETH;
            totalLoss += loans[loanIndex].lossETH;
            emit ProfitFinalized(loanIndex, loans[loanIndex].profitETH);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        IOU-TO-GG CONVERSION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Convert IOU tokens to GG governance tokens
     * @dev This is the core mechanism that creates profit distribution dynamics
     * @param loanIndex Index of the loan whose IOUs are being converted
     * @param iouAmount Amount of IOU tokens to convert
     * 
     * Process:
     * 1. Calculate GG tokens based on conversion rate
     * 2. Mint GG tokens to user (90%) and fees (10%)
     * 3. Move proportional ETH from loan to immediate profit pool
     * 4. Burn the IOU tokens from circulation
     * 5. Update loan goal downward
     */
    function swapIOUForMintTokens(uint256 loanIndex, uint256 iouAmount,address ref) external {
        require(loanIndex < loans.length, "Invalid loan index");
        require(iouAmount > 0, "IOU amount must be > 0");
        require(swapExp*1 days + loans[loanIndex].loanDrawnTime >= block.timestamp, "Swap expired");

        LoanInfo storage ln = loans[loanIndex];

        IERC20(ln.loanAddress).transferFrom(msg.sender, address(this), iouAmount);

        uint256 mintAmount = (iouAmount * 10 ** 18) / ln.iouConversionRate;

        _mint(msg.sender, mintAmount);
        if (ref!=address(0)) _mint(feeAddress, mintAmount / 10);
        else {
            _mint(feeAddress, (mintAmount * (10-refFee)) / 100);
            _mint(ref, (mintAmount * refFee) / 100);
        }
        uint256 amt = (iouAmount * loans[loanIndex].totalBuyETH) / IERC20(ln.loanAddress).totalSupply();
        loans[loanIndex].totalBuyETH -= amt;
        
        ISpotIOULoan(ln.loanAddress).drop(iouAmount);
        ISpotIOULoan(ln.loanAddress).updateGoal(
            ISpotIOULoan(ln.loanAddress).loanGoal() -
                iouAmount / 10 ** (18 - ISpotIOULoan(ISpotIOULoan(ln.loanAddress).loanToken()).decimals())
        );
        
        ethFromMint += amt;
        emit IOUSwapped(msg.sender, ln.loanAddress, iouAmount, mintAmount, loanIndex);
    }

    /*//////////////////////////////////////////////////////////////
                         GG TOKEN REDEMPTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Burn GG tokens to receive proportional share of total profit distribution
     * @param daoTokenAmount Amount of GG tokens to burn
     * 
     * User Share = (burnAmount / totalSupply) * (totalProfit + ethFromMint - totalLoss)
     */
    function burnForETH(uint256 daoTokenAmount) external {
        require(daoTokenAmount > 0, "DAO token amount must be > 0");
        require(balanceOf(msg.sender) >= daoTokenAmount, "Insufficient balance");
        uint256 totalDistribution = getProfit();
        uint256 userShare = (daoTokenAmount * totalDistribution) / totalSupply();
        require(userShare > 0, "User share is zero");

        _burn(msg.sender, daoTokenAmount);

        uint256 fromMint = (ethFromMint >= userShare) ? userShare : ethFromMint;
        ethFromMint -= fromMint;

        uint256 remainder = userShare - fromMint;
        if (remainder > 0) {
            totalProfit -= remainder;
        }

        (bool success, ) = msg.sender.call{value: userShare}("");
        require(success, "ETH transfer failed");

        emit BurnedForETH(msg.sender, daoTokenAmount, userShare);
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate total distributable profit across all sources
     * @return Total ETH available for distribution to GG token holders
     * @dev Formula: totalProfit + ethFromMint - totalLoss
     */
    function getProfit() public view returns (uint256) {
        return totalProfit + ethFromMint - totalLoss;
    }

    /**
     * @notice Get the total number of loans created
     * @return Number of loans in the loans array
     */
    function totalLoans() public view returns (uint256) {
        return loans.length;
    }

    /*//////////////////////////////////////////////////////////////
                        UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Receive ETH payments
    receive() external payable {}

    /**
     * @notice Emergency recovery function (admin only)
     * @param to Target address for call
     * @param data Call data
     * @param amount ETH amount to send
     */
    function recover(address to, bytes memory data, uint256 amount) external onlyRole(1) {
        to.call{value: amount}(data);
    }

    function setParams(
        uint256 _refFee,
        uint256 _repayDays,
        uint256 _conversionRatePrem,
        uint256 _swapExp
    ) external onlyRole(1) {
        refFee = _refFee<11 ? _refFee : 10; // Ensure maximum 10%
        repayDays = _repayDays>1 ? _repayDays : 1; // Ensure minimum 1 day
        conversionRatePrem = _conversionRatePrem > 10 ? _conversionRatePrem : 10; // Ensure minimum 100%
        swapExp = _swapExp;
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20 METADATA
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the name of the GG governance token
    function name() public view virtual override returns (string memory) {
        return "GigaStrat";
    }

    /// @notice Returns the symbol of the GG governance token  
    function symbol() public view virtual override returns (string memory) {
        return "GG";
    }
}