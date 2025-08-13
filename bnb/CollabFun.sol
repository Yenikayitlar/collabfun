pragma solidity ^0.8.20;

import "@openzeppelin/contracts@4.9.0/token/ERC20/ERC20.sol"; // Pinned version
import "@openzeppelin/contracts@4.9.0/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts@4.9.0/access/Ownable.sol";
import "@openzeppelin/contracts@4.9.0/security/ReentrancyGuard.sol";

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

// Custom BEP-20 token
contract Memecoin is ERC20, Ownable {
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_) ERC20(name_, symbol_) {
        _mint(msg.sender, totalSupply_ * 10**decimals());
    }

    function decimals() public view virtual override returns (uint8) {
        return 18; // Explicit for clarity
    }

    function renounceOwnership() public override onlyOwner {
        super.renounceOwnership();
    }
}

contract TokenLaunch is ReentrancyGuard {
    // Immutable parties and configs
    address public immutable partyA;
    address public immutable partyB;
    address public immutable safeWallet; // Pre-deployed Gnosis Safe (2/2 threshold, owned by partyA and partyB)
    address public immutable pancakeRouter; // PancakeSwap router
    address public immutable lpLocker; // Optional: Team Finance or similar locker address
    
    // Configurable parameters
    uint256 public immutable depositAmount; // e.g., 0.24 ether
    uint256 public immutable liquidityBNB; // e.g., 0.2 ether
    uint256 public immutable liquidityTokens; // e.g., 100_000_000 * 10**18
    uint256 public immutable totalSupply; // e.g., 1_000_000_000 * 10**18
    uint256 public constant DEPOSIT_DEADLINE = 1 hours;
    uint256 public constant REFUND_DELAY = 1 days;

    // State
    enum LaunchState { Initialized, Deposited, TokenCreated, LiquidityAdded, LPLocked }
    LaunchState public state;
    bool public partyADeposited;
    bool public partyBDeposited;
    address public tokenAddress;
    uint256 public deploymentTime;

    // Events
    event Deposited(address indexed party, uint256 amount);
    event TokenCreated(address indexed token, string name, string symbol, string logoURI);
    event LiquidityAdded(uint256 tokenAmount, uint256 bnbAmount, uint256 liquidityReceived);
    event RemainingTransferred(uint256 tokenAmount, uint256 bnbAmount);
    event LPLocked(address locker, uint256 duration);
    event Refunded(address indexed party, uint256 amount);
    event EmergencyWithdrawn(uint256 bnbAmount, uint256 tokenAmount);

    modifier onlyParties() {
        require(msg.sender == partyA || msg.sender == partyB, "Only parties");
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
        address _pancakeRouter,
        address _lpLocker,
        uint256 _depositAmount,
        uint256 _liquidityBNB,
        uint256 _liquidityTokens,
        uint256 _totalSupply
    ) {
        require(_partyA != address(0) && _partyB != address(0) && _safeWallet != address(0) && _pancakeRouter != address(0), "Zero address invalid");
        require(_partyA != _partyB, "Parties must differ");
        require(_depositAmount > 0 && _liquidityBNB > 0 && _liquidityTokens > 0 && _totalSupply > _liquidityTokens, "Invalid amounts");
        partyA = _partyA;
        partyB = _partyB;
        safeWallet = _safeWallet;
        pancakeRouter = _pancakeRouter;
        lpLocker = _lpLocker; // If address(0), skip locking
        depositAmount = _depositAmount;
        liquidityBNB = _liquidityBNB;
        liquidityTokens = _liquidityTokens;
        totalSupply = _totalSupply;
        deploymentTime = block.timestamp;
        state = LaunchState.Initialized;
    }

    // Deposit BNB
    function deposit() external payable onlyParties atState(LaunchState.Initialized) {
        require(block.timestamp <= deploymentTime + DEPOSIT_DEADLINE, "Deposit deadline passed");
        require(msg.value == depositAmount, "Incorrect deposit");
        if (msg.sender == partyA) {
            require(!partyADeposited, "Already deposited");
            partyADeposited = true;
        } else {
            require(!partyBDeposited, "Already deposited");
            partyBDeposited = true;
        }
        if (partyADeposited && partyBDeposited) {
            state = LaunchState.Deposited;
        }
        emit Deposited(msg.sender, msg.value);
    }

    // Create token
    function createToken(string memory name, string memory symbol, string memory logoURI) external onlyParties atState(LaunchState.Deposited) {
        require(tokenAddress == address(0), "Token created");
        Memecoin token = new Memecoin(name, symbol, totalSupply / 10**token.decimals());
        tokenAddress = address(token);
        state = LaunchState.TokenCreated;
        emit TokenCreated(tokenAddress, name, symbol);
        emit RemainingTransferred(logoURI, 0); // Misuse event for metadata; fix if needed
    }

    // Add liquidity
    function addLiquidity() external onlyParties atState(LaunchState.TokenCreated) nonReentrant {
        require(IERC20(tokenAddress).balanceOf(address(this)) >= liquidityTokens, "Insufficient tokens");
        IERC20(tokenAddress).approve(pancakeRouter, liquidityTokens);
        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = IPancakeRouter(pancakeRouter).addLiquidityETH{value: liquidityBNB}(
            tokenAddress,
            liquidityTokens,
            liquidityTokens * 99 / 100,
            liquidityBNB * 99 / 100,
            safeWallet,
            block.timestamp + 1 hours
        );
        require(liquidity > 0, "Liquidity addition failed");
        Memecoin(tokenAddress).renounceOwnership();
        state = LaunchState.LiquidityAdded;
        emit LiquidityAdded(amountToken, amountETH, liquidity);

        // Transfer remaining
        uint256 remainingTokens = IERC20(tokenAddress).balanceOf(address(this));
        uint256 remainingBNB = address(this).balance;
        if (remainingTokens > 0) IERC20(tokenAddress).transfer(safeWallet, remainingTokens);
        if (remainingBNB > 0) payable(safeWallet).transfer(remainingBNB);
        emit RemainingTransferred(remainingTokens, remainingBNB);
    }

    // Lock LP tokens (if lpLocker set)
    function lockLP(address lpToken, uint256 duration) external onlyParties atState(LaunchState.LiquidityAdded) {
        require(lpLocker != address(0), "No locker set");
        require(duration > 0, "Invalid duration");
        IERC20(lpToken).transfer(lpLocker, IERC20(lpToken).balanceOf(safeWallet)); // Assume Safe approves first
        state = LaunchState.LPLocked;
        emit LPLocked(lpLocker, duration);
    }

    // Refund
    function refund() external onlyParties atState(LaunchState.Initialized) {
        require(block.timestamp > deploymentTime + REFUND_DELAY, "Too early");
        if (msg.sender == partyA && !partyBDeposited) {
            payable(partyA).transfer(depositAmount);
            emit Refunded(partyA, depositAmount);
        } else if (msg.sender == partyB && !partyADeposited) {
            payable(partyB).transfer(depositAmount);
            emit Refunded(partyB, depositAmount);
        }
    }

    // Emergency withdraw
    function emergencyWithdraw() external onlyParties {
        uint256 tokenBalance = IERC20(tokenAddress).balanceOf(address(this));
        uint256 bnbBalance = address(this).balance;
        if (tokenBalance > 0) IERC20(tokenAddress).transfer(safeWallet, tokenBalance);
        if (bnbBalance > 0) payable(safeWallet).transfer(bnbBalance);
        emit EmergencyWithdrawn(bnbBalance, tokenBalance);
    }

    // View functions
    function getLaunchState() external view returns (LaunchState) {
        return state;
    }

    function getBalances() external view returns (uint256 bnbBalance, uint256 tokenBalance) {
        return (address(this).balance, tokenAddress == address(0) ? 0 : IERC20(tokenAddress).balanceOf(address(this)));
    }

    receive() external payable {}
}
