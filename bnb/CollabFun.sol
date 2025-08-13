pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Context.sol";

// PancakeSwap V2 Router interface
interface IPancakeRouter {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

// Custom BEP-20 token with minting
contract Memecoin is ERC20, Ownable {
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_)
        ERC20(name_, symbol_)
    {
        _mint(msg.sender, totalSupply_ * 10**decimals());
    }

    function renounceOwnership() public override onlyOwner {
        super.renounceOwnership();
    }
}

contract TokenLaunch is Context, ReentrancyGuard {
    // Parties and multisig wallet
    address public immutable partyA;
    address public immutable partyB;
    address public immutable safeWallet; // Gnosis Safe multisig (2/2)
    
    // Constants for deposits and liquidity
    uint256 public constant DEPOSIT_AMOUNT = 0.24 ether; // ~$120 per party
    uint256 public constant LIQUIDITY_BNB = 0.2 ether; // ~$100 for PancakeSwap
    uint256 public constant LIQUIDITY_TOKENS = 100_000_000 * 10**18; // 100M tokens
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10**18; // 1B tokens
    uint256 public constant DEPOSIT_DEADLINE = 1 hours; // Time to deposit
    uint256 public constant REFUND_DELAY = 1 days; // Time before refund

    // State tracking
    enum LaunchState { Initialized, Deposited, TokenCreated, LiquidityAdded }
    LaunchState public state;
    address public tokenAddress;
    address public immutable pancakeRouter; // Configurable PancakeSwap router
    uint256 public deploymentTime;

    // Events for transparency
    event Deposited(address indexed party, uint256 amount);
    event TokenCreated(address indexed token, string name, string symbol);
    event LiquidityAdded(uint256 tokenAmount, uint256 bnbAmount, address lpTokenRecipient);
    event RemainingTransferred(uint256 tokenAmount, uint256 bnbAmount);
    event MetadataSet(string name, string symbol, string logoURI);
    event EmergencyWithdrawn(uint256 bnbAmount, uint256 tokenAmount);

    // Modifiers
    modifier onlyParties() {
        require(_msgSender() == partyA || _msgSender() == partyB, "Only parties");
        _;
    }

    modifier atState(LaunchState _state) {
        require(state == _state, "Invalid state");
        _;
    }

    constructor(
        address _partyA,
        address _partyB,
        address _safeWallet,
        address _pancakeRouter
    ) {
        require(_partyA != address(0) && _partyB != address(0) && _safeWallet != address(0), "Zero address");
        require(_partyA != _partyB, "Parties must be different");
        require(_pancakeRouter != address(0), "Invalid router");
        partyA = _partyA;
        partyB = _partyB;
        safeWallet = _safeWallet;
        pancakeRouter = _pancakeRouter;
        deploymentTime = block.timestamp;
        state = LaunchState.Initialized;
    }

    // Deposit BNB from each party
    function deposit() external payable onlyParties atState(LaunchState.Initialized) {
        require(block.timestamp <= deploymentTime + DEPOSIT_DEADLINE, "Deposit deadline passed");
        require(msg.value == DEPOSIT_AMOUNT, "Incorrect deposit amount");
        if (_msgSender() == partyA) {
            require(state != LaunchState.Deposited || partyB == address(0), "Party A already deposited");
            if (partyB != address(0)) {
                state = LaunchState.Deposited;
            }
        } else {
            require(state != LaunchState.Deposited || partyA == address(0), "Party B already deposited");
            if (partyA != address(0)) {
                state = LaunchState.Deposited;
            }
        }
        emit Deposited(_msgSender(), msg.value);
    }

    // Create BEP-20 token
    function createToken(
        string memory name,
        string memory symbol,
        string memory logoURI
    ) external onlyParties atState(LaunchState.Deposited) {
        require(tokenAddress == address(0), "Token already created");
        Memecoin token = new Memecoin(name, symbol, 1_000_000_000);
        tokenAddress = address(token);
        state = LaunchState.TokenCreated;
        emit TokenCreated(tokenAddress, name, symbol);
        emit MetadataSet(name, symbol, logoURI); // For DEXScreener compatibility
    }

    // Add liquidity to PancakeSwap and transfer remaining assets
    function addLiquidity() external onlyParties atState(LaunchState.TokenCreated) nonReentrant {
        require(IERC20(tokenAddress).balanceOf(address(this)) >= LIQUIDITY_TOKENS, "Insufficient tokens");
        IERC20(tokenAddress).approve(pancakeRouter, LIQUIDITY_TOKENS);
        IPancakeRouter(pancakeRouter).addLiquidityETH{value: LIQUIDITY_BNB}(
            tokenAddress,
            LIQUIDITY_TOKENS,
            LIQUIDITY_TOKENS * 99 / 100, // 1% slippage protection
            LIQUIDITY_BNB * 99 / 100,   // 1% slippage protection
            safeWallet, // LP tokens to Safe
            block.timestamp + 1 hours
        );
        Memecoin(tokenAddress).renounceOwnership(); // Renounce after liquidity
        state = LaunchState.LiquidityAdded;
        emit LiquidityAdded(LIQUIDITY_TOKENS, LIQUIDITY_BNB, safeWallet);

        // Transfer remaining tokens and BNB to Safe
        uint256 remainingTokens = IERC20(tokenAddress).balanceOf(address(this));
        uint256 remainingBNB = address(this).balance;
        if (remainingTokens > 0) {
            IERC20(tokenAddress).transfer(safeWallet, remainingTokens);
        }
        if (remainingBNB > 0) {
            payable(safeWallet).transfer(remainingBNB);
        }
        emit RemainingTransferred(remainingTokens, remainingBNB);
    }

    // Refund if one party doesn't deposit
    function refund() external onlyParties atState(LaunchState.Initialized) {
        require(block.timestamp > deploymentTime + REFUND_DELAY, "Too early");
        if (_msgSender() == partyA && state != LaunchState.Deposited) {
            payable(partyA).transfer(DEPOSIT_AMOUNT);
        } else if (_msgSender() == partyB && state != LaunchState.Deposited) {
            payable(partyB).transfer(DEPOSIT_AMOUNT);
        }
    }

    // Emergency withdrawal to Safe (post-liquidity)
    function emergencyWithdraw() external onlyParties atState(LaunchState.LiquidityAdded) {
        uint256 tokenBalance = IERC20(tokenAddress).balanceOf(address(this));
        uint256 bnbBalance = address(this).balance;
        if (tokenBalance > 0) {
            IERC20(tokenAddress).transfer(safeWallet, tokenBalance);
        }
        if (bnbBalance > 0) {
            payable(safeWallet).transfer(bnbBalance);
        }
        emit EmergencyWithdrawn(bnbBalance, tokenBalance);
    }

    // Receive BNB for liquidity
    receive() external payable {}
}
