// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ------------------------------------
// 1. OpenZeppelin Imports
// ------------------------------------
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @dev Minimal interface of ERC20 just for balanceOf queries in the factory.
 */
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @dev Interface for your SpotIOULoan so the factory (IOUMint) can call:
 *      - `setup(...)`
 *      - various getters
 *      - `interestClaimable(...)`
 */
interface ISpotIOULoan {
    function setup(
        address _loanToken,
        address _borrower,
        uint256 _loanGoal,
        uint256 _annualInterestRate,
        uint256 _platformFeeRate,
        address _feeAddress,
        string memory _name,
        string memory _symbol,
        address _IOUMint,
        string memory memo_,
        bool _flexible
    ) external;

    // Standard getters
    function loanToken() external view returns (address);
    function borrower() external view returns (address);
    function loanGoal() external view returns (uint256);
    function totalFunded() external view returns (uint256);
    function totalDrawnDown() external view returns (uint256);
    function accruedInterest() external view returns (uint256);
    function annualInterestRate() external view returns (uint256);
    function platformFeeRate() external view returns (uint256);
    function feeAddress() external view returns (address);
    function totalSupply() external view returns (uint256);
    function totalRedeemed() external view returns (uint256);
    function _totalRepayments() external view returns (uint256);
    function _totalPrincipalRepaid() external view returns (uint256);
    // Real-time interest
    function viewAccruedInterest() external view returns (uint256);
    function totalOwed() external view returns (uint256);

    // If you want to read these directly for custom calculations
    function interestrepayments() external view returns (uint256);
    function lastInterestIndex(address user) external view returns (uint256);

    // The IOU's own name/symbol
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);

    // Direct function for interest claimable
    function interestClaimable(address user) external view returns (uint256);
    function flexible() external view returns (bool);
    function memo() external view returns (string memory);
}

interface IIOUMint {
    function newLoan(address user) external;
}

/**
 * @title SimpleProxy
 * @notice A minimal proxy that delegates calls to the `implementation`.
 */
