const { expect } = require("chai");
const { ethers } = require("hardhat");
describe("Vault System with Target Reference", function () {
    let Vault2, vaultImplementation, vaultProxy, vault, SimpleProxy, VaultFactory2, vaultFactory;
    let owner, recoveryAddress, addr1, addr2, otherSigner;
    let token, nft;
    const dailyLimitPercentage = 10; // Set daily limit to 10%

    beforeEach(async function () {
        [owner, recoveryAddress, addr1, addr2, otherSigner] = await ethers.getSigners();

        // Deploy mock ERC20 and ERC721 tokens
        const Token = await ethers.getContractFactory("ERC20Mock");
        token = await Token.deploy("Mock Token", "MTK", ethers.parseUnits("1000"));

        const NFT = await ethers.getContractFactory("ERC721Mock");
        nft = await NFT.deploy("Mock NFT", "MNFT");

        // Deploy Vault2 implementation
        Vault2 = await ethers.getContractFactory("Vault2");
        vaultImplementation = await Vault2.deploy();

        // Deploy the proxy
        SimpleProxy = await ethers.getContractFactory("SimpleProxy");
        vaultProxy = await SimpleProxy.deploy(vaultImplementation.target);

        // Attach Vault2 interface to proxy address
        vault = Vault2.attach(vaultProxy.target);

        // Initialize the vault
        await vault.connect(owner).init(
            owner.address,
            "TestVault",
            recoveryAddress.address,
            [addr1.address],
            dailyLimitPercentage, // Daily limit as 10%
            1,  // Threshold for confirmations
            0   // No delay
        );

        // Deploy VaultFactory2 and set vault implementation
        VaultFactory2 = await ethers.getContractFactory("VaultFactory2");
        vaultFactory = await VaultFactory2.deploy(vaultImplementation.target);
    });

    describe("Vault2 Contract with Target", function () {
        it("should initialize correctly", async function () {
            expect(await vault.owner()).to.equal(owner.address);
            expect(await vault.recoveryAddress()).to.equal(recoveryAddress.address);
            expect(await vault.dailyLimit()).to.equal(dailyLimitPercentage);
            expect(await vault.threshold()).to.equal(1);
        });

        it("should allow deposits of ERC20 tokens", async function () {
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            const balance = await token.balanceOf(vault.target);
            expect(balance).to.equal(ethers.parseUnits("100"));
        });

        it("should allow deposits of NFTs", async function () {
            await nft.connect(owner).mint(owner.address, 1);
            await nft.connect(owner).approve(vault.target, 1);
            await vault.connect(owner).depositNFT(nft.target, 1);

            expect(await nft.ownerOf(1)).to.equal(vault.target);
        });

        it("should queue a transaction if it exceeds daily limit", async function () {
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            await expect(vault.withdrawToken(addr1.address, token.target, ethers.parseUnits("20")))
                .to.emit(vault, "TransactionQueued");
        });

        it("should execute a transaction if within daily limit", async function () {
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            await expect(vault.withdrawToken(addr1.address, token.target, ethers.parseUnits("10")))
                .to.emit(vault, "TokenWithdrawn");
            const balance = await token.balanceOf(addr1.address);
            expect(balance).to.equal(ethers.parseUnits("10"));
        });

        it("should restrict withdrawal by non-owner", async function () {
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            await expect(
                vault.connect(addr1).withdrawToken(addr1.address, token.target, ethers.parseUnits("10"))
            ).to.be.revertedWith("Not the owner");
        });

        it("should update the recovery address correctly", async function () {
            await vault.connect(owner).queueTransaction(vault.target, vault.interface.encodeFunctionData("updateRecoveryAddress", [addr2.address]), 0);
            await vault.connect(owner).confirmTransaction(0);
            expect(await vault.recoveryAddress()).to.equal(addr2.address);
        });

        it("should allow the recovery address to cancel a transaction", async function () {
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));
            await vault.connect(owner).queueTransaction(addr1.address,'0x', ethers.parseUnits("20"));

            await vault.connect(recoveryAddress).cancelTransaction(0);

            const tx = await vault.queuedTransactions(0);
            expect(tx.executed).to.be.true;
            expect(tx.confirmations).to.equal(404); // Confirmation count set to 404 upon cancellation
        });

        it("should restrict recovery actions to the recovery address", async function () {
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            await expect(vault.connect(addr1).recover(token.target, addr1.address, ethers.parseUnits("10"), "0x", 1))
                .to.be.revertedWith("Not the recovery address");
        });
    });

    describe("Additional Tests for Vault2 Contract", function () {

        // 1. Token Limit Functionality
        it("should enforce token-specific fixed withdrawal limits", async function () {
            // Set a fixed limit for the token
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("setTokenLimit", [
                    token.target,
                    ethers.parseUnits("50"), // fixedLimit
                    0,                       // percentageLimit
                    0                        // useBaseLimit
                ]),
                0
            );
            await vault.connect(owner).confirmTransaction(0);

            // Deposit tokens into the vault
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            // Attempt to withdraw more than the fixed limit
            await expect(
                vault.withdrawToken(addr1.address, token.target, ethers.parseUnits("60"))
            ).to.emit(vault, "TransactionQueued");

            // Attempt to withdraw within the fixed limit
            await expect(
                vault.withdrawToken(addr1.address, token.target, ethers.parseUnits("50"))
            ).to.emit(vault, "TokenWithdrawn");

            // Check that the balance of addr1 is correct
            const balance = await token.balanceOf(addr1.address);
            expect(balance).to.equal(ethers.parseUnits("50"));
        });

        it("should enforce token-specific percentage withdrawal limits", async function () {
            // Set a percentage limit for the token
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("setTokenLimit", [
                    token.target,
                    0,    // fixedLimit
                    25,   // percentageLimit (25%)
                    0     // useBaseLimit
                ]),
                0
            );
            await vault.connect(owner).confirmTransaction(0);

            // Deposit tokens into the vault
            await token.connect(owner).approve(vault.target, ethers.parseUnits("200"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("200"));

            // Attempt to withdraw more than 25% of the balance
            await expect(
                vault.withdrawToken(addr1.address, token.target, ethers.parseUnits("51"))
            ).to.emit(vault, "TransactionQueued");

            // Attempt to withdraw exactly 25% of the balance
            await expect(
                vault.withdrawToken(addr1.address, token.target, ethers.parseUnits("50"))
            ).to.emit(vault, "TokenWithdrawn");

            const balance = await token.balanceOf(addr1.address);
            expect(balance).to.equal(ethers.parseUnits("50"));
        });

        it("should disallow withdrawals when useBaseLimit is set to 1", async function () {
            // Set useBaseLimit to 1 (disallow withdrawals)
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("setTokenLimit", [
                    token.target,
                    0,  // fixedLimit
                    0,  // percentageLimit
                    1   // useBaseLimit = 1 (disallow withdrawals)
                ]),
                0
            );
            await vault.connect(owner).confirmTransaction(0);

            // Deposit tokens into the vault
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            // Attempt to withdraw any amount
            await expect(
                vault.withdrawToken(addr1.address, token.target, ethers.parseUnits("10"))
            ).to.emit(vault, "TransactionQueued"); // Should queue the transaction

            // Confirm and try to execute the transaction
            await vault.connect(owner).confirmTransaction(1);
            // The transaction should not execute due to disallowed withdrawals
        });

        // 2. Freeze Functionality
        it("should prevent withdrawals when vault is frozen", async function () {
            // Freeze the vault
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("freezeLock", [2]), // freeze level 2
                0
            );
            await vault.connect(owner).confirmTransaction(0);

            // Deposit tokens into the vault
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            // Attempt to withdraw tokens
            await expect(
                vault.withdrawToken(addr1.address, token.target, ethers.parseUnits("10"))
            ).to.be.revertedWith("Freeze is active");
        });

        it("should allow withdrawals after unfreezing the vault", async function () {
            // Freeze the vault
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("freezeLock", [2]), // freeze level 2
                0
            );
            await vault.connect(owner).confirmTransaction(0);

            // Unfreeze the vault
            await vault.connect(recoveryAddress).freezeLock(0
            );
            // Deposit tokens into the vault
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            // Attempt to withdraw tokens
            await expect(
                vault.withdrawToken(addr1.address, token.target, ethers.parseUnits("10"))
            ).to.emit(vault, "TokenWithdrawn");
        });

        // 3. Recovery Mechanisms
        it("should allow recovery address to recover funds", async function () {
            // Deposit tokens into the vault
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            // Recovery address recovers tokens
            await vault.connect(recoveryAddress).recover(
                token.target,
                recoveryAddress.address,
                ethers.parseUnits("50"),
                "0x",
                0 // no freeze change
            );

            const balance = await token.balanceOf(recoveryAddress.address);
            expect(balance).to.equal(ethers.parseUnits("50"));
        });

        it("should prevent non-recovery address from performing recovery", async function () {
            await expect(
                vault.connect(addr1).recover(
                    token.target,
                    addr1.address,
                    ethers.parseUnits("10"),
                    "0x",
                    0
                )
            ).to.be.revertedWith("Not the recovery address");
        });

        // 4. Updating Vault Settings
        it("should allow updating vault settings via updateSettings", async function () {
            // Owner queues transaction to update settings
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateSettings", [
                    addr2.address,     // newRecoveryAddress
                    [addr1.address],   // newWhitelistedAddresses
                    15,                // newDailyLimit
                    2,                 // newThreshold
                    3600,              // newDelay
                    [],                // tokens
                    [],                // fixedLimits
                    [],                // percentageLimits
                    []                 // useBaseLimits
                ]),
                0
            );
            await vault.connect(owner).confirmTransaction(0);

            expect(await vault.recoveryAddress()).to.equal(addr2.address);
            expect(await vault.threshold()).to.equal(2);
            expect(await vault.delay()).to.equal(3600);
            expect(await vault.dailyLimit()).to.equal(15);
            expect(await vault.isWhitelisted(addr1.address)).to.be.true;
        });

        it("should restrict updateSettings to be called by contract or recovery address", async function () {
            await expect(
                vault.connect(addr1).updateSettings(
                    addr2.address,
                    [],
                    0,
                    0,
                    0,
                    [],
                    [],
                    [],
                    []
                )
            ).to.be.revertedWith("Not authorized");
        });

        // 5. Confirmation Mechanism
        it("should execute transaction after required confirmations", async function () {
            // Add addr1 to whitelisted addresses
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateWhitelistAddresses", [
                    [addr1.address]
                ]),
                0
            );
            await vault.connect(owner).confirmTransaction(0);

            // Update threshold to 2
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateThreshold", [2]),
                0
            );
            await vault.connect(owner).confirmTransaction(1);

            // Queue a transaction
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateRecoveryAddress", [addr2.address]),
                0
            );

            // Confirm transaction by whitelisted address
            await vault.connect(addr1).confirmTransaction(2);

            // Now transaction should be executed
            expect(await vault.recoveryAddress()).to.equal(addr2.address);
        });

        // 6. Delay Mechanism
        it("should enforce delay for owner transaction execution", async function () {
            // Set a delay of 1 hour
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateDelay", [3600]), // 1 hour
                0
            );
            await vault.connect(owner).confirmTransaction(0);

            // Queue a transaction
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateRecoveryAddress", [addr2.address]),
                0
            );

            // Try to confirm immediately
            await expect(
                vault.connect(owner).confirmTransaction(1)
            ).to.be.revertedWith("Not enough confirmations");

            // Increase time by 1 hour
            await ethers.provider.send('evm_increaseTime', [3600]);
            await ethers.provider.send('evm_mine', []);

            // Now confirm the transaction
            await vault.connect(owner).confirmTransaction(1);

            expect(await vault.recoveryAddress()).to.equal(addr2.address);
        });

        // 7. Edge Cases and Error Handling
        it("should not allow withdrawing zero tokens", async function () {
            await expect(
                vault.withdrawToken(addr1.address, token.target, 0)
            ).to.be.revertedWith("Insufficient balance");
        });

        it("should not allow withdrawing more than vault balance", async function () {
            await token.connect(owner).approve(vault.target, ethers.parseUnits("50"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("50"));

            await expect(
                vault.withdrawToken(addr1.address, token.target, ethers.parseUnits("60"))
            ).to.be.revertedWith("Insufficient balance");
        });

        it("should not allow withdrawals to invalid addresses", async function () {
            await token.connect(owner).approve(vault.target, ethers.parseUnits("50"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("50"));

            await expect(
                vault.withdrawToken(ethers.ZeroAddress, token.target, ethers.parseUnits("10"))
            ).to.be.reverted; // Transaction should fail due to invalid 'to' address
        });

        // 8. Fallback and Receive Functions
        it("should accept ETH deposits via receive function", async function () {
            // Send ETH directly to the vault
            await owner.sendTransaction({
                to: vault.target,
                value: ethers.parseEther("1.0")
            });

            const balance = await ethers.provider.getBalance(vault.target);
            expect(balance).to.equal(ethers.parseEther("1.0"));
        });

        it("should handle calls to fallback function", async function () {
            // Call an undefined function
            const tx = {
                to: vault.target,
                data: "0x12345678" // Some random data
            };
            await expect(owner.sendTransaction(tx)).to.be.reverted; // Should revert due to fallback
        });

        // 9. Access Control
        it("should restrict freezeLock to authorized addresses", async function () {
            await expect(
                vault.connect(addr1).freezeLock(1)
            ).to.be.revertedWith("Can only be called by contract itself, owner, recovery address or whitelisted addresses");
        });

        // Add more tests as needed...
    });});

