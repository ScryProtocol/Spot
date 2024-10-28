const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Vault2 Token Limits", function () {
    let Vault2, vault, owner, addr1, recoveryAddress;
    let token;

    beforeEach(async function () {
        [owner, recoveryAddress, addr1] = await ethers.getSigners();

        const Token = await ethers.getContractFactory("ERC20Mock");
        token = await Token.deploy("Mock Token", "MTK", 1000000);
        await token.deployed();

        Vault2 = await ethers.getContractFactory("Vault2");
        vault = await Vault2.deploy();
        await vault.deployed();

        await vault.init(
            owner.address,
            "TestVault",
            recoveryAddress.address,
            [addr1.address],
            10, // 10% daily limit
            1, // 1 confirmation
            0 // no delay
        );

        // Approve and deposit tokens
        await token.approve(vault.address, 1000);
        await vault.depositToken(token.address, 1000);
    });

    // Helper function to queue and execute transactions
    async function queueAndExecuteTransaction(vault, to, data, amount = 0) {
        await vault.queueTransaction(to, data, amount);
        const txIndex = await vault.queuedTxs();
        await vault.confirmTransaction(txIndex - 1); // Confirm and execute the transaction
    }

    describe("Daily Limit Boundaries", function () {
        it("should allow withdrawal within daily limit (10% of balance)", async function () {
            // 10% of 1000 is 100
            await expect(vault.withdrawToken(addr1.address, token.address, 100))
                .to.emit(vault, "TokenWithdrawn")
                .withArgs(token.address, 100);
        });

        it("should queue withdrawal if exceeding daily limit", async function () {
            // Exceeding 10% (100 tokens)
            await expect(vault.withdrawToken(addr1.address, token.address, 200))
                .to.emit(vault, "TransactionQueued");
        });

        it("should reset daily limit after 24 hours", async function () {
            await vault.withdrawToken(addr1.address, token.address, 100);

            // Advance time by 24 hours
            console.log(ethers.provider.blockNumber)
            await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]); // 24 hours
            await ethers.provider.send("evm_mine");

            console.log(ethers.provider.blockNumber)

            // Withdraw again, which should succeed because daily limit is reset
            await expect(vault.withdrawToken(addr1.address, token.address, 100))
                .to.emit(vault, "TokenWithdrawn")
                .withArgs(token.address, 100);
        });
    });

    describe("Fixed Limit Boundaries", function () {
        it("should respect fixed limit if set", async function () {
            // Set fixed limit to 50 tokens by calling setTokenLimit through queued transaction
            const data = vault.interface.encodeFunctionData("setTokenLimit", [
                token.address,
                50, 0, 0
            ]);
            await queueAndExecuteTransaction(vault, vault.address, data);

            // Try withdrawing more than the fixed limit
            await expect(vault.withdrawToken(addr1.address, token.address, 100))
                .to.emit(vault, "TransactionQueued");

            // Withdraw within fixed limit
            await expect(vault.withdrawToken(addr1.address, token.address, 50))
                .to.emit(vault, "TokenWithdrawn")
                .withArgs(token.address, 50);
        });

        it("should allow resetting fixed limit", async function () {
            // Set fixed limit
            let data = vault.interface.encodeFunctionData("setTokenLimit", [
                token.address,
                50, 0, 0
            ]);
            await queueAndExecuteTransaction(vault, vault.address, data);

            // Reset to no fixed limit
            data = vault.interface.encodeFunctionData("setTokenLimit", [
                token.address,
                0, 0, 0
            ]);
            await queueAndExecuteTransaction(vault, vault.address, data);

            // Withdraw full amount allowed by percentage limit
            await expect(vault.withdrawToken(addr1.address, token.address, 100))
                .to.emit(vault, "TokenWithdrawn")
                .withArgs(token.address, 100);
        });
    });

    describe("Percentage Limit Boundaries", function () {
        it("should respect percentage limit when fixed limit is not set", async function () {
            // Set percentage limit to 5% by calling setTokenLimit through queued transaction
            const data = vault.interface.encodeFunctionData("setTokenLimit", [
                token.address,
                0, 5, 0
            ]);
            await queueAndExecuteTransaction(vault, vault.address, data);

            // 5% of 1000 = 50
            await expect(vault.withdrawToken(addr1.address, token.address, 50))
                .to.emit(vault, "TokenWithdrawn")
                .withArgs(token.address, 50);

            // Try withdrawing more than 5%
            await expect(vault.withdrawToken(addr1.address, token.address, 100))
                .to.emit(vault, "TransactionQueued");
        });

        it("should apply percentage limits correctly as the balance changes", async function () {
            // Set percentage limit to 10% by calling setTokenLimit through queued transaction
            const data = vault.interface.encodeFunctionData("setTokenLimit", [
                token.address,
                0, 10, 0
            ]);
            await queueAndExecuteTransaction(vault, vault.address, data);

            // 10% of 1000 = 100
            await expect(vault.withdrawToken(addr1.address, token.address, 100))
                .to.emit(vault, "TokenWithdrawn")
                .withArgs(token.address, 100);

            // Deposit more tokens to the vault
            await token.approve(vault.address, 500);
            await vault.depositToken(token.address, 500);

            // New balance = 1500, 10% = 150
            await expect(vault.withdrawToken(addr1.address, token.address, 150))
                .to.emit(vault, "TokenWithdrawn")
                .withArgs(token.address, 150);
        });
    });

    describe("Use Base Limit Boundaries", function () {
        it("should disallow withdrawals if base limit is set to 1", async function () {
            const data = vault.interface.encodeFunctionData("setTokenLimit", [
                token.address,
                0, 0, 1
            ]); // useBaseLimit = 1 (disallow withdrawals)
            await queueAndExecuteTransaction(vault, vault.address, data);

            await expect(vault.withdrawToken(addr1.address, token.address, 100))
                .to.be.revertedWith("Limit exceeded");
        });

        it("should allow unlimited withdrawals if useBaseLimit is set to 2", async function () {
            const data = vault.interface.encodeFunctionData("setTokenLimit", [
                token.address,
                0, 0, 2
            ]); // useBaseLimit = 2 (unlimited withdrawals)
            await queueAndExecuteTransaction(vault, vault.address, data);

            await expect(vault.withdrawToken(addr1.address, token.address, 1000))
                .to.emit(vault, "TokenWithdrawn")
                .withArgs(token.address, 1000);
        });
    });

    describe("Withdrawal After Partial Daily Limit", function () {
        it("should calculate remaining daily limit correctly", async function () {
            // Withdraw half of the daily limit (50 out of 100)
            await vault.withdrawToken(addr1.address, token.address, 50);

            // Withdraw another 50 tokens (remaining of daily limit)
            await expect(vault.withdrawToken(addr1.address, token.address, 50))
                .to.emit(vault, "TokenWithdrawn")
                .withArgs(token.address, 50);

            // Exceeding daily limit should queue the transaction
            await expect(vault.withdrawToken(addr1.address, token.address, 10))
                .to.emit(vault, "TransactionQueued");
        });
    });

    describe("Token Limit Updates", function () {
        it("should allow updating token limits", async function () {
            // Initially no limit
            await expect(vault.withdrawToken(addr1.address, token.address, 100))
                .to.emit(vault, "TokenWithdrawn");

            // Set new limit (50 tokens)
            const data = vault.interface.encodeFunctionData("setTokenLimit", [
                token.address,
                50, 0, 0
            ]);
            await queueAndExecuteTransaction(vault, vault.address, data);

            await expect(vault.withdrawToken(addr1.address, token.address, 100))
                .to.emit(vault, "TransactionQueued");

            // Reset limit
            const resetData = vault.interface.encodeFunctionData("setTokenLimit", [
                token.address,
                0, 0, 0
            ]);
            await queueAndExecuteTransaction(vault, vault.address, resetData);

            await expect(vault.withdrawToken(addr1.address, token.address, 100))
                .to.emit(vault, "TokenWithdrawn");
        });
    });
});
