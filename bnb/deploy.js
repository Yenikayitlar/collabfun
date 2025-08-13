// scripts/deploy.js
const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying from:", deployer.address);

  // Deploy Gnosis Safe (2/2) at safe.global first with partyA and partyB as owners, threshold 2/2
  const partyA = "0xYourPartyAAddress";
  const partyB = "0xYourPartyBAddress";
  const safeWallet = "0xYourGnosisSafeAddress"; // Pre-deployed 2/2 Safe
  const pancakeRouter = "0x10ED43C718714eb63d5aA57B78B54704E256024E"; // BNB Chain mainnet V2
  const depositAmount = hre.ethers.utils.parseEther("0.24");
  const liquidityBNB = hre.ethers.utils.parseEther("0.2");
  const liquidityTokens = hre.ethers.utils.parseEther("100000000");
  const totalSupply = hre.ethers.utils.parseEther("1000000000");
  const slippageBps = 100; // 1%

  const TokenLaunch = await hre.ethers.getContractFactory("TokenLaunch");
  const tokenLaunch = await TokenLaunch.deploy(
    partyA,
    partyB,
    safeWallet,
    pancakeRouter,
    depositAmount,
    liquidityBNB,
    liquidityTokens,
    totalSupply,
    slippageBps
  );

  await tokenLaunch.deployed();
  console.log("TokenLaunch deployed to:", tokenLaunch.address);

  // Verify on BscScan
  await hre.run("verify:verify", {
    address: tokenLaunch.address,
    constructorArguments: [partyA, partyB, safeWallet, pancakeRouter, depositAmount, liquidityBNB, liquidityTokens, totalSupply, slippageBps],
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
