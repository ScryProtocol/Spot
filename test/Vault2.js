const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Vault2 Contract", function () {
    let Vault2, vault, owner, recoveryAddress, addr1, addr2;
    let token, nft;

    beforeEach(async function () {
        [owner, recoveryAddress, addr1, addr2] = await ethers.getSigners();

        const Token = await ethers.getContractFactory("ERC20Mock");
        token = await Token.deploy("Mock Token", "MTK", 1000000);
        await token.deployed();

        const NFT = await ethers.getContractFactory("ERC721Mock");
        nft = await NFT.deploy("Mock NFT", "MNFT");
        await nft.deployed();

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
    });

    describe("Initialization", function () {
        it("should initialize correctly", async function () {
            expect(await vault.owner()).to.equal(owner.address);
            expect(await vault.recoveryAddress()).to.equal(recoveryAddress.address);
            expect(await vault.dailyLimit()).to.equal(10);
            expect(await vault.threshold()).to.equal(1);
        });
    });

    describe("Deposits", function () {
        it("should deposit ERC20 tokens", async function () {
            await token.approve(vault.address, 100);
            await expect(vault.depositToken(token.address, 100))
                .to.emit(vault, "TokenDeposited")
                .withArgs(token.address, 100, owner.address);
        });

        it("should deposit NFTs", async function () {
            await nft.mint(owner.address, 1);
            await nft.approve(vault.address, 1);
            await expect(vault.depositNFT(nft.address, 1))
                .to.emit(vault, "NFTDeposited")
                .withArgs(nft.address, 1, owner.address);
        });
    });

    describe("Withdrawals", function () {
        beforeEach(async function () {
            await token.approve(vault.address, 100);
            await vault.depositToken(token.address, 100);
        });

        it("should withdraw under daily limit", async function () {
            await expect(vault.withdrawToken(addr1.address, token.address, 10))
                .to.emit(vault, "TokenWithdrawn")
                .withArgs(token.address, 10);
        });

        it("should queue withdrawal if exceeding daily limit", async function () {
            await expect(vault.withdrawToken(addr1.address, token.address, 20))
                .to.emit(vault, "TransactionQueued");
        });
    });

    describe("Transaction Confirmation", function () {
        it("should confirm queued transaction", async function () {
            await token.approve(vault.address, 100);
            await vault.depositToken(token.address, 100);

            await vault.withdrawToken(addr1.address, token.address, 50);
            await vault.confirmTransaction(0);

            const transaction = await vault.queuedTransactions(0);
            expect(transaction.confirmations).to.equal(1);
        });
    });

    describe("Recovery", function () {
        it("should allow recovery of tokens", async function () {
            await token.approve(vault.address, 100);
            await vault.depositToken(token.address, 100);

            await expect(vault.recover(token.address, addr2.address, 50, [], 1))
                .to.emit(vault, "TokenWithdrawn")
                .withArgs(token.address, 50);
        });

        it("should freeze the contract during recovery", async function () {
            await vault.recover(token.address, addr2.address, 50, [], 1);
            expect(await vault.freeze()).to.equal(1);
        });
    });
});
