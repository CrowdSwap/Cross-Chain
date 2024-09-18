import * as dotenv from "dotenv";

import "@typechain/hardhat";
import "@nomiclabs/hardhat-ethers";
import "@nomiclabs/hardhat-waffle";
import "@nomiclabs/hardhat-etherscan";
import "hardhat-gas-reporter";
import "hardhat-deploy";
import "@openzeppelin/hardhat-upgrades";

dotenv.config();

const FEE_TO_ADDRESS = process.env.FEE_TO_ADDRESS;

const config = {
  solidity: {
    compilers: [
      {
        version: "0.8.10",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1000,
          },
        },
      },
    ],
  },
  namedAccounts: {
    deployer: 0,
  },
  networks: {
    hardhat: { allowUnlimitedContractSize: true },
  },
  mocha: {
    timeout: 500000,
  },
  typechain: {
    outDir: "artifacts/types",
  },
  etherscan: {},
  gasReporter: {
    enabled: true,
    currency: "USD",
  },
};
export default config;
