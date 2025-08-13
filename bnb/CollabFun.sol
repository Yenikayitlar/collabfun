pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";

// Assume IPancakeRouter interface (use actual Pancake V2 router interface)
interface IPancakeRouter {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

// Assume Gnosis Safe is deployed separately; no direct interface needed beyond address

contract Memecoin is ERC20, Ownable {
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_) ERC20(name_, symbol_) {
        _mint(msg.sender, totalSupply_ * 10**decimals());
    }

    function renounceOwnership() public override onlyOwner {
        super.renounceOwnership();
    }
}

contract TokenLaunch is Context {
    address public partyA;
    address public partyB;
    address public safeWallet; // Gnosis Safe multisig address
    uint256 public constant depositAmount = 0.24 ether; // ~$120 in BNB per party
    uint256 public constant liquidityBNB = 0.2 ether; // ~$100 for PancakeSwap pool
    uint256 public constant liquidityTokens = 100_000_000 * 10**18; // 100M tokens
    uint256 public constant totalSupply = 1_000_000_000 * 10**18; // 1B tokens
    bool public partyADeposited;
    bool public partyBDeposited;
    bool public tokenCreated;
    bool public liquidityAdded;
    address public tokenAddress;
    address public constant pancakeRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E; // PancakeSwap V2 Router
    uint256 public deploymentTime;

    event Deposited(address party, uint256 amount);
    event TokenCreated(address token);
    event LiquidityAdded(uint256 tokenAmount, uint256 bnbAmount);
    event RemainingTransferred(uint256 tokenAmount, uint256 bnbAmount);

    modifier onlyParties() {
        require(_msgSender() == partyA || _msgSender() == partyB, "Only parties can call");
        _;
    }

    constructor(address _partyA, address _partyB, address _safeWallet) {
        partyA = _partyA;
        partyB = _partyB;
        safeWallet = _safeWallet;
        deploymentTime = block.timestamp;
    }

    // Both parties deposit BNB
    function deposit() external payable onlyParties {
        require(!tokenCreated, "Launch already started");
        require(msg.value == depositAmount, "Incorrect deposit amount");
        if (_msgSender() == partyA) {
            require(!partyADeposited, "Already deposited");
            partyADeposited = true;
        } else {
            require(!partyBDeposited, "Already deposited");
            partyBDeposited = true;
        }
        emit Deposited(_msgSender(), msg.value);
    }

    // Create BEP-20 token after both deposit
    function createToken() external onlyParties {
        require(partyADeposited && partyBDeposited, "Both must deposit");
        require(!tokenCreated, "Token already created");
        Memecoin token = new Memecoin("GrokDog Coin", "GROKDOG", 1_000_000_000);
        tokenAddress = address(token);
        token.renounceOwnership(); // Renounce for fairness
        tokenCreated = true;
        emit TokenCreated(tokenAddress);
    }

    // Add liquidity to PancakeSwap
    function addLiquidity() external onlyParties {
        require(tokenCreated, "Token not created");
        require(!liquidityAdded, "Liquidity already added");
        IERC20(tokenAddress).approve(pancakeRouter, liquidityTokens);
        IPancakeRouter(pancakeRouter).addLiquidityETH{value: liquidityBNB}(
            tokenAddress,
            liquidityTokens,
            0,
            0,
            safeWallet, // LP tokens to Safe
            block.timestamp + 1 hours
        );
        liquidityAdded = true;
        emit LiquidityAdded(liquidityTokens, liquidityBNB);

        // Transfer remaining tokens and BNB to Safe
        uint256 remainingTokens = IERC20(tokenAddress).balanceOf(address(this));
        IERC20(tokenAddress).transfer(safeWallet, remainingTokens);
        payable(safeWallet).transfer(address(this).balance);
        emit RemainingTransferred(remainingTokens, address(this).balance);
    }

    // Refund if one party doesn't deposit after 1 day
    function refund() external onlyParties {
        require(block.timestamp > deploymentTime + 1 days, "Too early");
        require(!tokenCreated, "Launch started");
        if (!partyADeposited && _msgSender() == partyB) {
            payable(partyB).transfer(depositAmount);
        } else if (!partyBDeposited && _msgSender() == partyA) {
            payable(partyA).transfer(depositAmount);
        }
    }
}
