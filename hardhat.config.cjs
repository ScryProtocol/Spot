require("@nomicfoundation/hardhat-toolbox");
require("hardhat-gas-reporter");
require("solidity-coverage");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.24",
  gasReporter: {
    enabled: true, // Set to true to enable gas reporting
    currency: 'USD',
    gasPrice: 21
  }

};
