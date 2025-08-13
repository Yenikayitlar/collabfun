// test/TokenLaunch.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("TokenLaunch", () => {
  let TokenLaunch, tokenLaunch, partyA, partyB, safeWallet, pancakeRouterMock, lpLockerMock;
  const depositAmount = ethers.utils.parseEther("0.24");
  const liquidityBNB = ethers.utils.parseEther("0.2");
  const liquidityTokens = ethers.utils.parseEther("100000000");
  const totalSupply = ethers.utils.parseEther("1000000000");
  const slippageBps = 100; // 1%
  const depositDeadline = 3600; // 1 hour
  const refundDelay = 86400; // 1 day
  const liquidityDeadline = 86400; // 1 day
  const targetChainId = 56; // BNB Chain

  beforeEach(async () => {
    [partyA, partyB, safeWallet, lpLockerMock] = await ethers.getSigners();

    // Mock PancakeRouter
    const PancakeRouterMock = await ethers.getContractFactory("PancakeRouterMock");
    pancakeRouterMock = await PancakeRouterMock.deploy();

    // Mock Safe with IERC165
    const SafeMock = await ethers.getContractFactory("SafeMock");
    const safeMock = await SafeMock.deploy();

    TokenLaunch = await ethers.getContractFactory("TokenLaunch");
    tokenLaunch = await TokenLaunch.deploy(
      partyA.address,
      partyB.address,
      safeMock.address,
      pancakeRouterMock.address,
      depositAmount,
      liquidityBNB,
      liquidityTokens,
      totalSupply,
      slippageBps,
      depositDeadline,
      refundDelay,
      liquidityDeadline,
      targetChainId
    );
  });

  it("Should deploy with correct parameters and emit ContractDeployed", async () => {
    expect(await tokenLaunch.partyA()).to.equal(partyA.address);
    expect(await tokenLaunch.depositAmount()).to.equal(depositAmount);
    expect(await tokenLaunch.targetChainId()).to.equal(targetChainId);
    expect(await tokenLaunch.getLaunchState()).to.equal(0); // Initialized
    expect(await tokenLaunch.getStateName()).to.equal("Initialized");
    expect(await tokenLaunch.paused()).to.be.false;
    expect(await tokenLaunch.getPancakeRouter()).to.equal(pancakeRouterMock.address);
    await expect(tokenLaunch.deployTransaction).to.emit(tokenLaunch, "ContractDeployed")
      .withArgs(partyA.address, partyB.address, await tokenLaunch.safeWallet(), pancakeRouterMock.address, targetChainId);
  });

  it("Should allow deposits and transition state", async () => {
    await tokenLaunch.connect(partyA).deposit({ value: depositAmount });
    expect(await tokenLaunch.partyADeposited()).to.be.true;
    await tokenLaunch.connect(partyB).deposit({ value: depositAmount });
    expect(await tokenLaunch.getLaunchState()).to.equal(1); // Deposited
    expect(await tokenLaunch.getStateName()).to.equal("Deposited");
    await expect(tokenLaunch.connect(partyA).deposit({ value: depositAmount })).to.be.revertedWith("Party A deposited");
  });

  it("Should create token with valid metadata and emit events", async () => {
    await tokenLaunch.connect(partyA).deposit({ value: depositAmount });
    await tokenLaunch.connect(partyB).deposit({ value: depositAmount });
    const tx = await tokenLaunch.connect(partyA).createToken("GrokDog Coin", "GROKDOG", "https://logo.uri");
    await expect(tx).to.emit(tokenLaunch, "TokenCreated").withArgs(
      await tokenLaunch.tokenAddress(),
      "GrokDog Coin",
      "GROKDOG",
      "https://logo.uri"
    );
    expect(await tokenLaunch.getLaunchState()).to.equal(2); // TokenCreated
    expect(await tokenLaunch.getStateName()).to.equal("TokenCreated");
    const [name, symbol, uri] = await tokenLaunch.getMetadata();
    expect(name).to.equal("GrokDog Coin");
    expect(symbol).to.equal("GROKDOG");
    expect(uri).to.equal("https://logo.uri");
    await expect(tokenLaunch.connect(partyA).createToken("", "GROKDOG", "https://logo.uri")).to.be.revertedWith("Name empty");
  });

  it("Should update metadata", async () => {
    await tokenLaunch.connect(partyA).deposit({ value: depositAmount });
    await tokenLaunch.connect(partyB).deposit({ value: depositAmount });
    await tokenLaunch.connect(partyA).createToken("GrokDog Coin", "GROKDOG", "https://logo.uri");
    await expect(tokenLaunch.connect(safeWallet).setMetadata("New Coin", "NEW", "https://new.logo.uri"))
      .to.emit(tokenLaunch, "MetadataUpdated").withArgs("New Coin", "NEW", "https://new.logo.uri");
    const [name, symbol, uri] = await tokenLaunch.getMetadata();
    expect(name).to.equal("New Coin");
    expect(symbol).to.equal("NEW");
    expect(uri).to.equal("https://new.logo.uri");
    await expect(tokenLaunch.connect(safeWallet).setMetadata("", "NEW", "https://new.logo.uri")).to.be.revertedWith("Name empty");
  });

  it("Should add liquidity and transfer remaining", async () => {
    await tokenLaunch.connect(partyA).deposit({ value: depositAmount });
    await tokenLaunch.connect(partyB).deposit({ value: depositAmount });
    await tokenLaunch.connect(partyA).createToken("GrokDog Coin", "GROKDOG", "https://logo.uri");
    await expect(tokenLaunch.connect(partyA).addLiquidity())
      .to.emit(tokenLaunch, "LiquidityAdded")
      .to.emit(tokenLaunch, "RemainingTransferred");
    const token = await ethers.getContractAt("Memecoin", await tokenLaunch.tokenAddress());
    expect(await token.owner()).to.equal(ethers.constants.AddressZero);
    expect(await tokenLaunch.getLaunchState()).to.equal(3); // LiquidityAdded
    expect(await tokenLaunch.getStateName()).to.equal("LiquidityAdded");
  });

  it("Should lock LP tokens", async () => {
    await tokenLaunch.connect(partyA).deposit({ value: depositAmount });
    await tokenLaunch.connect(partyB).deposit({ value: depositAmount });
    await tokenLaunch.connect(partyA).createToken("GrokDog Coin", "GROKDOG", "https://logo.uri");
    await tokenLaunch.connect(partyA).addLiquidity();
    const lpBalance = await tokenLaunch.getSafeLPBalance(pancakeRouterMock.address);
    const tx = await tokenLaunch.connect(partyA).lockLP(pancakeRouterMock.address, lpLockerMock.address, 365 * 24 * 3600);
    await expect(tx).to.emit(tokenLaunch, "LPLockInitiated").withArgs(pancakeRouterMock.address, lpLockerMock.address, lpBalance, 365 * 24 * 3600);
    await expect(tx).to.emit(tokenLaunch, "LPLocked").withArgs(pancakeRouterMock.address, lpLockerMock.address, lpBalance, 365 * 24 * 3600);
    expect(await tokenLaunch.getLaunchState()).to.equal(4); // LPLocked
    expect(await tokenLaunch.getStateName()).to.equal("LPLocked");
    expect(await tokenLaunch.getSafeLPBalance(pancakeRouterMock.address)).to.be.greaterThan(0); // Mock test
  });

  it("Should refund if one party doesn't deposit", async () => {
    await tokenLaunch.connect(partyA).deposit({ value: depositAmount });
    await ethers.provider.send("evm_increaseTime", [refundDelay + 1]);
    await expect(tokenLaunch.connect(partyA).refund())
      .to.emit(tokenLaunch, "Refunded")
      .withArgs(partyA.address, depositAmount);
  });

  it("Should reset liquidity if deadline passes", async () => {
    await tokenLaunch.connect(partyA).deposit({ value: depositAmount });
    await tokenLaunch.connect(partyB).deposit({ value: depositAmount });
    await tokenLaunch.connect(partyA).createToken("GrokDog Coin", "GROKDOG", "https://logo.uri");
    await ethers.provider.send("evm_increaseTime", [liquidityDeadline + 1]);
    await expect(tokenLaunch.connect(partyA).resetLiquidity())
      .to.emit(tokenLaunch, "LiquidityReset");
    expect(await tokenLaunch.getLaunchState()).to.equal(1); // Deposited
  });

  it("Should handle pause/unpause", async () => {
    await expect(tokenLaunch.connect(safeWallet).pause()).to.emit(tokenLaunch, "Paused");
    await expect(tokenLaunch.connect(partyA).deposit({ value: depositAmount })).to.be.revertedWith("Contract paused");
    await expect(tokenLaunch.connect(safeWallet).unpause()).to.emit(tokenLaunch, "Unpaused");
    await tokenLaunch.connect(partyA).deposit({ value: depositAmount });
    expect(await tokenLaunch.partyADeposited()).to.be.true;
  });

  it("Should handle emergency withdraw", async () => {
    await tokenLaunch.connect(partyA).deposit({ value: depositAmount });
    await tokenLaunch.connect(partyB).deposit({ value: depositAmount });
    await tokenLaunch.connect(partyA).createToken("GrokDog Coin", "GROKDOG", "https://logo.uri");
    await expect(tokenLaunch.connect(partyA).emergencyWithdraw())
      .to.emit(tokenLaunch, "EmergencyWithdrawn");
  });

  it("Should revert on invalid actions", async () => {
    await expect(tokenLaunch.connect(partyA).createToken("Name", "Sym", "URI")).to.be.revertedWith("Invalid state");
    await expect(tokenLaunch.connect(partyA).lockLP(pancakeRouterMock.address, lpLockerMock.address, 1))
      .to.be.revertedWith("Invalid state");
  });
});

// Mock PancakeRouter
const PancakeRouterMock = `
contract PancakeRouterMock {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        return (amountTokenDesired, msg.value, 1000);
    }
}
`;

// Mock Safe with IERC165
const SafeMock = `
contract SafeMock {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7; // IERC165
    }
}
`;
