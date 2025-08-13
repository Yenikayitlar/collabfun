// test/TokenLaunch.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("TokenLaunch", () => {
  let TokenLaunch, tokenLaunch, partyA, partyB, safeWallet, pancakeRouterMock, lpLockerMock;
  const depositAmount = ethers.utils.parseEther("0.24");
  const liquidityBNB = ethers.utils.parseEther("0.2");
  const liquidityTokens = ethers.utils.parseEther("100000000");
  const totalSupply = ethers.utils.parseEther("1000000000");

  beforeEach(async () => {
    [partyA, partyB, safeWallet] = await ethers.getSigners();
    // Mock PancakeRouter and LP Locker
    const PancakeRouterMock = await ethers.getContractFactory("PancakeRouterMock"); // Create a mock contract with addLiquidityETH returning values
    pancakeRouterMock = await PancakeRouterMock.deploy();
    lpLockerMock = await ethers.getSigner(3); // Mock address

    TokenLaunch = await ethers.getContractFactory("TokenLaunch");
    tokenLaunch = await TokenLaunch.deploy(
      partyA.address,
      partyB.address,
      safeWallet.address,
      pancakeRouterMock.address,
      lpLockerMock.address,
      depositAmount,
      liquidityBNB,
      liquidityTokens,
      totalSupply
    );
  });

  it("Should allow both parties to deposit and transition state", async () => {
    await tokenLaunch.connect(partyA).deposit({ value: depositAmount });
    expect(await tokenLaunch.partyADeposited()).to.be.true;
    await tokenLaunch.connect(partyB).deposit({ value: depositAmount });
    expect(await tokenLaunch.getLaunchState()).to.equal(1); // Deposited
  });

  it("Should create token and emit event", async () => {
    await tokenLaunch.connect(partyA).deposit({ value: depositAmount });
    await tokenLaunch.connect(partyB).deposit({ value: depositAmount });
    await expect(tokenLaunch.connect(partyA).createToken("GrokDog Coin", "GROKDOG", "https://logo.uri"))
      .to.emit(tokenLaunch, "TokenCreated");
    expect(await tokenLaunch.tokenAddress()).to.not.equal(ethers.constants.AddressZero);
    expect(await tokenLaunch.getLaunchState()).to.equal(2); // TokenCreated
  });

  it("Should add liquidity and renounce ownership", async () => {
    await tokenLaunch.connect(partyA).deposit({ value: depositAmount });
    await tokenLaunch.connect(partyB).deposit({ value: depositAmount });
    await tokenLaunch.connect(partyA).createToken("GrokDog Coin", "GROKDOG", "https://logo.uri");
    await expect(tokenLaunch.connect(partyA).addLiquidity())
      .to.emit(tokenLaunch, "LiquidityAdded");
    const token = await ethers.getContractAt("Memecoin", await tokenLaunch.tokenAddress());
    expect(await token.owner()).to.equal(ethers.constants.AddressZero); // Renounced
    expect(await tokenLaunch.getLaunchState()).to.equal(3); // LiquidityAdded
  });

  it("Should lock LP tokens if locker set", async () => {
    // Setup as above, then
    await tokenLaunch.connect(partyA).addLiquidity();
    const lpTokenMock = await ethers.getContractAt("IERC20", "0xMockLP"); // Assume mock
    await expect(tokenLaunch.connect(partyA).lockLP(lpTokenMock.address, 365 * 24 * 3600))
      .to.emit(tokenLaunch, "LPLocked");
    expect(await tokenLaunch.getLaunchState()).to.equal(4); // LPLocked
  });

  it("Should refund if one party doesn't deposit after delay", async () => {
    await tokenLaunch.connect(partyA).deposit({ value: depositAmount });
    await ethers.provider.send("evm_increaseTime", [86400 + 1]); // 1 day +1 sec
    await expect(tokenLaunch.connect(partyA).refund())
      .to.emit(tokenLaunch, "Refunded")
      .withArgs(partyA.address, depositAmount);
  });

  it("Should revert on double deposit", async () => {
    await tokenLaunch.connect(partyA).deposit({ value: depositAmount });
    await expect(tokenLaunch.connect(partyA).deposit({ value: depositAmount })).to.be.revertedWith("Already deposited");
  });

  it("Should handle emergency withdraw", async () => {
    // Simulate post-launch with balances
    await expect(tokenLaunch.connect(partyA).emergencyWithdraw())
      .to.emit(tokenLaunch, "EmergencyWithdrawn");
  });

  it("Should revert on invalid state transitions", async () => {
    await expect(tokenLaunch.connect(partyA).createToken("Name", "Sym", "URI")).to.be.revertedWith("Invalid state");
  });
});
