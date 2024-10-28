const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("SimpleProxy Contract", function () {
    let SimpleProxy, proxy, vault, owner, addr1;

    beforeEach(async function () {
        [owner, addr1] = await ethers.getSigners();

        const Vault2 = await ethers.getContractFactory("Vault2");
        vault = await Vault2.deploy();
        await vault.deployed();

        const SimpleProxy = await ethers.getContractFactory("SimpleProxy");
        proxy = await SimpleProxy.deploy(vault.address);
        await proxy.deployed();
    });

    it("should delegate calls to implementation", async function () {
        const proxyVault = await ethers.getContractAt("Vault2", proxy.address);
        await proxyVault.init(
            owner.address,
            "ProxyVault",
            addr1.address,
            [addr1.address],
            10,
            1,
            0
        );

        expect(await proxyVault.owner()).to.equal(owner.address);
        expect(await proxyVault.recoveryAddress()).to.equal(addr1.address);
    });

    it("should delegate token deposits", async function () {
        const proxyVault = await ethers.getContractAt("Vault2", proxy.address);
        await proxyVault.init(owner.address, "ProxyVault", addr1.address, [addr1.address], 10, 1, 0);

        const Token = await ethers.getContractFactory("ERC20Mock");
        const token = await Token.deploy("Mock Token", "MTK", 1000000);
        await token.deployed();

        await token.approve(proxy.address, 100);
        await expect(proxyVault.depositToken(token.address, 100))
            .to.emit(proxyVault, "TokenDeposited")
            .withArgs(token.address, 100, owner.address);
    });

    it("should advance time by 24 hours", async function () {
        const initialBlockTime = (await ethers.provider.getBlock('latest')).timestamp;

        // Advance time by 24 hours
        await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]); // 24 hours
        await ethers.provider.send("evm_mine"); // Mine a new block to update the timestamp

        const newBlockTime = (await ethers.provider.getBlock('latest')).timestamp;
        // Verify that the time has advanced by approximately 24 hours
        expect(newBlockTime).to.be.closeTo(initialBlockTime + 24 * 60 * 60, 2);  // 2 seconds tolerance
    });
});