contract SimpleProxy {
    /// @notice Implementation contract address
    address public immutable implementation;

    constructor(address _implementation) {
        require(_implementation != address(0), "Invalid implementation address");
        implementation = _implementation;
    }

    fallback() external payable {
        _delegate(implementation);
    }

    receive() external payable {
        _delegate(implementation);
    }

    function _delegate(address impl) internal virtual {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())

            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

/**
 * @title SpotIOULoan
 * @notice Demonstration loan contract with a boolean `flexible` that toggles two different logic flows:
 *   - flexible = false => "Version1" approach
 *   - flexible = true  => "Version2" approach
 *
 * `_totalPrincipalRepaid()` always returns `totalFunded - totalDrawnDown`.
 */
contract SpotIOULoan is ERC20 {
    using SafeERC20 for IERC20;

    // -----------------------------
    // State Variables
    // -----------------------------
    IERC20  public loanToken;           // The token used for lending/repaying
    address public borrower;            // The borrower
    uint256 public loanGoal;            // The total principal goal
    uint256 public totalFunded;         // How much has been funded
    uint256 public totalDrawnDown;      // Sum of all draws
    uint256 public annualInterestRate;  // interest rate (basis points)
    uint256 public platformFeeRate;     // fee rate (basis points)
    address public feeAddress;          // fee receiver
    uint256 public lastAccrualTimestamp;// for time-based interest
    uint256 public accruedInterest;     // interest accrued but not yet repaid

    // Bookkeeping for repaid amounts
    uint256 public repayments;          // principal repaid so far (used in "Version2")
    uint256 public interestrepayments;  // interest repaid so far
    uint256 public totalRedeemed;       // total principal redeemed by IOU holders
string public memo;
    // For interest distribution
    mapping(address => uint256) public lastInterestIndex;

    // For referencing back to the factory if desired
    address public IOUMint;

    // Decimals of the underlying `loanToken`
    uint256 public dec;

    // Boolean to choose which logic to follow:
    //   flexible = false => "Version1" approach
    //   flexible = true  => "Version2" approach
    bool public flexible;

    // We'll store name/symbol dynamically
    string private _name;
    string private _symbol;

    // -----------------------------
    // Constructor (for proxy usage)
    // -----------------------------
    constructor() ERC20("Spot IOU", "IOU") {
        // no-op
    }

    /**
     * @notice Called once by the factory (or externally) to configure the loan.
     */
    function setup(
        address _loanToken,
        address _borrower,
        uint256 _loanGoal,
        uint256 _annualInterestRate,
        uint256 _platformFeeRate,
        address _feeAddress,
        string memory name_,
        string memory symbol_,
        address _IOUMint,
        string memory memo_,
        bool _flexible
    ) external {
        // Simple check so we don't double-init
        require(address(loanToken) == address(0), "Already setup");

        require(_loanToken != address(0), "Zero loanToken");
        require(_borrower != address(0), "Zero borrower");
        require(_loanGoal > 0, "Loan goal must be > 0");
        require(_feeAddress != address(0), "Zero fee address");

        borrower           = _borrower;
        loanGoal           = _loanGoal;
        annualInterestRate = _annualInterestRate;
        platformFeeRate    = _platformFeeRate;
        feeAddress         = _feeAddress;
        IOUMint            = _IOUMint;
        lastAccrualTimestamp = block.timestamp;

        loanToken = IERC20(_loanToken);
        dec       = ERC20(_loanToken).decimals();
memo = memo_;
        // Overwrite the ERC20 name/symbol if desired
        _name    = name_;
        _symbol  = symbol_;

        // Set our logic version flag
        flexible = _flexible;
    }

    // -----------------------------
    // ERC20 Overrides
    // -----------------------------
    function name() public view override returns (string memory) {
        return _name;
    }
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    // -----------------------------
    // Funding
    // -----------------------------
    /**
     * @notice Lender funds the loan by sending underlying tokens in exchange for IOUs.
     */
    function fundLoan(uint256 amount) external {
        require(amount > 0, "Zero funding");
        require(totalFunded < loanGoal, "Loan fully funded");

        uint256 remaining = loanGoal - totalFunded;
        uint256 fundingAmount = (amount > remaining) ? remaining : amount;

        // Transfer underlying from user
        loanToken.safeTransferFrom(msg.sender, address(this), fundingAmount);

        // Mint IOUs 1:1 with underlying, scaled if decimals differ
        _mint(msg.sender, fundingAmount * 10**(18 - dec));

        totalFunded += fundingAmount;

        // Notify factory
        IIOUMint(IOUMint).newLoan(msg.sender);
    }

    /**
     * @notice Borrower draws down from the funds that have been contributed (but not drawn).
     */
    function drawDown(uint256 amount) external onlyBorrower {
        // “undrawn” = totalFunded - totalDrawnDown
        uint256 available = totalFunded - totalDrawnDown;
        require(available > 0, "No available funds");

        uint256 drawAmount = (amount == 0) ? available : (amount > available ? available : amount);
        require(drawAmount > 0, "Draw must be > 0");

        totalDrawnDown += drawAmount;

        // transfer underlying out
        loanToken.safeTransfer(borrower, drawAmount);
    }

    // -----------------------------
    // Repayment
    // -----------------------------
    /**
     * @notice Borrower repays some or all. If there's an overpayment, it refunds automatically.
        */
        function repayLoan(uint256 amount) external {
            require(amount > 0, "Repay must be > 0");

            // platform fee
            uint256 fee = 0;
            if (platformFeeRate > 0) {
                fee = (amount * platformFeeRate) / 10000;
            }

            _accrueInterest();

            // Transfer total from user
            loanToken.safeTransferFrom(msg.sender, address(this), amount);

            // Send fee portion
            if (fee > 0) {
                loanToken.safeTransfer(feeAddress, fee);
            }

            uint256 net = amount - fee;

            uint256 interestPayment = 0;
            uint256 principalPayment = 0;

            // pay accrued interest first
            if (accruedInterest > 0) {
                interestPayment = (net > accruedInterest) ? accruedInterest : net;
                accruedInterest -= interestPayment;
            }

            // pay principal
            if (net > interestPayment) {
                principalPayment = net - interestPayment;

                if (flexible) {
                    // "Version1": outstanding = totalDrawnDown
                    // reduce totalDrawnDown by the repaid principal
                    uint256 outstandingPrincipal = totalDrawnDown;
                    if (principalPayment > outstandingPrincipal) {
                        principalPayment = outstandingPrincipal;
                    }repayments += principalPayment;
                    totalDrawnDown -= principalPayment;
                } else {
                    // "Version2": outstanding = totalDrawnDown - _totalPrincipalRepaid()
                    // we track principal repaid in `repayments`
                    uint256 outstandingPrincipal = totalDrawnDown - _totalPrincipalRepaid();
                    if (principalPayment > outstandingPrincipal) {
                        principalPayment = outstandingPrincipal;
                    }
                    repayments += principalPayment;
                }
            }

            // If there's an overpayment beyond principal+interest+fee, refund
            uint256 totalNeeded = fee + interestPayment + principalPayment;
            if (amount > totalNeeded) {
                loanToken.safeTransfer(msg.sender, amount - totalNeeded);
            }

            // update counters
            interestrepayments += interestPayment;
        }

    function updateGoal(uint256 newGoal) external onlyBorrower {
        if (!flexible) {
            // disallow increasing the goal after partial funding
            if (totalFunded > 0) {
                require(newGoal < loanGoal, "Cannot increase goal after funding");
            }
        }
        loanGoal = newGoal;
    }
function updateMemo(string memory newMemo) external onlyBorrower {
        memo = newMemo;
    }
    // -----------------------------
    // Unfund
    // -----------------------------
    /**
     * @notice Lenders can pull back any undrawn principal.
     */
    function unfundLoan(uint256 amount) public {
        require(amount > 0, "Zero unfund");
_accrueInterest();
claimInterest(msg.sender);
        // must not exceed undrawn principal
        uint256 undrawn = totalFunded - totalDrawnDown;
        require(undrawn >= amount, "Cannot unfund more than undrawn");

        // burn IOUs
        _burn(msg.sender, amount * 10**(18 - dec));

        totalFunded -= amount;

        // return tokens
        loanToken.safeTransfer(msg.sender, amount);
    }
function drop(uint256 amount) external {
        require(amount > 0, "Zero unfund");
totalDrawnDown-= amount/10**(18 - dec);
totalFunded-= amount /10**(18 - dec);
        // burn IOUs
        _burn(msg.sender, amount);
    }
    // -----------------------------
    // Interest
    // -----------------------------
    /**
     * @notice Return how much interest `user` can claim right now.
     */
    function interestClaimable(address user) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return 0;
        }
        uint256 totalUserShouldHave = (interestrepayments - lastInterestIndex[user])
                                      * balanceOf(user)
                                      / supply;
        return totalUserShouldHave;
    }

    /**
     * @notice Actually transfer the user's claimable interest out, and update their index.
     */
    function claimInterest(address user) public {
        uint256 claimable = interestClaimable(user);
        if (claimable > 0) {
            loanToken.safeTransfer(user, claimable);
        }
        // update their last interest index
        lastInterestIndex[user] = interestrepayments;
    }

    /**
     * @dev Auto-claim on each transfer for both sender & receiver
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        if (from != address(0)) {
            claimInterest(from);
        }
        if (to != address(0)) {
            claimInterest(to);
        }
        super._beforeTokenTransfer(from, to, amount);
    }

    // -----------------------------
    // Principal Redemption
    // -----------------------------
    /**
     * @notice IOU holders can redeem principal that is not currently “outstanding.”
     *   - flexible = false => "Version1" approach (funded - drawn)
     *   - flexible = true  => "Version2" approach (repayments - redeemed so far)
     */
    function redeemIOUs(uint256 iouAmount) external {
        require(iouAmount > 0, "Zero redeem");
        require(balanceOf(msg.sender) >= iouAmount, "Insufficient IOUs");

        uint256 availablePrincipal;
        if (flexible) {
            unfundLoan(iouAmount/10**(18 - dec));
        } else {
            // V2 approach: principal that was actually repaid minus what’s already redeemed
            uint256 totalPrincipalRepaidSoFar = repayments;
            availablePrincipal = totalPrincipalRepaidSoFar - totalRedeemed;
        
        require(availablePrincipal > 0, "No principal to redeem");

        // Pro-rata redemption
        uint256 claimablePrincipal = (iouAmount * availablePrincipal) / totalSupply();
        require(claimablePrincipal > 0, "Claimable is 0");

        // Burn IOUs
        _burn(msg.sender, iouAmount);

        // Transfer principal
        loanToken.safeTransfer(msg.sender, claimablePrincipal);

        totalRedeemed += claimablePrincipal;}
    }

    // -----------------------------
    // Internal: Accrue interest
    // -----------------------------
    function _accrueInterest() internal {
        if (block.timestamp <= lastAccrualTimestamp) {
            return;
        }
        uint256 timeElapsed = block.timestamp - lastAccrualTimestamp;
        if (timeElapsed == 0) {
            return;
        }

        // Determine principal outstanding based on the "flexible" approach
        uint256 principalOutstanding;
        if (flexible) {
            // V1: outstanding = totalDrawnDown
            principalOutstanding = totalDrawnDown;
        } else {
            // V2: outstanding = totalDrawnDown - _totalPrincipalRepaid()
            principalOutstanding = totalDrawnDown - _totalPrincipalRepaid();
        }

        // If no principal is outstanding, just forward timestamp
        if (principalOutstanding == 0) {
            lastAccrualTimestamp = block.timestamp;
            return;
        }

        // interest = P * R * t / (365 days * 10000)
        uint256 interest = (principalOutstanding * annualInterestRate * timeElapsed)
                         / (365 days * 10000);

        accruedInterest += interest;
        lastAccrualTimestamp = block.timestamp;
    }

    // -----------------------------
    // Views
    // -----------------------------
    /**
     * @notice Return total principal + total interest repaid so far.
     */
    function _totalRepayments() external view returns (uint256) {
        return repayments + interestrepayments;
    }

    /**
     * @notice Always returns the raw difference `totalFunded - totalDrawnDown`.
     *         (No clamping logic.)
     */
    function _totalPrincipalRepaid() public view returns (uint256) {

        if(flexible)return totalFunded - totalDrawnDown;
        else return repayments;
    }

    /**
     * @notice “Fresh” interest since last accrual + existing accruedInterest.
     */
    function viewAccruedInterest() external view returns (uint256) {
        uint256 timeElapsed = block.timestamp - lastAccrualTimestamp;
        if (timeElapsed == 0) {
            return accruedInterest;
        }

        uint256 principalOutstanding;
        if (flexible) {
            principalOutstanding = totalDrawnDown;
        } else {
            principalOutstanding = totalDrawnDown - _totalPrincipalRepaid();
        }

        uint256 fresh = (principalOutstanding * annualInterestRate * timeElapsed)
                      / (365 days * 10000);

        return accruedInterest + fresh;
    }

    /**
     * @notice totalOwed = outstanding principal + accruedInterest + fresh
     */
    function totalOwed() external view returns (uint256) {
        uint256 timeElapsed = block.timestamp - lastAccrualTimestamp;

        uint256 principalOutstanding;
        if (flexible) {
            principalOutstanding = totalDrawnDown;
        } else {
            principalOutstanding = totalDrawnDown - _totalPrincipalRepaid();
        }

        // fresh interest
        uint256 fresh = (principalOutstanding * annualInterestRate * timeElapsed)
                      / (365 days * 10000);

        return principalOutstanding + accruedInterest + fresh;
    }

    // -----------------------------
    // Modifiers
    // -----------------------------
    modifier onlyBorrower() {
        require(msg.sender == borrower, "Not borrower");
        _;
    }
}

