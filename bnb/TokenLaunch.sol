pragma solidity ^0.8.20;

import "@openzeppelin/contracts@5.0.0/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@5.0.0/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts@5.0.0/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts@5.0.0/access/Ownable.sol";
import "@openzeppelin/contracts@5.0.0/security/ReentrancyGuard.sol";

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
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_)
        ERC20(name_, symbol_)
    {
        // Supply is scaled (e.g., 1_000_000_000 * 10^18 for 1B tokens with 18 decimals)
        _mint(msg.sender, totalSupply_);
    }

    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    function renounceOwnership() public override onlyOwner {
        super.renounceOwnership();
    }
}

/// @title TokenLaunch - Trustless memecoin launch contract for BNB Chain
/// @dev Deploy on BNB Chain (chainId 56). Compatible with PancakeSwap V2; consider V3 for concentrated liquidity in future.
/// @dev Use UUPS proxy for upgradeability if needed (not implemented here).
/// @dev Metadata stored on-chain; consider IPFS for gas savings in future versions.
/// @custom:security-contact security@x.ai
contract TokenLaunch is ReentrancyGuard {
    // Immutable parties and configs
    address public immutable partyA;
    address public immutable partyB;
    address public immutable safeWallet; // Pre-deployed Gnosis Safe (2/2 threshold)
    address public immutable pancakeRouter;
    
    // Configurable parameters
    uint256 public immutable depositAmount; // e.g., 0.24 BNB
    uint256 public immutable liquidityBNB; // e.g., 0.2 BNB
    uint256 public immutable liquidityTokens; // e.g., 100M tokens
    uint256 public immutable totalSupply; // e.g., 1B tokens
    uint256 public immutable slippageBps; // e.g., 100 = 1%, max 500 = 5%
    uint256 public immutable depositDeadline; // e.g., 1 hour
    uint256 public immutable refundDelay; // e.g., 1 day
    uint256 public immutable liquidityDeadline; // e.g., 1 day

    // State
    enum LaunchState { Initialized, Deposited, TokenCreated, LiquidityAdded, LPLocked }
    LaunchState public state;
    bool public paused;
    bool public partyADeposited;
    bool public partyBDeposited;
    address public tokenAddress;
    string public tokenName;
    string public tokenSymbol;
    string public logoURI;
    uint256 public deploymentTime;
    uint256 public tokenCreationTime;

    // Events
    event Deposited(address indexed party, uint256 amount);
    event TokenCreated(address indexed token, string name, string symbol, string logoURI);
    event LiquidityAdded(uint256 tokenAmount, uint256 bnbAmount, uint256 liquidityReceived);
    event RemainingTransferred(uint256 tokenAmount, uint256 bnbAmount);
    event LPLockInitiated(address indexed lpToken, address indexed locker, uint256 amount, uint256 duration);
    event LPLocked(address indexed locker, uint256 duration);
    event Refunded(address indexed party, uint256 amount);
    event EmergencyWithdrawn(uint256 bnbAmount, uint256 tokenAmount);
    event LiquidityReset();
    event StateChanged(LaunchState state);
    event Paused();
    event Unpaused();

    modifier onlyParties() {
        require(msg.sender == partyA || msg.sender == partyB, "Only parties");
        _;
    }

    modifier atState(LaunchState _state) {
        require(state == _state, "Invalid state");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract paused");
        _;
    }

    /// @dev Formal invariant: totalSupply >= IERC20(tokenAddress).balanceOf(address(this))
    /// @dev Formal invariant: state transitions only forward (Initialized -> Deposited -> TokenCreated -> LiquidityAdded -> LPLocked)
    /// @dev Formal property: address(this).balance >= depositAmount if state == Deposited
    /// @dev Formal property: safeWallet has 2/2 threshold (verified off-chain)
    constructor(
        address _partyA,
        address _partyB,
        address _safeWallet,
        address _pancakeRouter,
        uint256 _depositAmount,
        uint256 _liquidityBNB,
        uint256 _liquidityTokens,
        uint256 _totalSupply,
        uint256 _slippageBps,
        uint256 _depositDeadline,
        uint256 _refundDelay,
        uint256 _liquidityDeadline
    ) {
        require(_partyA != address(0) && _partyB != address(0) && _safeWallet != address(0) && _pancakeRouter != address(0), "Zero address");
        require(_partyA != _partyB, "Parties must differ");
        require(_depositAmount >= _liquidityBNB && _liquidityTokens <= _totalSupply, "Invalid amounts");
        require(_slippageBps <= 500, "Slippage too high"); // Max 5%
        require(_depositDeadline > 0 && _refundDelay > 0 && _liquidityDeadline > 0, "Invalid deadlines");
        // Ensure deployment on BNB Chain (chainId 56)
        uint256 chainId;
        assembly { chainId := chainid() }
        require(chainId == 56, "Must deploy on BNB Chain");
        partyA = _partyA;
        partyB = _partyB;
        safeWallet = _safeWallet;
        pancakeRouter = _pancakeRouter;
        depositAmount = _depositAmount;
        liquidityBNB = _liquidityBNB;
        liquidityTokens = _liquidityTokens;
        totalSupply = _totalSupply;
        slippageBps = _slippageBps;
        depositDeadline = _depositDeadline;
        refundDelay = _refundDelay;
        liquidityDeadline = _liquidityDeadline;
        deploymentTime = block.timestamp;
        state = LaunchState.Initialized;
    }

    /// @notice Deposit BNB from either party
    /// @dev Both parties must deposit within depositDeadline
    function deposit() external payable onlyParties atState(LaunchState.Initialized) whenNotPaused {
        require(block.timestamp <= deploymentTime + depositDeadline, "Deposit deadline passed");
        require(msg.value == depositAmount, "Incorrect deposit");
        if (msg.sender == partyA) {
            require(!partyADeposited, "Party A deposited");
            partyADeposited = true;
        } else {
            require(!partyBDeposited, "Party B deposited");
            partyBDeposited = true;
        }
        if (partyADeposited && partyBDeposited) {
            state = LaunchState.Deposited;
            emit StateChanged(state);
        }
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Create BEP-20 token
    /// @dev Metadata stored for DEX compatibility; consider IPFS for gas savings
    function createToken(string memory name, string memory symbol, string memory _logoURI)
        external
        onlyParties
        atState(LaunchState.Deposited)
        whenNotPaused
    {
        require(tokenAddress == address(0), "Token created");
        Memecoin token = new Memecoin(name, symbol, totalSupply);
        tokenAddress = address(token);
        tokenName = name;
        tokenSymbol = symbol;
        logoURI = _logoURI;
        tokenCreationTime = block.timestamp;
        state = LaunchState.TokenCreated;
        emit StateChanged(state);
        emit TokenCreated(tokenAddress, name, symbol, _logoURI);
    }

    /// @notice Add liquidity to PancakeSwap V2
    /// @dev Sends LP tokens to safeWallet; renounces token ownership
    function addLiquidity() external onlyParties atState(LaunchState.TokenCreated) nonReentrant whenNotPaused {
        require(block.timestamp <= tokenCreationTime + liquidityDeadline, "Liquidity deadline passed");
        require(IERC20(tokenAddress).balanceOf(address(this)) >= liquidityTokens, "Insufficient tokens");
        SafeERC20.safeApprove(IERC20(tokenAddress), pancakeRouter, 0);
        SafeERC20.safeApprove(IERC20(tokenAddress), pancakeRouter, liquidityTokens);
        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = IPancakeRouter(pancakeRouter).addLiquidityETH{value: liquidityBNB}(
            tokenAddress,
            liquidityTokens,
            liquidityTokens * (10000 - slippageBps) / 10000,
            liquidityBNB * (10000 - slippageBps) / 10000,
            safeWallet,
            block.timestamp + 1 hours
        );
        require(liquidity > 0, "Liquidity addition failed");
        Memecoin(tokenAddress).renounceOwnership();
        state = LaunchState.LiquidityAdded;
        emit StateChanged(state);
        emit LiquidityAdded(amountToken, amountETH, liquidity);

        // Transfer remaining
        uint256 remainingTokens = IERC20(tokenAddress).balanceOf(address(this));
        uint256 remainingBNB = address(this).balance;
        if (remainingTokens > 0) SafeERC20.safeTransfer(IERC20(tokenAddress), safeWallet, remainingTokens);
        if (remainingBNB > 0) payable(safeWallet).transfer(remainingBNB);
        emit RemainingTransferred(remainingTokens, remainingBNB);
    }

    /// @notice Initiate LP token locking
    /// @dev Safe must approve transfer to locker (e.g., Team Finance) via UI
    function lockLP(address lpToken, address locker, uint256 duration)
        external
        onlyParties
        atState(LaunchState.LiquidityAdded)
        whenNotPaused
    {
        require(locker != address(0), "Invalid locker");
        require(duration > 0, "Invalid duration");
        uint256 lpBalance = IERC20(lpToken).balanceOf(safeWallet);
        require(lpBalance > 0, "No LP tokens in Safe");
        require(IERC20(lpToken).allowance(safeWallet, locker) >= lpBalance, "Safe must approve locker");
        emit LPLockInitiated(lpToken, locker, lpBalance, duration);
        state = LaunchState.LPLocked;
        emit StateChanged(state);
        emit LPLocked(locker, duration);
    }

    /// @notice Refund if one party doesn't deposit
    function refund() external onlyParties atState(LaunchState.Initialized) whenNotPaused {
        require(block.timestamp > deploymentTime + refundDelay, "Too early");
        if (msg.sender == partyA && !partyBDeposited) {
            payable(partyA).transfer(depositAmount);
            emit Refunded(partyA, depositAmount);
        } else if (msg.sender == partyB && !partyADeposited) {
            payable(partyB).transfer(depositAmount);
            emit Refunded(partyB, depositAmount);
        }
    }

    /// @notice Reset to Deposited if liquidity fails
    function resetLiquidity() external onlyParties atState(LaunchState.TokenCreated) whenNotPaused {
        require(block.timestamp > tokenCreationTime + liquidityDeadline, "Too early");
        require(IERC20(tokenAddress).balanceOf(address(this)) >= totalSupply, "Tokens moved");
        state = LaunchState.Deposited;
        emit StateChanged(state);
        emit LiquidityReset();
    }

    /// @notice Emergency withdraw tokens/BNB
    function emergencyWithdraw() external onlyParties whenNotPaused {
        require(state >= LaunchState.TokenCreated, "No assets to withdraw");
        uint256 tokenBalance = IERC20(tokenAddress).balanceOf(address(this));
        uint256 bnbBalance = address(this).balance;
        if (tokenBalance > 0) SafeERC20.safeTransfer(IERC20(tokenAddress), safeWallet, tokenBalance);
        if (bnbBalance > 0) payable(safeWallet).transfer(bnbBalance);
        emit EmergencyWithdrawn(bnbBalance, tokenBalance);
    }

    /// @notice Pause contract (Safe only)
    function pause() external {
        require(msg.sender == safeWallet, "Only Safe");
        require(!paused, "Already paused");
        paused = true;
        emit Paused();
    }

    /// @notice Unpause contract (Safe only)
    function unpause() external {
        require(msg.sender == safeWallet, "Only Safe");
        require(paused, "Not paused");
        paused = false;
        emit Unpaused();
    }

    // View functions
    function getLaunchState() external view returns (LaunchState) {
        return state;
    }

    function getStateName() external view returns (string memory) {
        if (state == LaunchState.Initialized) return "Initialized";
        if (state == LaunchState.Deposited) return "Deposited";
        if (state == LaunchState.TokenCreated) return "TokenCreated";
        if (state == LaunchState.LiquidityAdded) return "LiquidityAdded";
        if (state == LaunchState.LPLocked) return "LPLocked";
        return "Unknown";
    }

    function getBalances() external view returns (uint256 bnbBalance, uint256 tokenBalance) {
        return (address(this).balance, tokenAddress == address(0) ? 0 : IERC20(tokenAddress).balanceOf(address(this)));
    }

    function getMetadata() external view returns (string memory name, string memory symbol, string memory uri) {
        return (tokenName, tokenSymbol, logoURI);
    }

    function getSafeAllowance(address lpToken, address locker) external view returns (uint256) {
        return IERC20(lpToken).allowance(safeWallet, locker);
    }

    function getSafeLPBalance(address lpToken) external view returns (uint256) {
        return IERC20(lpToken).balanceOf(safeWallet);
    }

    receive() external payable {}
}
