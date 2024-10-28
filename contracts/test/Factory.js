const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("VaultFactory2 Contract", function () {
    let factory, vaultImplementation, owner, addr1, addr2;

    beforeEach(async function () {
        [owner, addr1, addr2] = await ethers.getSigners();

        const Vault2 = await ethers.getContractFactory("Vault2");
        vaultImplementation = await Vault2.deploy();
        await vaultImplementation.deployed();

        const VaultFactory2 = await ethers.getContractFactory("VaultFactory2");
        factory = await VaultFactory2.deploy(vaultImplementation.address);
        await factory.deployed();
    });

    it("should create a new vault and assign to owner", async function () {
        const tx = await factory.createVault("TestVault", addr1.address, [addr1.address], 10, 1, 0);
        const receipt = await tx.wait();
        const event = receipt.events.find(event => event.event === "VaultCreated");

        const vaultAddress = event.args.vaultAddress;
        const vault = await ethers.getContractAt("Vault2", vaultAddress);

        expect(await vault.owner()).to.equal(owner.address);
        expect(await vault.name()).to.equal("TestVault");
        expect(await vault.recoveryAddress()).to.equal(addr1.address);
    });

    it("should maintain owner-to-vault mapping", async function () {
        await factory.createVault("Vault1", addr1.address, [addr1.address], 10, 1, 0);
        await factory.createVault("Vault2", addr2.address, [addr2.address], 15, 1, 0);

        const vaults = await factory.getVaultsByOwner(owner.address);
        expect(vaults.length).to.equal(2);
    });

    it("should update vault implementation", async function () {
        const NewVault = await ethers.getContractFactory("Vault2");
        const newVaultImplementation = await NewVault.deploy();
        await newVaultImplementation.deployed();

        await factory.updateVaultImplementation(newVaultImplementation.address);
        expect(await factory.vaultImplementation()).to.equal(newVaultImplementation.address);
    });
});