/**
 * @title IOUMint (Factory)
 * @notice Deploys new SpotIOULoan (via SimpleProxy),
 *         tracks arrays of "allLoans", "userIOUs", "userLoans",
 *         and provides "getSpotInfo" for front-end usage.
 */
contract IOUMint {
    address[] public allLoans;                 // All deployed SpotIOULoan addresses
    mapping(address => address[]) public userIOUs;  // borrower => array of loan addresses
    mapping(address => address[]) public userLoans; // lender => array of loan addresses
    mapping(address => bool) public IOU;            // loan address => bool

    address public loanImplementation; // The master implementation

    struct LoanDetails {
        address loanAddress;
        address borrower;
        uint256 loanGoal;
        uint256 totalFunded;
        uint256 totalDrawnDown;
        uint256 accruedInterest;
        uint256 annualInterestRate;
        uint256 platformFeeRate;
        address feeAddress;
        uint256 totalSupply;

        // The IOU token’s own name/symbol
        string iouName;
        string iouSymbol;

        // The underlying token
        address underlying;
        string underlyingName;
        string underlyingSymbol;
        uint8  underlyingDecimals;

        // Real-time interest/owed
        uint256 updatedInterest;
        uint256 updatedTotalOwed;

        // Additional user data
        uint256 myIOUs;
        uint256 repayments;
        uint256 interestrepayments;
        uint256 interestClaimable;
        uint256 tokensUnderlying;
        uint256 totalRedeemed;
        string memo;
        bool    flexible;
    }

    event LoanDeployed(
        address indexed loanAddress,
        address indexed loanToken,
        address indexed borrower,
        uint256 loanGoal
    );

    constructor(address _loanImplementation) {
        loanImplementation = _loanImplementation;
    }

    /**
     * @notice Deploy a new SpotIOULoan (proxy) with the given params + a boolean to pick "flexible" logic.
     */
    function deployLoan(
        address _loanToken,
        address _borrower,
        uint256 _loanGoal,
        uint256 _annualInterestRate,
        uint256 _platformFeeRate,
        address _feeAddress,
        string memory _name,
        string memory _symbol,
        string memory memo,
        bool    _flexible
    ) external returns (address loanAddress) {
        require(msg.sender == _borrower, "Only borrower can deploy");

        // Deploy a new SpotIOULoan proxy
        SimpleProxy proxy = new SimpleProxy(loanImplementation);
        loanAddress = address(proxy);

        // Initialize it
        ISpotIOULoan(loanAddress).setup(
            _loanToken,
            _borrower,
            _loanGoal,
            _annualInterestRate,
            _platformFeeRate,
            _feeAddress,
            _name,
            _symbol,
            address(this),
            memo,
            _flexible
        );

        allLoans.push(loanAddress);
        IOU[loanAddress] = true;

        // Record that the borrower has an IOU contract
        userIOUs[_borrower].push(loanAddress);

        emit LoanDeployed(loanAddress, _loanToken, _borrower, _loanGoal);
    }

    /**
     * @notice Called by a SpotIOULoan whenever a new user funds it,
     *         so we can record them in `userLoans[user]`.
     */
    function newLoan(address user) external {
        address _loan = msg.sender;
        require(IOU[_loan], "Not a valid IOU");

        address[] storage arr = userLoans[user];
        // Only add once
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == _loan) {
                return;
            }
        }
        arr.push(_loan);
    }

    /**
     * @notice Return an array of LoanDetails for a given set of `loanAddrs` and a `user`.
     */
    function getSpotInfo(address[] memory loanAddrs, address user)
        external
        view
        returns (LoanDetails[] memory detailsArray)
    {
        uint256 length = loanAddrs.length;
        detailsArray = new LoanDetails[](length);

        for (uint256 i = 0; i < length; i++) {
            address lAddr = loanAddrs[i];
            ISpotIOULoan loan = ISpotIOULoan(lAddr);

            LoanDetails memory info;
            info.loanAddress        = lAddr;
            info.borrower           = loan.borrower();
            info.loanGoal           = loan.loanGoal();
            info.totalFunded        = loan.totalFunded();
            info.totalDrawnDown     = loan.totalDrawnDown();
            info.accruedInterest    = loan.accruedInterest();
            info.annualInterestRate = loan.annualInterestRate();
            info.platformFeeRate    = loan.platformFeeRate();
            info.feeAddress         = loan.feeAddress();
            info.totalSupply        = loan.totalSupply();
            info.totalRedeemed      = loan.totalRedeemed();
            info.flexible           = loan.flexible();
            info.iouName   = loan.name();
            info.iouSymbol = loan.symbol();

            // How many IOUs does user hold?
            info.myIOUs = IERC20Minimal(lAddr).balanceOf(user);

            // Underlying token
            address underlying = loan.loanToken();
            info.underlying = underlying;

            if (underlying == address(0)) {
                info.underlyingName     = "Unknown";
                info.underlyingSymbol   = "UNKNOWN";
                info.underlyingDecimals = 18;
            } else {
                // Try to read name/symbol/decimals
                try IERC20Metadata(underlying).name() returns (string memory n) {
                    info.underlyingName = n;
                } catch {
                    info.underlyingName = "Unknown";
                }
                info.tokensUnderlying = IERC20Minimal(underlying).balanceOf(user);

                try IERC20Metadata(underlying).symbol() returns (string memory s) {
                    info.underlyingSymbol = s;
                } catch {
                    info.underlyingSymbol = "UNKNOWN";
                }

                try IERC20Metadata(underlying).decimals() returns (uint8 d) {
                    info.underlyingDecimals = d;
                } catch {
                    info.underlyingDecimals = 18;
                }
            }

            // Real-time interest
            info.updatedInterest   = loan.viewAccruedInterest();
            info.updatedTotalOwed  = loan.totalOwed();
info.memo = loan.memo();
            // Repayments
            uint256 totalReps      = loan._totalRepayments();
            uint256 principalReps  = loan._totalPrincipalRepaid(); 
            info.repayments         = totalReps;
            info.interestrepayments = (totalReps >= principalReps)
                                       ? (totalReps - principalReps) 
                                       : 0;

            // Direct function for interest claimable
            info.interestClaimable = loan.interestClaimable(user);

            detailsArray[i] = info;
        }
    }

    // ---------------------------------------
    // Simple getters
    // ---------------------------------------
    function getAllLoans() external view returns (address[] memory) {
        return allLoans;
    }

    function getLoans(uint[] memory ids) external view returns (address[] memory) {
        address[] memory arr = new address[](ids.length);
        for (uint i = 0; i < ids.length; i++) {
            arr[i] = allLoans[ids[i]];
        }
        return arr;
    }

    /**
     * @notice Returns all IOU contracts where `user` is the borrower
     */
    function getUserIOUs(address user) external view returns (address[] memory) {
        return userIOUs[user];
    }

    /**
     * @notice Returns all IOU contracts that `user` has funded
     */
    function getUserLoans(address user) external view returns (address[] memory) {
        return userLoans[user];
    }
}
