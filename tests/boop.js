const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Stream Contract Tests", function () {
    let Stream, stream, Token, token;
    let owner, streamer, recipient, feeAddress;
    const feePercentage = 10;

    beforeEach(async () => {
        [owner, streamer, recipient, feeAddress] = await ethers.getSigners();

        // Deploy a mock token
        Token = await ethers.getContractFactory("MockERC20"); // Assume MockERC20 has basic ERC20 functions
        token = await Token.deploy("TestToken", "TT", 18, ethers.utils.parseEther("1000000"));
        await token.deployed();

        // Deploy the Stream contract
        Stream = await ethers.getContractFactory("Stream");
        stream = await Stream.deploy(feeAddress.address);
        await stream.deployed();
    });

    it("Should compute hash correctly", async function () {
        const hash = await stream.computeHash(streamer.address, token.address, recipient.address);
        expect(hash).to.be.properHex(32);
    });

    it("Should allow a stream setup", async function () {
        const amount = ethers.utils.parseEther("1000");
        await stream.connect(streamer).allowStream(token.address, recipient.address, amount, 3600, false);

        const hash = await stream.computeHash(streamer.address, token.address, recipient.address);
        const details = await stream.streamDetails(hash);

        expect(details.outstanding).to.equal(amount);
    });

    it("Should stream tokens correctly with fees", async function () {
        const amount = ethers.utils.parseEther("1000");
        await token.transfer(streamer.address, amount);
        await token.connect(streamer).approve(stream.address, amount);

        await stream.connect(streamer).allowStream(token.address, recipient.address, amount, 3600, true);

        // Time simulation and streaming
        await ethers.provider.send("evm_increaseTime", [1800]); // half of the time window
        await stream.connect(recipient).stream(token.address, streamer.address, recipient.address);

        const recipientBalance = await token.balanceOf(recipient.address);
        const feeBalance = await token.balanceOf(feeAddress.address);

        expect(recipientBalance).to.be.gt(0);
        expect(feeBalance).to.be.gt(0);
    });

    it("Should handle batch allow stream correctly", async function () {
        const amounts = [1000, 2000].map(ethers.utils.parseEther);
        const windows = [3600, 7200];
        const tokens = [token.address, token.address];
        const recipients = [recipient.address, recipient.address];
        const onces = [false, true];

        await stream.connect(streamer).batchAllowStream(tokens, recipients, amounts, windows, onces);
        
        for (let i = 0; i < tokens.length; i++) {
            const hash = await stream.computeHash(streamer.address, tokens[i], recipients[i]);
            const details = await stream.streamDetails(hash);
            expect(details.outstanding).to.equal(amounts[i]);
        }
    });

    it("Should handle batch streaming", async function () {
        const amount = ethers.utils.parseEther("1000");
        await token.transfer(streamer.address, amount.mul(2));
        await token.connect(streamer).approve(stream.address, amount.mul(2));

        await stream.connect(streamer).allowStream(token.address, recipient.address, amount, 3600, true);
        await stream.connect(streamer).allowStream(token.address, recipient.address, amount, 7200, true);

        await ethers.provider.send("evm_increaseTime", [3600]);
        await stream.connect(recipient).batchStream([token.address, token.address], [streamer.address, streamer.address], [recipient.address, recipient.address]);

        const balance = await token.balanceOf(recipient.address);
        expect(balance).to.be.gt(0);
    });

    it("Should cancel a stream", async function () {
        const amount = ethers.utils.parseEther("1000");
        await stream.connect(streamer).allowStream(token.address, recipient.address, amount, 3600, false);

        const hash = await stream.computeHash(streamer.address, token.address, recipient.address);
        await stream.connect(streamer).cancelStreams([token.address], [streamer.address], [recipient.address]);

        const details = await stream.streamDetails(hash);
        expect(details.allowable).to.equal(0);
    });

    it("Should calculate available amount correctly", async function () {
        const amount = ethers.utils.parseEther("1000");
        await stream.connect(streamer).allowStream(token.address, recipient.address, amount, 3600, false);

        await ethers.provider.send("evm_increaseTime", [1800]);
        const available = await stream.getAvailable(token.address, streamer.address, recipient.address);

        expect(available).to.be.gt(0);
    });

    it("Should validate streamable status with balances and allowances", async function () {
        const amount = ethers.utils.parseEther("1000");
        await token.transfer(streamer.address, amount);
        await token.connect(streamer).approve(stream.address, amount);

        await stream.connect(streamer).allowStream(token.address, recipient.address, amount, 3600, false);

        const hash = await stream.computeHash(streamer.address, token.address, recipient.address);
        const [canStream] = await stream.getStreamable([hash]);

        expect(canStream[0]).to.be.true;
    });

    it("Should allow fee setting within limits", async function () {
        const newFee = 20;
        await stream.connect(feeAddress).setFee(newFee, feeAddress.address);

        const updatedFee = await stream.fee();
        expect(updatedFee).to.equal(newFee);
    });
});
