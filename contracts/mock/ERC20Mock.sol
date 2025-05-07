// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock ERC20 token (e.g., USDC)
contract ERC20Mock is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return 6; // USDC-like token
    }
}

// Mock WETH contract
contract MockWETH is ERC20 {
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        require(balanceOf(msg.sender) >= wad, "Insufficient WETH balance");
        _burn(msg.sender, wad);
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    receive() external payable {}
}

// Mock Chainlink V3 Aggregator
contract MockV3Aggregator {
    uint8 private _decimals;
    int256 private _answer;
    uint256 private _updatedAt;

    constructor(uint8 decimals_, int256 initialAnswer) {
        _decimals = decimals_;
        _answer = initialAnswer;
        _updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, _answer, block.timestamp, _updatedAt, 1);
    }

    function updateAnswer(int256 newAnswer) external {
        _answer = newAnswer;
        _updatedAt = block.timestamp;
    }
}

// Mock Uniswap V3 Swap Router (Simulates swaps with token transfers)
contract MockSwapRouter {
    uint256 private _swapResult;
    bool private _revertSwap;

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    ExactInputSingleParams private _lastParams;

    // Set the amount to return for the next swap
    function setSwapResult(uint256 amountOut) external {
        _swapResult = amountOut;
        _revertSwap = false;
    }

    // Set swap to revert for testing failure cases
    function setSwapToRevert() external {
        _revertSwap = true;
    }

    // Simulate Uniswap V3 exactInputSingle with token transfers
    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut) {
        // Pull input tokens from the caller
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        // Simulate sending output tokens by minting (mock behavior)
        if (params.tokenOut == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
            // If tokenOut is ETH (not used in Gigastrat2, but included for completeness)
            payable(params.recipient).transfer(_swapResult);
        } else {
            // Mint output tokens (USDC or WETH) to recipient
            ERC20Mock(params.tokenOut).mint(params.recipient, _swapResult);
        }

        _lastParams = params;
        return _swapResult;
    }

    // Retrieve last swap parameters for test verification
    function getLastParams() external view returns (ExactInputSingleParams memory) {
        return _lastParams;
    }
}
