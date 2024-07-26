// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract Vault is IERC721Receiver {
    struct Transaction {
        address to;
        bytes data;
        uint256 timestamp;
        bool executed;
        uint256 confirmations;
        uint256 amount;
    }

    struct TokenLimit {
        uint256 fixedLimit; // if set, takes precedence over percentageLimit
        uint256 percentageLimit; // if fixedLimit is 0, use this limit as percentage of total balance
        uint256 useBaseLimit; // 0: no limit, 1: use base daily limit, 2: limit = 0 (disallow withdrawals)
    }

    address public owner;
    string public name;
    address public recoveryAddress;
    address[] public whitelistedAddresses;
    uint256 public dailyLimit; // in percentage
    uint256 public threshold; // number of required signers
    uint256 public delay; // in seconds
    address[] public assets;
    mapping(address => bool) public isWhitelisted;
    mapping(address => uint256) public dailyWithdrawnAmount; // token => withdrawn amount
    mapping(address => uint256) public lastWithdrawTimestamp; // token => timestamp
    mapping(address => TokenLimit) public tokenLimits;
    Transaction[] public queuedTransactions;
    uint public queuedTxs;
    uint public freeze;
    mapping(uint256 => mapping(address => bool)) public confirmed;

    event TokenDeposited(
        address token,
        uint256 amount,
        address indexed depositor
    );
    event NFTDeposited(address nft, uint256 tokenId, address indexed depositor);
    event TokenWithdrawn(address token, uint256 amount);
    event TransactionQueued(
        uint256 txIndex,
        address to,
        bytes data,
        uint256 amount
    );
    event TransactionExecuted(uint256 txIndex, address to, bytes data);
    event TransactionConfirmed(uint256 txIndex, address confirmer);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    modifier onlyWhitelisted() {
        require(isWhitelisted[msg.sender], "Not a whitelisted address");
        _;
    }

    modifier onlyRecoveryAddress() {
        require(msg.sender == recoveryAddress, "Not the recovery address");
        _;
    }

    constructor(
        address _owner,
        string memory _name,
        address _recoveryAddress,
        address[] memory _whitelistedAddresses,
        uint256 _dailyLimit,
        uint256 _threshold,
        uint256 _delay
    ) {
        owner = _owner;
        name = _name;
        recoveryAddress = _recoveryAddress;
        dailyLimit = _dailyLimit;
        threshold = _threshold;
        delay = _delay;

        for (uint256 i = 0; i < _whitelistedAddresses.length; i++) {
            isWhitelisted[_whitelistedAddresses[i]] = true;
        }
        whitelistedAddresses = _whitelistedAddresses;
    }

    function depositToken(address token, uint256 amount) public payable {
        if (token == address(0)) {
            require(msg.value == amount, "Incorrect ETH amount");
        } else {
            require(
                IERC20(token).transferFrom(msg.sender, address(this), amount),
                "Transfer failed"
            );
        }
        emit TokenDeposited(token, amount, msg.sender);
    }

    function depositNFT(address nft, uint256 tokenId) public {
        IERC721(nft).safeTransferFrom(msg.sender, address(this), tokenId);
        emit NFTDeposited(nft, tokenId, msg.sender);
    }

    function withdrawToken(
        address to,
        address token,
        uint256 amount
    ) public onlyOwner {
        uint256 balance = token == address(0)
            ? address(this).balance
            : IERC20(token).balanceOf(address(this));
        require(balance >= amount, "Insufficient balance");
        require(freeze == 0, "Freeze is active");

        uint256 limitAmount = getLimitAmount(token);
        uint256 timeSinceLastWithdrawal = block.timestamp -
            lastWithdrawTimestamp[token];

        if (timeSinceLastWithdrawal >= 1 days) {
            dailyWithdrawnAmount[token] = 0;
        }

        uint256 remainingLimit = limitAmount +
            (timeSinceLastWithdrawal * limitAmount) /
            1 days >
            dailyWithdrawnAmount[token]
            ? limitAmount +
                (timeSinceLastWithdrawal * limitAmount) /
                1 days -
                dailyWithdrawnAmount[token]
            : 0;
        if (remainingLimit > limitAmount) {
            remainingLimit = limitAmount;
        }

        if (amount > remainingLimit) {
            queueWithdrawal(token, to, amount);
        } else {
            dailyWithdrawnAmount[token] += amount;
            lastWithdrawTimestamp[token] = block.timestamp;

            executeWithdrawal(to, token, amount);
        }
    }

    function getLimit(
        address to,
        address token,
        uint256 amount
    ) public view returns (uint) {
        uint256 balance = token == address(0)
            ? address(this).balance
            : IERC20(token).balanceOf(address(this));
        require(balance >= amount, "Insufficient balance");

        uint256 limitAmount = getLimitAmount(token);
        uint256 timeSinceLastWithdrawal = block.timestamp -
            lastWithdrawTimestamp[token];
        uint dailyWithdrawn = dailyWithdrawnAmount[token];

        if (timeSinceLastWithdrawal >= 1 days) {
            dailyWithdrawn = 0;
        }

        uint256 remainingLimit = limitAmount +
            (timeSinceLastWithdrawal * limitAmount) /
            1 days >
            dailyWithdrawnAmount[token]
            ? limitAmount +
                (timeSinceLastWithdrawal * limitAmount) /
                1 days -
                dailyWithdrawnAmount[token]
            : 0;
        if (remainingLimit > limitAmount) {
            remainingLimit = limitAmount;
        }

        if (amount <= remainingLimit) {
            return amount != 0 ? amount : remainingLimit;
        } else {
            return 0;
        }
    }

    function queueWithdrawal(
        address token,
        address to,
        uint256 amount
    ) internal {
        bytes memory data;
        if (token == address(0)) {
            data = "";
            queueTransaction(to, data, amount);
        } else {
            data = abi.encodeWithSignature(
                "transfer(address,uint256)",
                to,
                amount
            );
            queueTransaction(token, data, 0);
        }
    }

    function queueTransaction(
        address to,
        bytes memory data,
        uint256 amount
    ) public onlyOwner {
        require(freeze == 0, "Freeze is active");
        Transaction storage newTransaction = queuedTransactions.push();
        newTransaction.to = to;
        newTransaction.data = data;
        newTransaction.timestamp = block.timestamp;
        newTransaction.executed = false;
        newTransaction.amount = amount;
        queuedTxs += 1;

        emit TransactionQueued(queuedTransactions.length - 1, to, data, amount);
    }

    function confirmTransaction(uint256 txIndex) public {
        require(
            msg.sender == owner || isWhitelisted[msg.sender],
            "Not authorized"
        );
        require(freeze <= 1, "Freeze is active");
        Transaction storage transaction = queuedTransactions[txIndex];
        require(transaction.timestamp != 0, "Transaction not found");
        require(!transaction.executed, "Transaction already executed");
        if (
            isWhitelisted[msg.sender] &&
            !(msg.sender == owner &&
                transaction.timestamp + delay <= block.timestamp)
        ) {
            require(
                !confirmed[txIndex][msg.sender],
                "Transaction already confirmed by this address"
            );
            transaction.confirmations += 1;
            confirmed[txIndex][msg.sender] = true;
        }
        if (
            msg.sender == owner &&
            transaction.timestamp + delay <= block.timestamp
        ) {
            transaction.confirmations = threshold;
        }
        emit TransactionConfirmed(txIndex, msg.sender);

        if (transaction.confirmations >= threshold) {
            executeTransaction(txIndex);
        }
    }

    function executeTransaction(uint256 txIndex) internal {
        Transaction storage transaction = queuedTransactions[txIndex];
        require(
            transaction.confirmations >= threshold,
            "Not enough confirmations"
        );
        require(!transaction.executed, "Transaction already executed");

        transaction.executed = true;

        (bool success, ) = transaction.to.call{value: transaction.amount}(
            transaction.data
        );
        require(success, "Transaction execution failed");

        emit TransactionExecuted(txIndex, transaction.to, transaction.data);
    }

    function executeWithdrawal(
        address to,
        address token,
        uint256 amount
    ) internal {
        if (token == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            require(success, "Transfer failed");
        } else {
            require(IERC20(token).transfer(to, amount), "Transfer failed");
        }
        emit TokenWithdrawn(token, amount);

        // Queue and execute a placeholder transaction
        Transaction storage newTransaction = queuedTransactions.push();
        newTransaction.to = token != address(0) ? token : to;
        newTransaction.data = abi.encode(
            "transfer(address,uint256)",
            to,
            amount
        );
        newTransaction.timestamp = block.timestamp;
        newTransaction.executed = true;
        newTransaction.amount = amount;

        queuedTxs += 1;

        emit TransactionQueued(queuedTransactions.length - 1, to, "", 0);
        emit TransactionExecuted(queuedTransactions.length - 1, to, "");
    }

    function getLimitAmount(address token) public view returns (uint256) {
        uint256 balance = token == address(0)
            ? address(this).balance
            : IERC20(token).balanceOf(address(this));
        TokenLimit storage limit = tokenLimits[token];
        if (limit.fixedLimit > 0) {
            return limit.fixedLimit;
        } else if (limit.percentageLimit > 0) {
            return (balance * limit.percentageLimit) / 100;
        } else if (limit.useBaseLimit == 1) {
            return 0; // disallow withdrawals
        } else if (limit.useBaseLimit == 2) {
            return uint256(1000000000000000000000000000000);
        } else {
            return (balance * dailyLimit) / 100;
        }
    }

    function updateRecoveryAddress(address newRecoveryAddress) external {
        require(
            msg.sender == address(this),
            "Can only be called by contract itself"
        );
        recoveryAddress = newRecoveryAddress;
    }

    function updateWhitelistAddresses(
        address[] memory newWhitelistedAddresses
    ) external {
        require(
            msg.sender == address(this),
            "Can only be called by contract itself"
        );
        for (uint256 i = 0; i < whitelistedAddresses.length; i++) {
            isWhitelisted[whitelistedAddresses[i]] = false;
        }
        for (uint256 i = 0; i < newWhitelistedAddresses.length; i++) {
            isWhitelisted[newWhitelistedAddresses[i]] = true;
        }
        whitelistedAddresses = newWhitelistedAddresses;
    }

    function updateDailyLimit(uint256 newDailyLimit) external {
        require(
            msg.sender == address(this),
            "Can only be called by contract itself"
        );
        dailyLimit = newDailyLimit;
    }

    function updateThreshold(uint256 newThreshold) external {
        require(
            msg.sender == address(this),
            "Can only be called by contract itself"
        );
        threshold = newThreshold;
    }

    function updateDelay(uint256 newDelay) external {
        require(
            msg.sender == address(this),
            "Can only be called by contract itself"
        );
        delay = newDelay;
    }

    function setTokenLimit(
        address token,
        uint256 fixedLimit,
        uint256 percentageLimit,
        uint256 useBaseLimit
    ) external {
        require(
            msg.sender == address(this),
            "Can only be called by contract itself"
        );
        require(useBaseLimit <= 2, "Invalid useBaseLimit value");
        tokenLimits[token] = TokenLimit({
            fixedLimit: fixedLimit,
            percentageLimit: percentageLimit,
            useBaseLimit: useBaseLimit
        });
    }
    function freezeLock(uint freezeL) external {
        require(
            msg.sender == address(this) ||
                msg.sender == owner ||
                msg.sender == recoveryAddress ||
                isWhitelisted[msg.sender],
            "Can only be called by contract itself, owner, recovery address or whitelisted addresses"
        );
        if (msg.sender != recoveryAddress) {
            require(freezeL >= freeze, "Cannot unfreeze");
        }
        freeze = freezeL;
    }
    receive() external payable {
        // Accept ETH deposits
    }

    function recover(
        address token,
        address to,
        uint256 amount,
        bytes memory data,
        uint freezeL
    ) external onlyRecoveryAddress {
        if (token == address(0)) {
            require(address(this).balance >= amount, "Insufficient balance");
            (bool success, ) = to.call{value: amount}(data);
            require(success, "Transfer failed");
        } else {
            require(
                IERC20(token).balanceOf(address(this)) >= amount,
                "Insufficient balance"
            );
            require(IERC20(token).transfer(to, amount), "Transfer failed");
        }
        emit TokenWithdrawn(token, amount);
        freeze = freezeL;
    }

    function updateSettings(
        address newRecoveryAddress,
        address[] memory newWhitelistedAddresses,
        uint256 newDailyLimit,
        uint256 newThreshold,
        uint256 newDelay,
        address[] memory tokens,
        uint256[] memory fixedLimits,
        uint256[] memory percentageLimits,
        uint256[] memory useBaseLimits
    ) external {
        require(
            msg.sender == address(this) || msg.sender == recoveryAddress,
            "Not authorized"
        );

        if (newRecoveryAddress != address(0)) {
            recoveryAddress = newRecoveryAddress;
        }

        if (newWhitelistedAddresses.length > 0) {
            for (uint256 i = 0; i < whitelistedAddresses.length; i++) {
                isWhitelisted[whitelistedAddresses[i]] = false;
            }
            for (uint256 i = 0; i < newWhitelistedAddresses.length; i++) {
                isWhitelisted[newWhitelistedAddresses[i]] = true;
            }
            whitelistedAddresses = newWhitelistedAddresses;
        }

        if (newDailyLimit != 0) {
            dailyLimit = newDailyLimit;
        }

        if (newThreshold != 0) {
            threshold = newThreshold;
        }

        if (newDelay != 0) {
            delay = newDelay;
        }

        if (tokens.length > 0) {
            require(
                tokens.length == fixedLimits.length &&
                    tokens.length == percentageLimits.length &&
                    tokens.length == useBaseLimits.length,
                "Input arrays length mismatch"
            );

            for (uint256 i = 0; i < tokens.length; i++) {
                require(useBaseLimits[i] <= 2, "Invalid useBaseLimit value");
                tokenLimits[tokens[i]] = TokenLimit({
                    fixedLimit: fixedLimits[i],
                    percentageLimit: percentageLimits[i],
                    useBaseLimit: useBaseLimits[i]
                });
            }
        }
    }

    function onERC721Received(
        address _operator,
        address _from,
        uint256 _tokenId,
        bytes memory _data
    ) external override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract VaultFactory {
    address public owner;
    uint256 public totalVaults;
    mapping(string => address) public vaultNames;
    mapping(address => address[]) public ownerToVaults;

    event VaultCreated(
        address vaultAddress,
        address indexed owner,
        string name,
        address recoveryAddress
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function createVault(
        string memory _name,
        address _recoveryAddress,
        address[] memory _whitelistedAddresses,
        uint256 _dailyLimit,
        uint256 _threshold,
        uint256 _delay
    ) public returns (address) {
        require(vaultNames[_name] == address(0), "Vault name already exists");

        Vault vault = new Vault(
            msg.sender,
            _name,
            _recoveryAddress,
            _whitelistedAddresses,
            _dailyLimit,
            _threshold,
            _delay
        );
        address vaultAddress = address(vault);

        vaultNames[_name] = vaultAddress;
        ownerToVaults[msg.sender].push(vaultAddress);
        totalVaults += 1;

        emit VaultCreated(vaultAddress, msg.sender, _name, _recoveryAddress);
        return vaultAddress;
    }

    function getVaultsByOwner(
        address _owner
    ) public view returns (address[] memory) {
        return ownerToVaults[_owner];
    }
}
