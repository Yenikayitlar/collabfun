// scripts/deploy.js
const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying from:", deployer.address);

  // Replace with actual addresses
  const partyA = "0xYourPartyAAddress";
  const partyB = "0xYourPartyBAddress";
  const safeWallet = "0xYourGnosisSafeAddress"; // Deploy Safe first via safe.global
  const pancakeRouter = "0x10ED43C718714eb63d5aA57B78B54704E256024E"; // Mainnet V2
  const lpLocker = "0xTeamFinanceLockerAddress"; // Or 0x0 if not using
  const depositAmount = hre.ethers.utils.parseEther("0.24");
  const liquidityBNB = hre.ethers.utils.parseEther("0.2");
  const liquidityTokens = hre.ethers.utils.parseEther("100000000");
  const totalSupply = hre.ethers.utils.parseEther("1000000000");

  const TokenLaunch = await hre.ethers.getContractFactory("TokenLaunch");
  const tokenLaunch = await TokenLaunch.deploy(
    partyA,
    partyB,
    safeWallet,
    pancakeRouter,
    lpLocker,
    depositAmount,
    liquidityBNB,
    liquidityTokens,
    totalSupply
  );

  await tokenLaunch.deployed();
  console.log("TokenLaunch deployed to:", tokenLaunch.address);

  // Verify on BscScan
  await hre.run("verify:verify", {
    address: tokenLaunch.address,
    constructorArguments: [partyA, partyB, safeWallet, pancakeRouter, lpLocker, depositAmount, liquidityBNB, liquidityTokens, totalSupply],
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
