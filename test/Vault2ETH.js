const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Vault2 ETH Handling", function () {
    let Vault2, vault, owner, addr1, recoveryAddress;

    beforeEach(async function () {
        [owner, recoveryAddress, addr1] = await ethers.getSigners();

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

    describe("ETH Deposits", function () {
        it("should allow ETH deposits", async function () {
            await expect(() =>
                owner.sendTransaction({ to: vault.address, value: ethers.utils.parseEther("1") })
            ).to.changeEtherBalance(vault, ethers.utils.parseEther("1"));

            await expect(vault.depositToken(ethers.constants.AddressZero, ethers.utils.parseEther("1")))
                .to.emit(vault, "TokenDeposited")
                .withArgs(ethers.constants.AddressZero, ethers.utils.parseEther("1"), owner.address);
        });
    });

    describe("ETH Withdrawals", function () {
        beforeEach(async function () {
            // Deposit 10 ETH
            await owner.sendTransaction({ to: vault.address, value: ethers.utils.parseEther("10") });
        });

        it("should allow ETH withdrawals within daily limit", async function () {
            // Daily limit is 1 ETH (10%)
            await expect(vault.withdrawToken(addr1.address, ethers.constants.AddressZero, ethers.utils.parseEther("1")))
                .to.emit(vault, "TokenWithdrawn")
                .withArgs(ethers.constants.AddressZero, ethers.utils.parseEther("1"));
        });

        it("should queue ETH withdrawals exceeding daily limit", async function () {
            // Exceeding 1 ETH daily limit
            await expect(vault.withdrawToken(addr1.address, ethers.constants.AddressZero, ethers.utils.parseEther("2")))
                .to.emit(vault, "TransactionQueued");
        });
    });

    describe("ETH Recovery", function () {
        beforeEach(async function () {
            // Deposit 5 ETH
            await owner.sendTransaction({ to: vault.address, value: ethers.utils.parseEther("5") });
        });

        it("should allow ETH recovery by recovery address", async function () {
            await expect(vault.connect(recoveryAddress).recover(ethers.constants.AddressZero, addr1.address, ethers.utils.parseEther("3"), [], 1))
                .to.emit(vault, "TokenWithdrawn")
                .withArgs(ethers.constants.AddressZero, ethers.utils.parseEther("3"));

            expect(await ethers.provider.getBalance(vault.address)).to.equal(ethers.utils.parseEther("2"));
        });

        it("should freeze contract during ETH recovery", async function () {
            await vault.connect(recoveryAddress).recover(ethers.constants.AddressZero, addr1.address, ethers.utils.parseEther("2"), [], 1);
            expect(await vault.freeze()).to.equal(1);
        });
    });
});
