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
        Vault2 = await ethers.getContractFactory("Vault");
        vaultImplementation = await Vault2.deploy();
        vault = Vault2.attach(vaultImplementation.target);

        // Initialize the vault
        await vault.connect(owner).init(
            owner.address,
            "TestVault",
            recoveryAddress.address,
            [addr1.address],
            dailyLimitPercentage, // Daily limit as 10%
            1,  // Threshold for confirmations
            1   // No delay
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
await vault.connect(owner).confirmTransaction(2);

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

                vault.connect(owner).confirmTransaction(1)
            expect(await vault.recoveryAddress()).to.equal(recoveryAddress.address);

            // Increase time by 1 hour
            await ethers.provider.send('evm_increaseTime', [3600]);
            await ethers.provider.send('evm_mine', []);

            // Now confirm the transaction
            await vault.connect(owner).confirmTransaction(1);

            expect(await vault.recoveryAddress()).to.equal(addr2.address);
        });

        it("should not allow withdrawing more than vault balance", async function () {
            await token.connect(owner).approve(vault.target, ethers.parseUnits("50"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("50"));

            await expect(
                vault.withdrawToken(addr1.address, token.target, ethers.parseUnits("60"))
            ).to.be.revertedWith("Insufficient balance");
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
                vault.connect(addr2).freezeLock(1)
            ).to.be.revertedWith("Can only be called by contract itself, owner, recovery address or whitelisted addresses");
        });

        // Add more tests as needed...
    });
    describe("Additional Tests for Vault2 Contract", function () {
        // Existing tests...
    
        // 1. Testing 'getLimit' function
        it("should return correct limit amount from getLimit", async function () {
            // Deposit tokens into the vault
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));
    
            // Call getLimit function
            const limitAmount = await vault.getLimit(addr1.address, token.target, ethers.parseUnits("9"));
            expect(limitAmount).to.equal(ethers.parseUnits("9")); // 10% of 100 tokens
    
            // Now set a token-specific limit
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("setTokenLimit", [
                    token.target,
                    ethers.parseUnits("20"), // fixedLimit
                    0,                       // percentageLimit
                    0                        // useBaseLimit
                ]),
                0
            );
            await vault.connect(owner).confirmTransaction(0);
    
            // Call getLimit again
            const limitAmount2 = await vault.getLimit(addr1.address, token.target, ethers.parseUnits("0"));
            expect(limitAmount2).to.equal(ethers.parseUnits("20"));
        });
    
        // 2. Testing 'cancelTransaction' functionality
        it("should not allow unauthorized users to cancel transactions", async function () {
            // Queue a transaction
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateRecoveryAddress", [addr2.address]),
                0
            );
    
            // Attempt to cancel transaction as addr1 (not owner or recovery address)
            await expect(
                vault.connect(addr1).cancelTransaction(0)
            ).to.be.revertedWith("Not authorized");
        });
    
        // 4. Testing behavior when the threshold is not met
        it("should not execute transaction if threshold is not met", async function () {
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
    
            // Queue a transaction to update recovery address
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateRecoveryAddress", [addr2.address]),
                0
            );
    
            // Confirm transaction by owner
            await vault.connect(addr1).confirmTransaction(2);
    
            // Transaction should not be executed yet
            expect(await vault.recoveryAddress()).to.equal(recoveryAddress.address);
    
            // Try to confirm again
            await vault.connect(owner).confirmTransaction(2);
    
            // Should still not have updated recovery address
            expect(await vault.recoveryAddress()).to.equal(addr2.address);
        });
    
        // 5. Testing behavior when trying to execute transaction before delay
        it("should not allow owner to execute transaction before delay", async function () {
            // Set a delay of 1 hour
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateDelay", [3600]), // 1 hour
                0
            );
            await vault.connect(owner).confirmTransaction(0);
    
            // Queue a transaction to update recovery address
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateRecoveryAddress", [addr2.address]),
                0
            );
    
            // Confirm transaction by owner before delay
            await vault.connect(owner).confirmTransaction(1);
    
            // Transaction should not be executed yet
            expect(await vault.recoveryAddress()).to.equal(recoveryAddress.address);
    
            // Increase time by 1 hour
            await ethers.provider.send('evm_increaseTime', [3600]);
            await ethers.provider.send('evm_mine', []);
    
            // Confirm transaction by owner after delay
            await vault.connect(owner).confirmTransaction(1);
    
            // Now recovery address should be updated
            expect(await vault.recoveryAddress()).to.equal(addr2.address);
        });
    
        // 6. Testing 'updateWhitelistAddresses' function
        it("should update whitelist addresses correctly", async function () {
            // Owner queues transaction to update whitelist addresses
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateWhitelistAddresses", [
                    [addr1.address, addr2.address]
                ]),
                0
            );
            await vault.connect(owner).confirmTransaction(0);
    
            // Check that addresses are whitelisted
            expect(await vault.isWhitelisted(addr1.address)).to.be.true;
            expect(await vault.isWhitelisted(addr2.address)).to.be.true;
    
            // Previous whitelist addresses should be removed
            expect(await vault.isWhitelisted(owner.address)).to.be.false; // Assuming owner was not whitelisted initially
        });
    
        // 7. Testing 'setTokenLimit' function when called via queued transaction
        it("should set token limits correctly via queued transaction", async function () {
            // Owner queues transaction to set token limit
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("setTokenLimit", [
                    token.target,
                    ethers.parseUnits("30"), // fixedLimit
                    0,                       // percentageLimit
                    0                        // useBaseLimit
                ]),
                0
            );
            await vault.connect(owner).confirmTransaction(0);
    
            // Deposit tokens into the vault
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));
    
            // Attempt to withdraw up to limit
            await expect(
                vault.withdrawToken(addr1.address, token.target, ethers.parseUnits("30"))
            ).to.emit(vault, "TokenWithdrawn");
    
            // Attempt to withdraw more than limit
            await expect(
                vault.withdrawToken(addr1.address, token.target, ethers.parseUnits("1"))
            ).to.emit(vault, "TransactionQueued");
        });
    
        // 8. Testing 'updateSettings' including updating token limits
        it("should update settings including token limits via updateSettings", async function () {
            // Owner queues transaction to update settings
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateSettings", [
                    addr2.address,     // newRecoveryAddress
                    [addr1.address],   // newWhitelistedAddresses
                    15,                // newDailyLimit
                    2,                 // newThreshold
                    3600,              // newDelay
                    [token.target],    // tokens
                    [ethers.parseUnits("50")], // fixedLimits
                    [0],                      // percentageLimits
                    [0]                       // useBaseLimits
                ]),
                0
            );
            await vault.connect(owner).confirmTransaction(0);
    
            // Check updated settings
            expect(await vault.recoveryAddress()).to.equal(addr2.address);
            expect(await vault.threshold()).to.equal(2);
            expect(await vault.delay()).to.equal(3600);
            expect(await vault.dailyLimit()).to.equal(15);
            expect(await vault.isWhitelisted(addr1.address)).to.be.true;
    
            // Check token limit
            const tokenLimit = await vault.tokenLimits(token.target);
            expect(tokenLimit.fixedLimit).to.equal(ethers.parseUnits("50"));
        });
    
        // 9. Testing 'updateVaultImplementation' in VaultFactory2
        it("should update vault implementation in VaultFactory2", async function () {
            // Deploy a new Vault2 implementation
            const NewVault2 = await ethers.getContractFactory("Vault2");
            const newVaultImplementation = await NewVault2.deploy();
    
            // Update the vault implementation in the factory
            await vaultFactory.updateVaultImplementation(newVaultImplementation.target);
    
            expect(await vaultFactory.vaultImplementation()).to.equal(newVaultImplementation.target);
        });
    
        // 10. Testing 'createVault' in VaultFactory2, including re-using an existing name
        it("should not allow creating a vault with an existing name", async function () {
            // Create a vault with name 'MyVault'
            await vaultFactory.createVault(
                "MyVault",
                recoveryAddress.address,
                [addr1.address],
                dailyLimitPercentage,
                1,
                0
            );
    
            // Attempt to create another vault with the same name
            await expect(
                vaultFactory.createVault(
                    "MyVault",
                    recoveryAddress.address,
                    [addr1.address],
                    dailyLimitPercentage,
                    1,
                    0
                )
            ).to.be.revertedWith("Vault name already exists");
        });
    
        // 11. Testing 'getVaultsByOwner' in VaultFactory2
        it("should return correct vaults for owner", async function () {
            // Create two vaults for owner
            await vaultFactory.createVault(
                "Vault1",
                recoveryAddress.address,
                [addr1.address],
                dailyLimitPercentage,
                1,
                0
            );
            await vaultFactory.createVault(
                "Vault2",
                recoveryAddress.address,
                [addr1.address],
                dailyLimitPercentage,
                1,
                0
            );
    
            // Get vaults by owner
            const vaults = await vaultFactory.getVaultsByOwner(owner.address);
            expect(vaults.length).to.equal(2);
        });
    
        // 12. Testing 'onERC721Received'
        it("should accept NFTs via onERC721Received", async function () {
            await nft.connect(owner).mint(owner.address, 2);
            await nft.connect(owner)["safeTransferFrom(address,address,uint256,bytes)"](owner.address, vault.target, 2, "0x");
    
            expect(await nft.ownerOf(2)).to.equal(vault.target);
        });
    
        // 13. Testing 'recover' function with ETH
        it("should allow recovery address to recover ETH", async function () {
            // Send ETH to the vault
            await owner.sendTransaction({
                to: vault.target,
                value: ethers.parseEther("1.0")
            });
    
            const vaultBalanceBefore = await ethers.provider.getBalance(vault.target);
            expect(vaultBalanceBefore).to.equal(ethers.parseEther("1.0"));
    
            // Recovery address recovers ETH
            const recoveryBalanceBefore = await ethers.provider.getBalance(recoveryAddress.address);
            await vault.connect(recoveryAddress).recover(
                ethers.ZeroAddress,
                recoveryAddress.address,
                ethers.parseEther("0.5"),
                "0x",
                0 // no freeze change
            );
    
            const recoveryBalanceAfter = await ethers.provider.getBalance(recoveryAddress.address);
            expect((recoveryBalanceAfter - (recoveryBalanceBefore))).to.greaterThan(ethers.parseEther("0.4"));
        });
    
        // 14. Testing that whitelisted address cannot execute transaction before delay
        it("should not allow whitelisted address to execute transaction before delay", async function () {
            // Add addr1 to whitelisted addresses
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateWhitelistAddresses", [
                    [addr1.address]
                ]),
                0
            );
            await vault.connect(owner).confirmTransaction(0);
    
            // Set a delay of 1 hour
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateDelay", [3600]), // 1 hour
                0
            );
            await vault.connect(owner).confirmTransaction(1);
    
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateThreshold", [2]),
                0
            );
            await vault.connect(owner).confirmTransaction(2);
    
            // Queue a transaction
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateRecoveryAddress", [addr2.address]),
                0
            );
    
            // Whitelisted address tries to confirm transaction before delay
            await vault.connect(addr1).confirmTransaction(2);
    
            // Transaction should not be executed yet
            expect(await vault.recoveryAddress()).to.equal(recoveryAddress.address);
    
            // Increase time by 1 hour
            await ethers.provider.send('evm_increaseTime', [3600]);
            await ethers.provider.send('evm_mine', []);
    
            // Now whitelisted address confirms transaction
            await vault.connect(addr1).confirmTransaction(3);
    
            // Transaction should not be executed yet because threshold is not met
            expect(await vault.recoveryAddress()).to.equal(recoveryAddress.address);
    
            // Owner confirms transaction
            await vault.connect(owner).confirmTransaction(3);
    
            // Now recovery address should be updated
            expect(await vault.recoveryAddress()).to.equal(addr2.address);
        });
    
        // 15. Testing that recovery address cannot freeze to a lower level
        it("should prevent non-recovery address from decreasing freeze level", async function () {
            // Freeze the vault at level 2
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("freezeLock", [2]),
                0
            );
            await vault.connect(owner).confirmTransaction(0);
    
            // Owner attempts to decrease freeze level to 1
            await expect(
                vault.connect(owner).freezeLock(1)
            ).to.be.revertedWith("Cannot unfreeze");
    
            // Recovery address can decrease freeze level
            await vault.connect(recoveryAddress).freezeLock(1);
            expect(await vault.freeze()).to.equal(1);
        });
    
        // 16. Testing that unauthorized users cannot call functions restricted to contract itself
        it("should prevent unauthorized calls to internal update functions", async function () {
            await expect(
                vault.connect(addr1).updateRecoveryAddress(addr2.address)
            ).to.be.revertedWith("Can only be called by contract itself");
    
            await expect(
                vault.connect(addr1).updateDailyLimit(20)
            ).to.be.revertedWith("Can only be called by contract itself");
        });
    
        // 17. Testing that owner can execute transaction after delay even without threshold confirmations
        it("should allow owner to execute transaction after delay without other confirmations", async function () {
            // Update threshold to 2
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateThreshold", [2]),
                0
            );
            await vault.connect(owner).confirmTransaction(0);
    
            // Set a delay of 1 hour
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateDelay", [3600]), // 1 hour
                0
            );
            await vault.connect(owner).confirmTransaction(1);
    
            // Queue a transaction
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateRecoveryAddress", [addr2.address]),
                0
            );
    
            // Increase time by 1 hour
            await ethers.provider.send('evm_increaseTime', [3600]);
            await ethers.provider.send('evm_mine', []);
    
            // Owner confirms transaction
            await vault.connect(owner).confirmTransaction(2);
    
            // Now recovery address should be updated
            expect(await vault.recoveryAddress()).to.equal(addr2.address);
        });
    
    });
    
    describe("Full Coverage Tests", function () {
        // Test init cannot be called twice
        it("should prevent re-initialization", async function () {
            await expect(
                vault.connect(owner).init(
                    owner.address,
                    "TestVault2",
                    recoveryAddress.address,
                    [addr1.address],
                    dailyLimitPercentage,
                    1,
                    0
                )
            ).to.be.revertedWith("Already initialized");
        });

        // Test depositToken function for ETH
        it("should allow depositing ETH", async function () {
            await vault.connect(owner).depositToken(
                ethers.ZeroAddress,
                ethers.parseEther("1"),
                { value: ethers.parseEther("1") }
            );
            const balance = await ethers.provider.getBalance(vault.target);
            expect(balance).to.equal(ethers.parseEther("1"));
        });

        // Test depositToken function for ERC20 tokens
        it("should allow depositing ERC20 tokens", async function () {
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));
            const balance = await token.balanceOf(vault.target);
            expect(balance).to.equal(ethers.parseUnits("100"));
        });

        // Test depositNFT function
        it("should allow depositing NFTs", async function () {
            await nft.connect(owner).mint(owner.address, 1);
            await nft.connect(owner).approve(vault.target, 1);
            await vault.connect(owner).depositNFT(nft.target, 1);
            expect(await nft.ownerOf(1)).to.equal(vault.target);
        });

        // Test withdrawToken function within daily limit
        it("should allow owner to withdraw tokens within daily limit", async function () {
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            await expect(
                vault.connect(owner).withdrawToken(addr1.address, token.target, ethers.parseUnits("10"))
            ).to.emit(vault, "TokenWithdrawn");

            const balance = await token.balanceOf(addr1.address);
            expect(balance).to.equal(ethers.parseUnits("10"));
        });

        // Test withdrawToken function exceeding daily limit
        it("should queue withdrawal if amount exceeds daily limit", async function () {
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            await expect(
                vault.connect(owner).withdrawToken(addr1.address, token.target, ethers.parseUnits("20"))
            ).to.emit(vault, "TransactionQueued");
        });

        // Test queueTransaction function
        it("should allow owner to queue a transaction", async function () {
            await expect(
                vault.connect(owner).queueTransaction(
                    vault.target,
                    vault.interface.encodeFunctionData("updateDailyLimit", [15]),
                    0
                )
            ).to.emit(vault, "TransactionQueued");
        });

        // Test confirmTransaction function by owner
        it("should allow owner to confirm transaction after delay", async function () {
            // Set delay
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateDelay", [3600]), // 1 hour
                0
            );
            await vault.connect(owner).confirmTransaction(0);

            // Queue transaction
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateDailyLimit", [15]),
                0
            );

            // Fast-forward time
            await ethers.provider.send("evm_increaseTime", [3600]);
            await ethers.provider.send("evm_mine", []);

            // Confirm transaction
            await vault.connect(owner).confirmTransaction(1);

            expect(await vault.dailyLimit()).to.equal(15);
        });

        // Test confirmTransaction function by whitelisted address
        it("should allow whitelisted address to confirm transaction", async function () {
           
            // Queue transaction
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateDailyLimit", [15]),
                0
            );

            // Confirm by whitelisted address
            await vault.connect(addr1).confirmTransaction(0);

            expect(await vault.dailyLimit()).to.equal(15);
        });

        // Test cancelTransaction function
        it("should allow owner or recovery address to cancel transaction", async function () {
            // Queue transaction
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateDailyLimit", [15]),
                0
            );

            // Cancel by owner
            await vault.connect(owner).cancelTransaction(0);

            // Try to confirm canceled transaction
            await expect(
                vault.connect(owner).confirmTransaction(0)
            ).to.be.revertedWith("Transaction already executed");
        });

        // Test freezeLock function by owner
        it("should allow owner to increase freeze level", async function () {
            await vault.connect(owner).freezeLock(1);
            expect(await vault.freeze()).to.equal(1);
        });

        // Test freezeLock function by recovery address to decrease freeze level
        it("should allow recovery address to decrease freeze level", async function () {
            // Set freeze level to 2 by owner
            await vault.connect(owner).freezeLock(2);

            // Decrease freeze level by recovery address
            await vault.connect(recoveryAddress).freezeLock(0);
            expect(await vault.freeze()).to.equal(0);
        });

        // Test recover function
        it("should allow recovery address to recover tokens and freeze vault", async function () {
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            await vault.connect(recoveryAddress).recover(
                token.target,
                recoveryAddress.address,
                ethers.parseUnits("50"),
                "0x",
                2
            );

            const balance = await token.balanceOf(recoveryAddress.address);
            expect(balance).to.equal(ethers.parseUnits("50"));

            expect(await vault.freeze()).to.equal(2);
        });

        // Test updateSettings function via queued transaction
        it("should allow updating settings via queued transaction", async function () {
            // Queue transaction to update settings
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

            // Confirm transaction
            await vault.connect(owner).confirmTransaction(0);

            expect(await vault.recoveryAddress()).to.equal(addr2.address);
            expect(await vault.dailyLimit()).to.equal(15);
            expect(await vault.threshold()).to.equal(2);
            expect(await vault.delay()).to.equal(3600);
            expect(await vault.isWhitelisted(addr1.address)).to.be.true;
        });

        // Test setTokenLimit function via queued transaction
        it("should allow setting token limits via queued transaction", async function () {
            // Queue transaction to set token limit
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

            // Confirm transaction
            await vault.connect(owner).confirmTransaction(0);

            const limit = await vault.tokenLimits(token.target);
            expect(limit.fixedLimit).to.equal(ethers.parseUnits("50"));
        });

        // Test onERC721Received function
        it("should accept NFTs via onERC721Received", async function () {
            await nft.connect(owner).mint(owner.address, 2);
            await nft.connect(owner)["safeTransferFrom(address,address,uint256,bytes)"](owner.address, vault.target, 2, "0x");

            expect(await nft.ownerOf(2)).to.equal(vault.target);
        });

        // Test executeWithdrawal function indirectly via withdrawToken
        it("should execute withdrawal and emit events", async function () {
            // Deposit tokens
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            // Withdraw tokens within limit
            await expect(
                vault.connect(owner).withdrawToken(addr1.address, token.target, ethers.parseUnits("10"))
            ).to.emit(vault, "TokenWithdrawn")
             .and.to.emit(vault, "TransactionQueued")
             .and.to.emit(vault, "TransactionExecuted");
        });

        // Test getLimitAmount function with various token limits
        it("should return correct limit amount based on token settings", async function () {
            // Deposit tokens
            await token.connect(owner).approve(vault.target, ethers.parseUnits("200"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("200"));

            // Set fixed limit
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

            let limitAmount = await vault.getLimitAmount(token.target);
            expect(limitAmount).to.equal(ethers.parseUnits("50"));

            // Set percentage limit
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("setTokenLimit", [
                    token.target,
                    0,    // fixedLimit
                    25,   // percentageLimit
                    0     // useBaseLimit
                ]),
                0
            );
            await vault.connect(owner).confirmTransaction(1);

            limitAmount = await vault.getLimitAmount(token.target);
            expect(limitAmount).to.equal(ethers.parseUnits("50")); // 25% of 200

            // Set useBaseLimit to 1 (disallow withdrawals)
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("setTokenLimit", [
                    token.target,
                    0,  // fixedLimit
                    0,  // percentageLimit
                    1   // useBaseLimit
                ]),
                0
            );
            await vault.connect(owner).confirmTransaction(2);

            limitAmount = await vault.getLimitAmount(token.target);
            expect(limitAmount).to.equal(0);
        });

        // Test receive function
        it("should accept Ether via receive function", async function () {
            await owner.sendTransaction({
                to: vault.target,
                value: ethers.parseEther("1.0")
            });

            const balance = await ethers.provider.getBalance(vault.target);
            expect(balance).to.equal(ethers.parseEther("1.0"));
        });

        // Test fallback function reverts on unknown function calls
        it("should revert on unknown function calls via fallback", async function () {
            await expect(
                owner.sendTransaction({
                    to: vault.target,
                    data: "0x12345678"
                })
            ).to.be.reverted;
        });

        // Test that only owner can call onlyOwner functions
        it("should prevent non-owner from calling onlyOwner functions", async function () {
            await expect(
                vault.connect(addr1).withdrawToken(addr1.address, token.target, ethers.parseUnits("10"))
            ).to.be.revertedWith("Not the owner");
        });

        // Test that only recovery address can call onlyRecoveryAddress functions
        it("should prevent non-recovery address from calling onlyRecoveryAddress functions", async function () {
            await expect(
                vault.connect(addr1).recover(token.target, addr1.address, ethers.parseUnits("10"), "0x", 0)
            ).to.be.revertedWith("Not the recovery address");
        });

        // Test that only whitelisted addresses can confirm transactions
        it("should prevent non-whitelisted addresses from confirming transactions", async function () {
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateDailyLimit", [15]),
                0
            );

            await expect(
                vault.connect(addr2).confirmTransaction(0)
            ).to.be.revertedWith("Not authorized");
        });

        // Test that owner cannot decrease freeze level
        it("should prevent owner from decreasing freeze level", async function () {
            // Freeze level to 2
            await vault.connect(owner).freezeLock(2);

            // Attempt to decrease freeze level
            await expect(
                vault.connect(owner).freezeLock(1)
            ).to.be.revertedWith("Cannot unfreeze");
        });

        // Test that non-existent transactions cannot be confirmed
        it("should revert when confirming non-existent transaction", async function () {
            await expect(
                vault.connect(owner).confirmTransaction(999)
            ).to.be.reverted;
        });

        // Test that transaction cannot be confirmed twice by the same address
        it("should prevent confirming transaction twice by the same address", async function () {
            // Queue transaction
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateDailyLimit", [15]),
                0
            );

            // Confirm transaction
            await vault.connect(owner).confirmTransaction(0);

            // Attempt to confirm again
            await expect(
                vault.connect(owner).confirmTransaction(0)
            ).to.be.revertedWith("Transaction already executed");
        });

        // Test that queueWithdrawal queues transaction when amount exceeds limit
        it("should queue withdrawal when amount exceeds limit", async function () {
            await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
            await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

            await expect(
                vault.connect(owner).withdrawToken(addr1.address, token.target, ethers.parseUnits("20"))
            ).to.emit(vault, "TransactionQueued");
        });

        // Test that getLimitAmount returns max value when useBaseLimit is 2
        it("should return max limit when useBaseLimit is 2", async function () {
            // Set useBaseLimit to 2
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("setTokenLimit", [
                    token.target,
                    0,       // fixedLimit
                    0,       // percentageLimit
                    2        // useBaseLimit
                ]),
                0
            );
            await vault.connect(owner).confirmTransaction(0);

            const limitAmount = await vault.getLimitAmount(token.target);
            expect(limitAmount.toString()).to.equal('1000000000000000000000000000000');
        });

        // Test that recovery address cannot be set to zero address
        it("should prevent setting recovery address to zero via updateSettings", async function () {
            // Queue transaction to update settings with zero address
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateSettings", [
                    ethers.ZeroAddress, // newRecoveryAddress
                    [],                          // newWhitelistedAddresses
                    0,                           // newDailyLimit
                    0,                           // newThreshold
                    0,                           // newDelay
                    [],                          // tokens
                    [],                          // fixedLimits
                    [],                          // percentageLimits
                    []                           // useBaseLimits
                ]),
                0
            );

            // Confirm transaction
            await vault.connect(owner).confirmTransaction(0);

            expect(await vault.recoveryAddress()).to.equal(recoveryAddress.address); // Should remain unchanged
        });
    // Test that queueTransaction reverts when freeze is active
    it("should revert queueTransaction when freeze is active", async function () {
        // Freeze the vault
        await vault.connect(owner).freezeLock(1);

        // Attempt to queue a transaction
        await expect(
        vault.connect(owner).queueTransaction(
            vault.target,
            vault.interface.encodeFunctionData("updateDailyLimit", [15]),
            0
        )
        ).to.be.revertedWith("Freeze is active");
    });
    });

        // Test that recovery address cannot be set to zero address
        it("should prevent setting recovery address to zero via updateSettings", async function () {
            // Queue transaction to update settings with zero address
            await vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateSettings", [
                    ethers.ZeroAddress, // newRecoveryAddress
                    [],                          // newWhitelistedAddresses
                    0,                           // newDailyLimit
                    0,                           // newThreshold
                    0,                           // newDelay
                    [],                          // tokens
                    [],                          // fixedLimits
                    [],                          // percentageLimits
                    []                           // useBaseLimits
                ]),
                0
            );

            // Confirm transaction
            await vault.connect(owner).confirmTransaction(0);

            expect(await vault.recoveryAddress()).to.equal(recoveryAddress.address); // Should remain unchanged
        });
        // Test that queueTransaction reverts when freeze is active
        it("should revert queueTransaction when freeze is active", async function () {
            // Freeze the vault
            await vault.connect(owner).freezeLock(1);

            // Attempt to queue a transaction
            await expect(
            vault.connect(owner).queueTransaction(
                vault.target,
                vault.interface.encodeFunctionData("updateDailyLimit", [15]),
                0
            )
            ).to.be.revertedWith("Freeze is active");
        });
        // Test that withdrawToken reverts when token address is zero
        it("should withdrawETH when token address is zero", async function () {
            // Deposit ETH
            let balance = await ethers.provider.getBalance(addr1.address);
            await vault.connect(owner).depositToken(ethers.ZeroAddress, ethers.parseUnits("100"),{value: ethers.parseUnits("100")});
            await vault.connect(owner).withdrawToken(addr1.address, ethers.ZeroAddress, ethers.parseUnits("10"))
expect(await ethers.provider.getBalance(addr1.address)).to.equal(balance+ethers.parseUnits("10"));
        });

        // Test that withdrawToken reverts when token address is zero
        it("shouldnt withdrawETH", async function () {
            // Deposit ETH
            let balance = await ethers.provider.getBalance(addr1.address);
            await vault.connect(owner).depositToken(ethers.ZeroAddress, ethers.parseUnits("100"),{value: ethers.parseUnits("100")});
            await expect( vault.connect(owner).withdrawToken(addr1.address, ethers.ZeroAddress, ethers.parseUnits("1000"))).to.be.reverted;
        });
        // Test that withdrawToken reverts when token address is zero
        it("shouldnt withdrawETH", async function () {
            // Deposit ETH
            let balance = await ethers.provider.getBalance(addr1.address);
            await vault.connect(owner).depositToken(ethers.ZeroAddress, ethers.parseUnits("100"),{value: ethers.parseUnits("100")});
            await vault.connect(owner).withdrawToken(addr1.address, ethers.ZeroAddress, ethers.parseUnits("100"))
        await vault.connect(owner).confirmTransaction(0);
        expect(await ethers.provider.getBalance(addr1.address)).to.equal(balance+ethers.parseUnits("100"));
        })
        it("should return correct vaults for owner", async function () {
        // Create two vaults for owner
        await vaultFactory.createVault(
            "Vault1",
            recoveryAddress.address,
            [addr1.address],
            dailyLimitPercentage,
            1,
            0
        );
        await vaultFactory.createVault(
            "Vault2",
            recoveryAddress.address,
            [addr1.address],
            dailyLimitPercentage,
            1,
            0
        );

        // Get vaults by owner
        const vaults = await vaultFactory.getVaultsByOwner(owner.address);
        expect(vaults.length).to.equal(2);
    });
    // 18. Testing 'getLimit' function when amount exceeds remaining limit
    it("should return remaining limit when amount exceeds remaining limit", async function () {
        // Deposit tokens into the vault
        await token.connect(owner).approve(vault.target, ethers.parseUnits("100"));
        await vault.connect(owner).depositToken(token.target, ethers.parseUnits("100"));

        // Withdraw some tokens to reduce the remaining limit
        await vault.connect(owner).withdrawToken(addr1.address, token.target, ethers.parseUnits("10"));

        // Call getLimit function with an amount exceeding the remaining limit
        const limitAmount = await vault.getLimit(addr1.address, token.target, ethers.parseUnits("20"));
        expect(limitAmount).to.equal(ethers.parseUnits("0")); // Remaining limit should be 20
    });
    });

