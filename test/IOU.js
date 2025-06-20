const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("IOU.sol Tests", function() {
    let SpotIOULoan, IOUMint, ERC20Mock;
    let spotImplementation, iouMint, mockToken;
    let owner, borrower, lender1, lender2, feeRecipient;

    const LOAN_GOAL = ethers.parseUnits("1000", 6); // 1000 USDC
    const ANNUAL_RATE = 1000; // 10% 
    const PLATFORM_FEE = 200; // 2%
    const YEAR_IN_SECONDS = 365 * 24 * 60 * 60;

    beforeEach(async function() {
        [owner, borrower, lender1, lender2, feeRecipient] = await ethers.getSigners();

        // Deploy mock USDC (6 decimals)
        ERC20Mock = await ethers.getContractFactory("ERC20Mock");
        mockToken = await ERC20Mock.deploy("Mock USDC", "USDC", 6);
        await mockToken.waitForDeployment();

        // Deploy SpotIOULoan implementation
        SpotIOULoan = await ethers.getContractFactory("SpotIOULoan");
        spotImplementation = await SpotIOULoan.deploy();
        await spotImplementation.waitForDeployment();

        // Deploy IOUMint factory
        IOUMint = await ethers.getContractFactory("contracts/IOU.sol:IOUMint");
        iouMint = await IOUMint.deploy(await spotImplementation.getAddress());
        await iouMint.waitForDeployment();

        // Mint tokens to lenders
        await mockToken.mint(lender1.address, ethers.parseUnits("10000", 6));
        await mockToken.mint(lender2.address, ethers.parseUnits("10000", 6));
        await mockToken.mint(borrower.address, ethers.parseUnits("2000", 6)); // For repayments
    });

    describe("Deployment and Setup", function() {
        it("Should deploy IOUMint with correct implementation", async function() {
            expect(await iouMint.loanImplementation()).to.equal(await spotImplementation.getAddress());
        });

        it("Should deploy new loan contract with flexible=false", async function() {
            const tx = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Test Loan",
                "TL",
                false // flexible = false
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });

            expect(event).to.not.be.undefined;
            const parsedEvent = iouMint.interface.parseLog(event);
            const loanAddress = parsedEvent.args[0];

            const loan = await ethers.getContractAt("SpotIOULoan", loanAddress);
            expect(await loan.borrower()).to.equal(borrower.address);
            expect(await loan.loanGoal()).to.equal(LOAN_GOAL);
            expect(await loan.flexible()).to.equal(false);
        });

        it("Should deploy new loan contract with flexible=true", async function() {
            const tx = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Test Loan V2",
                "TL2",
                true // flexible = true
            );

            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });

            const parsedEvent = iouMint.interface.parseLog(event);
            const loanAddress = parsedEvent.args[0];

            const loan = await ethers.getContractAt("SpotIOULoan", loanAddress);
            expect(await loan.flexible()).to.equal(true);
        });

        it("Should reject deployment from non-borrower", async function() {
            await expect(
                iouMint.connect(lender1).deployLoan(
                    await mockToken.getAddress(),
                    borrower.address,
                    LOAN_GOAL,
                    ANNUAL_RATE,
                    PLATFORM_FEE,
                    feeRecipient.address,
                    "Test Loan",
                    "TL",
                    false
                )
            ).to.be.revertedWith("Only borrower can deploy");
        });
    });

    describe("Setup Validation", function() {
        let loanAddress;

        beforeEach(async function() {
            const tx = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Test Loan",
                "TL",
                false
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });
            loanAddress = iouMint.interface.parseLog(event).args[0];
        });

        it("Should prevent double initialization", async function() {
            const loan = await ethers.getContractAt("SpotIOULoan", loanAddress);
            
            await expect(
                loan.setup(
                    await mockToken.getAddress(),
                    borrower.address,
                    LOAN_GOAL,
                    ANNUAL_RATE,
                    PLATFORM_FEE,
                    feeRecipient.address,
                    "Test",
                    "T",
                    await iouMint.getAddress(),
                    false
                )
            ).to.be.revertedWith("Already setup");
        });

        it("Should validate setup parameters", async function() {
            const newImplementation = await SpotIOULoan.deploy();
            await newImplementation.waitForDeployment();

            // Test zero loanToken
            await expect(
                newImplementation.setup(
                    ethers.ZeroAddress,
                    borrower.address,
                    LOAN_GOAL,
                    ANNUAL_RATE,
                    PLATFORM_FEE,
                    feeRecipient.address,
                    "Test",
                    "T",
                    await iouMint.getAddress(),
                    false
                )
            ).to.be.revertedWith("Zero loanToken");

            // Test zero borrower
            await expect(
                newImplementation.setup(
                    await mockToken.getAddress(),
                    ethers.ZeroAddress,
                    LOAN_GOAL,
                    ANNUAL_RATE,
                    PLATFORM_FEE,
                    feeRecipient.address,
                    "Test",
                    "T",
                    await iouMint.getAddress(),
                    false
                )
            ).to.be.revertedWith("Zero borrower");

            // Test zero loan goal
            await expect(
                newImplementation.setup(
                    await mockToken.getAddress(),
                    borrower.address,
                    0,
                    ANNUAL_RATE,
                    PLATFORM_FEE,
                    feeRecipient.address,
                    "Test",
                    "T",
                    await iouMint.getAddress(),
                    false
                )
            ).to.be.revertedWith("Loan goal must be > 0");
        });
    });

    describe("Loan Funding", function() {
        let loan;

        beforeEach(async function() {
            const tx = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Test Loan",
                "TL",
                false
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });
            const loanAddress = iouMint.interface.parseLog(event).args[0];
            loan = await ethers.getContractAt("SpotIOULoan", loanAddress);
        });

        it("Should allow lender to fund loan and receive IOUs", async function() {
            const fundAmount = ethers.parseUnits("500", 6); // 500 USDC
            
            await mockToken.connect(lender1).approve(await loan.getAddress(), fundAmount);
            await loan.connect(lender1).fundLoan(fundAmount);

            expect(await loan.totalFunded()).to.equal(fundAmount);
            // IOUs should be scaled to 18 decimals: 500 * 10^(18-6) = 500 * 10^12
            expect(await loan.balanceOf(lender1.address)).to.equal(fundAmount * BigInt(10**12));
        });

        it("Should reject zero funding", async function() {
            await expect(
                loan.connect(lender1).fundLoan(0)
            ).to.be.revertedWith("Zero funding");
        });

        it("Should cap funding at loan goal", async function() {
            const excessAmount = ethers.parseUnits("1500", 6); // More than loan goal
            
            await mockToken.connect(lender1).approve(await loan.getAddress(), excessAmount);
            await loan.connect(lender1).fundLoan(excessAmount);

            // Should only fund up to loan goal
            expect(await loan.totalFunded()).to.equal(LOAN_GOAL);
            expect(await loan.balanceOf(lender1.address)).to.equal(LOAN_GOAL * BigInt(10**12));
        });

        it("Should reject funding fully funded loan", async function() {
            // First, fully fund the loan
            await mockToken.connect(lender1).approve(await loan.getAddress(), LOAN_GOAL);
            await loan.connect(lender1).fundLoan(LOAN_GOAL);

            // Try to fund again
            const additionalFunding = ethers.parseUnits("100", 6);
            await mockToken.connect(lender2).approve(await loan.getAddress(), additionalFunding);
            
            await expect(
                loan.connect(lender2).fundLoan(additionalFunding)
            ).to.be.revertedWith("Loan fully funded");
        });

        it("Should handle multiple lenders", async function() {
            const amount1 = ethers.parseUnits("300", 6);
            const amount2 = ethers.parseUnits("700", 6);

            await mockToken.connect(lender1).approve(await loan.getAddress(), amount1);
            await loan.connect(lender1).fundLoan(amount1);

            await mockToken.connect(lender2).approve(await loan.getAddress(), amount2);
            await loan.connect(lender2).fundLoan(amount2);

            expect(await loan.totalFunded()).to.equal(LOAN_GOAL);
            expect(await loan.balanceOf(lender1.address)).to.equal(amount1 * BigInt(10**12));
            expect(await loan.balanceOf(lender2.address)).to.equal(amount2 * BigInt(10**12));
        });

        it("Should transfer tokens correctly", async function() {
            const fundAmount = ethers.parseUnits("500", 6);
            const lenderBalanceBefore = await mockToken.balanceOf(lender1.address);
            const loanBalanceBefore = await mockToken.balanceOf(await loan.getAddress());

            await mockToken.connect(lender1).approve(await loan.getAddress(), fundAmount);
            await loan.connect(lender1).fundLoan(fundAmount);

            expect(await mockToken.balanceOf(lender1.address)).to.equal(lenderBalanceBefore - fundAmount);
            expect(await mockToken.balanceOf(await loan.getAddress())).to.equal(loanBalanceBefore + fundAmount);
        });
    });

    describe("Drawdown", function() {
        let loan;

        beforeEach(async function() {
            const tx = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Test Loan",
                "TL",
                false
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });
            const loanAddress = iouMint.interface.parseLog(event).args[0];
            loan = await ethers.getContractAt("SpotIOULoan", loanAddress);

            // Fund the loan partially
            const fundAmount = ethers.parseUnits("800", 6);
            await mockToken.connect(lender1).approve(await loan.getAddress(), fundAmount);
            await loan.connect(lender1).fundLoan(fundAmount);
        });

        it("Should allow borrower to draw down funds", async function() {
            const drawAmount = ethers.parseUnits("300", 6);
            const borrowerBalanceBefore = await mockToken.balanceOf(borrower.address);

            await loan.connect(borrower).drawDown(drawAmount);

            expect(await loan.totalDrawnDown()).to.equal(drawAmount);
            expect(await mockToken.balanceOf(borrower.address)).to.equal(borrowerBalanceBefore + drawAmount);
        });

        it("Should reject drawdown from non-borrower", async function() {
            const drawAmount = ethers.parseUnits("300", 6);
            
            await expect(
                loan.connect(lender1).drawDown(drawAmount)
            ).to.be.revertedWith("Not borrower");
        });

        it("Should reject drawdown when no funds available", async function() {
            // First draw down all available funds
            const totalFunded = await loan.totalFunded();
            await loan.connect(borrower).drawDown(totalFunded);

            // Try to draw down more
            await expect(
                loan.connect(borrower).drawDown(ethers.parseUnits("100", 6))
            ).to.be.revertedWith("No available funds");
        });

        it("Should cap drawdown at available amount", async function() {
            const totalFunded = await loan.totalFunded();
            const excessiveAmount = totalFunded + ethers.parseUnits("500", 6);

            await loan.connect(borrower).drawDown(excessiveAmount);

            expect(await loan.totalDrawnDown()).to.equal(totalFunded);
        });

        it("Should draw all funds when amount is 0", async function() {
            const totalFunded = await loan.totalFunded();
            
            await loan.connect(borrower).drawDown(0);

            expect(await loan.totalDrawnDown()).to.equal(totalFunded);
        });
    });

    describe("Repayment - Flexible False", function() {
        let loan;

        beforeEach(async function() {
            const tx = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Test Loan",
                "TL",
                false // flexible = false
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });
            const loanAddress = iouMint.interface.parseLog(event).args[0];
            loan = await ethers.getContractAt("SpotIOULoan", loanAddress);

            // Fund and draw down the loan
            await mockToken.connect(lender1).approve(await loan.getAddress(), LOAN_GOAL);
            await loan.connect(lender1).fundLoan(LOAN_GOAL);
            await loan.connect(borrower).drawDown(LOAN_GOAL);
        });

        it("Should handle principal repayment correctly (flexible=false)", async function() {
            const repayAmount = ethers.parseUnits("300", 6);
            const expectedFee = repayAmount * BigInt(PLATFORM_FEE) / BigInt(10000);
            const expectedNetPayment = repayAmount - expectedFee;
            
            await mockToken.connect(borrower).approve(await loan.getAddress(), repayAmount);
            await loan.connect(borrower).repayLoan(repayAmount);

            // In flexible=false mode, repayments are tracked in `repayments`
            const actualRepayments = await loan.repayments();
            expect(actualRepayments).to.be.closeTo(expectedNetPayment, ethers.parseUnits("0.1", 6)); // Allow small tolerance
        });

        it("Should deduct platform fee", async function() {
            const repayAmount = ethers.parseUnits("100", 6);
            const expectedFee = repayAmount * BigInt(PLATFORM_FEE) / BigInt(10000); // 2%
            
            const feeRecipientBalanceBefore = await mockToken.balanceOf(feeRecipient.address);
            
            await mockToken.connect(borrower).approve(await loan.getAddress(), repayAmount);
            await loan.connect(borrower).repayLoan(repayAmount);

            expect(await mockToken.balanceOf(feeRecipient.address)).to.equal(feeRecipientBalanceBefore + expectedFee);
        });

        it("Should refund overpayment", async function() {
            // Fast forward time to accrue some interest
            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]); // 30 days
            await ethers.provider.send("evm_mine");

            const totalOwed = await loan.totalOwed();
            const overpayAmount = totalOwed + ethers.parseUnits("100", 6);
            
            const borrowerBalanceBefore = await mockToken.balanceOf(borrower.address);
            
            await mockToken.connect(borrower).approve(await loan.getAddress(), overpayAmount);
            await loan.connect(borrower).repayLoan(overpayAmount);

            // Should receive refund
            const borrowerBalanceAfter = await mockToken.balanceOf(borrower.address);
            expect(borrowerBalanceAfter).to.be.gt(borrowerBalanceBefore - overpayAmount);
        });
    });

    describe("Repayment - Flexible True", function() {
        let loan;

        beforeEach(async function() {
            const tx = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Test Loan V2",
                "TL2",
                true // flexible = true
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });
            const loanAddress = iouMint.interface.parseLog(event).args[0];
            loan = await ethers.getContractAt("SpotIOULoan", loanAddress);

            // Fund and draw down the loan
            await mockToken.connect(lender1).approve(await loan.getAddress(), LOAN_GOAL);
            await loan.connect(lender1).fundLoan(LOAN_GOAL);
            await loan.connect(borrower).drawDown(LOAN_GOAL);
        });

        it("Should handle principal repayment correctly (flexible=true)", async function() {
            const repayAmount = ethers.parseUnits("300", 6);
            const expectedFee = repayAmount * BigInt(PLATFORM_FEE) / BigInt(10000);
            const netAmount = repayAmount - expectedFee;
            
            const totalDrawnBefore = await loan.totalDrawnDown();
            
            await mockToken.connect(borrower).approve(await loan.getAddress(), repayAmount);
            await loan.connect(borrower).repayLoan(repayAmount);

            // In flexible=true mode, totalDrawnDown is reduced directly
            const actualDrawnDown = await loan.totalDrawnDown();
            const actualRepayments = await loan.repayments();
            
            expect(actualDrawnDown).to.be.closeTo(totalDrawnBefore - netAmount, ethers.parseUnits("0.1", 6));
            expect(actualRepayments).to.be.closeTo(netAmount, ethers.parseUnits("0.1", 6));
        });
    });

    describe("Interest Accrual and Claiming", function() {
        let loan;

        beforeEach(async function() {
            const tx = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Test Loan",
                "TL",
                false
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });
            const loanAddress = iouMint.interface.parseLog(event).args[0];
            loan = await ethers.getContractAt("SpotIOULoan", loanAddress);

            // Fund and draw down the loan
            await mockToken.connect(lender1).approve(await loan.getAddress(), LOAN_GOAL);
            await loan.connect(lender1).fundLoan(LOAN_GOAL);
            await loan.connect(borrower).drawDown(LOAN_GOAL);
        });

        it("Should accrue interest over time", async function() {
            // Get initial interest right after setup (may have small amount due to block time)
            const initialInterest = await loan.viewAccruedInterest();
            
            // Fast forward 30 days
            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            const accruedInterest = await loan.viewAccruedInterest();
            expect(accruedInterest).to.be.gt(initialInterest);

            // Calculate expected interest: principal * rate * time / (365 days * 10000)
            const expectedInterest = LOAN_GOAL * BigInt(ANNUAL_RATE) * BigInt(30 * 24 * 60 * 60) / (BigInt(YEAR_IN_SECONDS) * BigInt(10000));
            expect(accruedInterest).to.be.closeTo(expectedInterest, ethers.parseUnits("1", 6)); // Within 1 USDC tolerance
        });

        it("Should track total owed correctly", async function() {
            // Fast forward time to accrue interest
            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]); // 30 days
            await ethers.provider.send("evm_mine");

            const totalOwed = await loan.totalOwed();
            const accruedInterest = await loan.viewAccruedInterest();
            const principalOutstanding = await loan.totalDrawnDown(); // For flexible=false, outstanding = totalDrawnDown - repayments

            expect(totalOwed).to.equal(principalOutstanding + accruedInterest);
        });

        it("Should handle interest repayment", async function() {
            // Accrue some interest
            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            const accruedInterest = await loan.viewAccruedInterest();
            const interestPayment = accruedInterest / BigInt(2); // Pay half the interest

            const adjustedPayment = interestPayment + (interestPayment * BigInt(PLATFORM_FEE) / BigInt(10000)); // Add platform fee
            
            await mockToken.connect(borrower).approve(await loan.getAddress(), adjustedPayment);
            await loan.connect(borrower).repayLoan(adjustedPayment);

            // Check that interest was reduced
            const remainingInterest = await loan.accruedInterest();
            expect(remainingInterest).to.be.lt(accruedInterest);
        });

        it("Should distribute interest to lenders proportionally", async function() {
            // Add second lender with partial funding
            const secondLoanGoal = ethers.parseUnits("500", 6);
            
            const tx2 = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                secondLoanGoal,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Test Loan 2",
                "TL2",
                false
            );
            const receipt2 = await tx2.wait();
            const event2 = receipt2.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });
            const loan2Address = iouMint.interface.parseLog(event2).args[0];
            const loan2 = await ethers.getContractAt("SpotIOULoan", loan2Address);

            // Fund with two lenders: 60% lender1, 40% lender2
            const amount1 = ethers.parseUnits("300", 6);
            const amount2 = ethers.parseUnits("200", 6);

            await mockToken.connect(lender1).approve(await loan2.getAddress(), amount1);
            await loan2.connect(lender1).fundLoan(amount1);

            await mockToken.connect(lender2).approve(await loan2.getAddress(), amount2);
            await loan2.connect(lender2).fundLoan(amount2);

            await loan2.connect(borrower).drawDown(secondLoanGoal);

            // Accrue interest
            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            // Repay some interest
            const totalInterest = ethers.parseUnits("10", 6); // Arbitrary amount
            await mockToken.connect(borrower).approve(await loan2.getAddress(), totalInterest);
            await loan2.connect(borrower).repayLoan(totalInterest);

            // Check interest claimable
            const claimable1 = await loan2.interestClaimable(lender1.address);
            const claimable2 = await loan2.interestClaimable(lender2.address);

            // Should be proportional to their IOU holdings (60/40 split)
            const ratio = Number(claimable1) / Number(claimable2);
            expect(ratio).to.be.closeTo(1.5, 0.1); // 60/40 = 1.5 with some tolerance
        });

        it("Should allow claiming interest", async function() {
            // Accrue and repay some interest
            await ethers.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            const interestPayment = ethers.parseUnits("5", 6);
            await mockToken.connect(borrower).approve(await loan.getAddress(), interestPayment);
            await loan.connect(borrower).repayLoan(interestPayment);

            const claimableBefore = await loan.interestClaimable(lender1.address);
            expect(claimableBefore).to.be.gt(0);

            const lenderBalanceBefore = await mockToken.balanceOf(lender1.address);
            
            await loan.connect(lender1).claimInterest(lender1.address);

            const lenderBalanceAfter = await mockToken.balanceOf(lender1.address);
            expect(lenderBalanceAfter).to.equal(lenderBalanceBefore + claimableBefore);

            const claimableAfter = await loan.interestClaimable(lender1.address);
            expect(claimableAfter).to.equal(0);
        });
    });

    describe("IOU Redemption", function() {
        let flexibleFalseLoan, flexibleTrueLoan;

        beforeEach(async function() {
            // Deploy flexible=false loan
            const tx1 = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Test Loan False",
                "TLF",
                false
            );
            const receipt1 = await tx1.wait();
            const event1 = receipt1.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });
            const loan1Address = iouMint.interface.parseLog(event1).args[0];
            flexibleFalseLoan = await ethers.getContractAt("SpotIOULoan", loan1Address);

            // Deploy flexible=true loan  
            const tx2 = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Test Loan True",
                "TLT",
                true
            );
            const receipt2 = await tx2.wait();
            const event2 = receipt2.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });
            const loan2Address = iouMint.interface.parseLog(event2).args[0];
            flexibleTrueLoan = await ethers.getContractAt("SpotIOULoan", loan2Address);
        });

        it("Should allow unfunding undrawn loans", async function() {
            // Fund but don't draw down
            const fundAmount = ethers.parseUnits("500", 6);
            await mockToken.connect(lender1).approve(await flexibleFalseLoan.getAddress(), fundAmount);
            await flexibleFalseLoan.connect(lender1).fundLoan(fundAmount);

            const lenderBalanceBefore = await mockToken.balanceOf(lender1.address);
            const unfundAmount = ethers.parseUnits("200", 6);

            await flexibleFalseLoan.connect(lender1).unfundLoan(unfundAmount);

            expect(await flexibleFalseLoan.totalFunded()).to.equal(fundAmount - unfundAmount);
            expect(await mockToken.balanceOf(lender1.address)).to.equal(lenderBalanceBefore + unfundAmount);
        });

        it("Should reject unfunding more than available", async function() {
            const fundAmount = ethers.parseUnits("500", 6);
            await mockToken.connect(lender1).approve(await flexibleFalseLoan.getAddress(), fundAmount);
            await flexibleFalseLoan.connect(lender1).fundLoan(fundAmount);

            // Draw down part of it
            await flexibleFalseLoan.connect(borrower).drawDown(ethers.parseUnits("300", 6));

            // Try to unfund more than undrawn amount
            await expect(
                flexibleFalseLoan.connect(lender1).unfundLoan(ethers.parseUnits("300", 6))
            ).to.be.revertedWith("Cannot unfund more than undrawn");
        });

        it("Should handle redemption for flexible=false (Version2)", async function() {
            // Fund, draw, and partially repay
            await mockToken.connect(lender1).approve(await flexibleFalseLoan.getAddress(), LOAN_GOAL);
            await flexibleFalseLoan.connect(lender1).fundLoan(LOAN_GOAL);
            await flexibleFalseLoan.connect(borrower).drawDown(LOAN_GOAL);

            const repayAmount = ethers.parseUnits("300", 6);
            await mockToken.connect(borrower).approve(await flexibleFalseLoan.getAddress(), repayAmount);
            await flexibleFalseLoan.connect(borrower).repayLoan(repayAmount);

            // Now redeem some IOUs
            const iouAmount = ethers.parseUnits("100", 18); // 100 IOUs (18 decimals)
            const lenderBalanceBefore = await mockToken.balanceOf(lender1.address);

            await flexibleFalseLoan.connect(lender1).redeemIOUs(iouAmount);

            const lenderBalanceAfter = await mockToken.balanceOf(lender1.address);
            expect(lenderBalanceAfter).to.be.gt(lenderBalanceBefore);
        });

        it("Should handle redemption for flexible=true (calls unfundLoan)", async function() {
            // Fund but don't draw down all
            const fundAmount = ethers.parseUnits("800", 6);
            await mockToken.connect(lender1).approve(await flexibleTrueLoan.getAddress(), fundAmount);
            await flexibleTrueLoan.connect(lender1).fundLoan(fundAmount);

            const drawAmount = ethers.parseUnits("600", 6);
            await flexibleTrueLoan.connect(borrower).drawDown(drawAmount);

            // Redeem some IOUs (should call unfundLoan internally)
            const iouAmount = ethers.parseUnits("100", 18); // 100 IOUs
            const lenderBalanceBefore = await mockToken.balanceOf(lender1.address);

            await flexibleTrueLoan.connect(lender1).redeemIOUs(iouAmount);

            const lenderBalanceAfter = await mockToken.balanceOf(lender1.address);
            expect(lenderBalanceAfter).to.be.gt(lenderBalanceBefore);
        });

        it("Should handle drop function", async function() {
            // Fund and draw down
            await mockToken.connect(lender1).approve(await flexibleFalseLoan.getAddress(), LOAN_GOAL);
            await flexibleFalseLoan.connect(lender1).fundLoan(LOAN_GOAL);
            await flexibleFalseLoan.connect(borrower).drawDown(LOAN_GOAL);

            const dropAmount = ethers.parseUnits("100", 18); // 100 IOUs
            const totalFundedBefore = await flexibleFalseLoan.totalFunded();
            const totalDrawnBefore = await flexibleFalseLoan.totalDrawnDown();

            await flexibleFalseLoan.connect(lender1).drop(dropAmount);

            // Should reduce both totalFunded and totalDrawnDown by the scaled amount
            const scaledAmount = dropAmount / BigInt(10**12); // Convert from 18 to 6 decimals
            expect(await flexibleFalseLoan.totalFunded()).to.equal(totalFundedBefore - scaledAmount);
            expect(await flexibleFalseLoan.totalDrawnDown()).to.equal(totalDrawnBefore - scaledAmount);
        });
    });

    describe("Edge Cases and Error Conditions", function() {
        let loan;

        beforeEach(async function() {
            const tx = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Test Loan",
                "TL",
                false
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });
            const loanAddress = iouMint.interface.parseLog(event).args[0];
            loan = await ethers.getContractAt("SpotIOULoan", loanAddress);
        });

        it("Should reject zero repayment", async function() {
            await expect(
                loan.connect(borrower).repayLoan(0)
            ).to.be.revertedWith("Repay must be > 0");
        });

        it("Should reject zero redemption", async function() {
            await expect(
                loan.connect(lender1).redeemIOUs(0)
            ).to.be.revertedWith("Zero redeem");
        });

        it("Should reject redemption with insufficient IOUs", async function() {
            const iouAmount = ethers.parseUnits("100", 18);
            
            await expect(
                loan.connect(lender1).redeemIOUs(iouAmount)
            ).to.be.revertedWith("Insufficient IOUs");
        });

        it("Should handle updateGoal correctly for flexible=false", async function() {
            // Before any funding, should allow reducing goal
            const newGoal = ethers.parseUnits("800", 6);
            await loan.connect(borrower).updateGoal(newGoal);
            expect(await loan.loanGoal()).to.equal(newGoal);

            // After funding, should reject increasing goal
            await mockToken.connect(lender1).approve(await loan.getAddress(), ethers.parseUnits("100", 6));
            await loan.connect(lender1).fundLoan(ethers.parseUnits("100", 6));

            await expect(
                loan.connect(borrower).updateGoal(ethers.parseUnits("900", 6))
            ).to.be.revertedWith("Cannot increase goal after funding");
        });

        it("Should handle updateGoal correctly for flexible=true", async function() {
            // Deploy flexible=true loan
            const tx = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Flexible Loan",
                "FL",
                true
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });
            const flexibleLoanAddress = iouMint.interface.parseLog(event).args[0];
            const flexibleLoan = await ethers.getContractAt("SpotIOULoan", flexibleLoanAddress);

            // Should allow increasing goal even after funding for flexible=true
            await mockToken.connect(lender1).approve(await flexibleLoan.getAddress(), ethers.parseUnits("100", 6));
            await flexibleLoan.connect(lender1).fundLoan(ethers.parseUnits("100", 6));

            const newGoal = ethers.parseUnits("1200", 6);
            await flexibleLoan.connect(borrower).updateGoal(newGoal);
            expect(await flexibleLoan.loanGoal()).to.equal(newGoal);
        });

        it("Should handle zero interest case", async function() {
            // Deploy loan with 0% interest
            const tx = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                0, // 0% interest
                PLATFORM_FEE,
                feeRecipient.address,
                "Zero Interest Loan",
                "ZIL",
                false
            );
            const receipt = await tx.wait();
            const event = receipt.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });
            const zeroInterestLoanAddress = iouMint.interface.parseLog(event).args[0];
            const zeroInterestLoan = await ethers.getContractAt("SpotIOULoan", zeroInterestLoanAddress);

            await mockToken.connect(lender1).approve(await zeroInterestLoan.getAddress(), LOAN_GOAL);
            await zeroInterestLoan.connect(lender1).fundLoan(LOAN_GOAL);
            await zeroInterestLoan.connect(borrower).drawDown(LOAN_GOAL);

            // Fast forward time
            await ethers.provider.send("evm_increaseTime", [365 * 24 * 60 * 60]); // 1 year
            await ethers.provider.send("evm_mine");

            const accruedInterest = await zeroInterestLoan.viewAccruedInterest();
            expect(accruedInterest).to.equal(0);
        });

        it("Should handle division by zero in interest calculation", async function() {
            // This tests when totalSupply is 0 for interest claimable calculation
            const claimable = await loan.interestClaimable(lender1.address);
            expect(claimable).to.equal(0);
        });
    });

    describe("IOUMint Factory Functions", function() {
        let loan1, loan2;

        beforeEach(async function() {
            // Deploy two loans
            const tx1 = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Test Loan 1",
                "TL1",
                false
            );
            const receipt1 = await tx1.wait();
            const event1 = receipt1.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });
            loan1 = iouMint.interface.parseLog(event1).args[0];

            const tx2 = await iouMint.connect(borrower).deployLoan(
                await mockToken.getAddress(),
                borrower.address,
                LOAN_GOAL,
                ANNUAL_RATE,
                PLATFORM_FEE,
                feeRecipient.address,
                "Test Loan 2",
                "TL2",
                true
            );
            const receipt2 = await tx2.wait();
            const event2 = receipt2.logs.find(log => {
                try {
                    return iouMint.interface.parseLog(log).name === 'LoanDeployed';
                } catch {
                    return false;
                }
            });
            loan2 = iouMint.interface.parseLog(event2).args[0];
        });

        it("Should track all loans", async function() {
            const allLoans = await iouMint.getAllLoans();
            expect(allLoans).to.include(loan1);
            expect(allLoans).to.include(loan2);
            expect(allLoans.length).to.be.gte(2);
        });

        it("Should track user IOUs (borrower loans)", async function() {
            const userIOUs = await iouMint.getUserIOUs(borrower.address);
            expect(userIOUs).to.include(loan1);
            expect(userIOUs).to.include(loan2);
        });

        it("Should track user loans (lender loans)", async function() {
            // Fund a loan to become a lender
            const loanContract = await ethers.getContractAt("SpotIOULoan", loan1);
            await mockToken.connect(lender1).approve(loan1, ethers.parseUnits("100", 6));
            await loanContract.connect(lender1).fundLoan(ethers.parseUnits("100", 6));

            const userLoans = await iouMint.getUserLoans(lender1.address);
            expect(userLoans).to.include(loan1);
        });

        it("Should get loans by IDs", async function() {
            const allLoans = await iouMint.getAllLoans();
            const ids = [0, 1]; // First two loans
            
            const selectedLoans = await iouMint.getLoans(ids);
            expect(selectedLoans[0]).to.equal(allLoans[0]);
            expect(selectedLoans[1]).to.equal(allLoans[1]);
        });

        it("Should provide detailed spot info", async function() {
            const loanContract = await ethers.getContractAt("SpotIOULoan", loan1);
            await mockToken.connect(lender1).approve(loan1, ethers.parseUnits("500", 6));
            await loanContract.connect(lender1).fundLoan(ethers.parseUnits("500", 6));

            const spotInfo = await iouMint.getSpotInfo([loan1], lender1.address);
            expect(spotInfo.length).to.equal(1);
            
            const info = spotInfo[0];
            expect(info.loanAddress).to.equal(loan1);
            expect(info.borrower).to.equal(borrower.address);
            expect(info.loanGoal).to.equal(LOAN_GOAL);
            expect(info.totalFunded).to.equal(ethers.parseUnits("500", 6));
            expect(info.myIOUs).to.equal(ethers.parseUnits("500", 6) * BigInt(10**12));
            expect(info.flexible).to.equal(false);
        });
    });
});