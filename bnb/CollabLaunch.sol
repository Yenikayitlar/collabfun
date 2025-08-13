pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IPancakeRouter.sol";
import "./GnosisSafe.sol";

contract TokenLaunch {
    address public partyA;
    address public partyB;
    address public safeWallet; // Gnosis Safe multisig address
    uint256 public depositAmount = 0.24 ether; // ~$120 in BNB per party
    uint256 public liquidityBNB = 0.2 ether; // ~$100 for PancakeSwap pool
    uint256 public liquidityTokens = 100_000_000 * 10**18; // 100M tokens
    bool public partyADeposited;
    bool public partyBDeposited;
    address public tokenAddress;
    address public pancakeRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E; // PancakeSwap Router

    constructor(address _partyA, address _partyB, address _safeWallet) {
        partyA = _partyA;
        partyB = _partyB;
        safeWallet = _safeWallet;
    }

    // Both parties deposit BNB
    function deposit() external payable {
        require(msg.sender == partyA || msg.sender == partyB, "Invalid sender");
        require(msg.value == depositAmount, "Incorrect deposit amount");
        if (msg.sender == partyA) partyADeposited = true;
        if (msg.sender == partyB) partyBDeposited = true;
    }

    // Create BEP-20 token after both deposit
    function createToken() external {
        require(partyADeposited && partyBDeposited, "Both must deposit");
        require(tokenAddress == address(0), "Token already created");
        ERC20 token = new ERC20("GrokDog Coin", "GROKDOG");
        tokenAddress = address(token);
        token.transfer(safeWallet, 1_000_000_000 * 10**18); // 1B tokens to Safe
    }

    // Add liquidity to PancakeSwap
    function addLiquidity() external {
        require(tokenAddress != address(0), "Token not created");
        require(partyADeposited && partyBDeposited, "Both must deposit");
        IERC20(tokenAddress).approve(pancakeRouter, liquidityTokens);
        IPancakeRouter(pancakeRouter).addLiquidityETH{value: liquidityBNB}(
            tokenAddress,
            liquidityTokens,
            0,
            0,
            safeWallet, // LP tokens to Safe
            block.timestamp + 1 hours
        );
    }

    // Refund if one party doesn't deposit
    function refund() external {
        require(block.timestamp > block.timestamp + 1 days, "Too early");
        if (!partyADeposited && msg.sender == partyB) payable(partyB).transfer(depositAmount);
        if (!partyBDeposited && msg.sender == partyA) payable(partyA).transfer(depositAmount);
    }
}
