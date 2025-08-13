pragma solidity ^0.8.20;

import "@openzeppelin/contracts@5.0.0/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@5.0.0/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts@5.0.0/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts@5.0.0/access/AccessControl.sol";
import "@openzeppelin/contracts@5.0.0/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts@5.0.0/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts@5.0.0/security/Pausable.sol";

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
    
    function WETH() external pure returns (address);
    function factory() external pure returns (address);
}

// Interface for liquidity lockers (Team Finance, DxSale, etc.)
interface ILiquidityLocker {
    function lockTokens(
        address token,
        address beneficiary,
        uint256 amount,
        uint256 unlockTime
    ) external;
}

// Custom BEP-20 token with enhanced security
contract Memecoin is ERC20 {
    uint8 private _decimals;
    address public immutable deployer;
    bool public ownershipRenounced;
    
    modifier onlyDeployer() {
        require(msg.sender == deployer && !ownershipRenounced, "Unauthorized");
        _;
    }
    
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, uint8 decimals_)
        ERC20(name_, symbol_)
    {
        deployer = msg.sender;
        _decimals = decimals_;
        _mint(msg.sender, totalSupply_);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function renounceOwnership() external onlyDeployer {
        ownershipRenounced = true;
    }
}

/// @title TokenLaunch - Secure trustless memecoin launch contract for BNB Chain
/// @dev Deploy on BNB Chain (chainId 56 by default). Compatible with PancakeSwap V2
/// @custom:version 2.0.0
/// @custom:security-contact security@x.ai
contract TokenLaunch is ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant PARTY_A_ROLE = keccak256("PARTY_A_ROLE");
    bytes32 public constant PARTY_B_ROLE = keccak256("PARTY_B_ROLE");
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");
    bytes32 public constant SAFE_ADMIN_ROLE = keccak256("SAFE_ADMIN_ROLE");

    // Immutable configuration
    address public immutable partyA;
    address public immutable partyB;
    address public immutable safeWallet;
    address public immutable pancakeRouter;
    uint256 public immutable targetChainId;
    
    // Launch parameters
    uint256 public immutable depositAmount;
    uint256 public immutable liquidityBNB;
    uint256 public immutable liquidityTokens;
    uint256 public immutable totalSupply;
    uint256 public immutable slippageBps;
    uint256 public immutable depositDeadline;
    uint256 public immutable refundDelay;
    uint256 public immutable liquidityDeadline;
    uint8 public immutable tokenDecimals;

    // State management
    enum LaunchState { 
        Initialized, 
        Deposited, 
        TokenCreated, 
        LiquidityAdded, 
        LPLocked,
        Failed,
        Refunded
    }
    
    LaunchState public state;
    mapping(address => uint256) public contributions;
    mapping(address => uint256) public pendingWithdrawals;
    
    // Token and launch data
    address public tokenAddress;
    string public tokenName;
    string public tokenSymbol;
    string public logoURI;
    uint256 public deploymentTime;
    uint256 public tokenCreationTime;
    uint256 public liquidityAddedTime;
    
    // Liquidity locking
    address public lpToken;
    address public liquidityLocker;
    uint256 public lockDuration;

    // Events
    event ContractDeployed(
        address indexed partyA, 
        address indexed partyB, 
        address indexed safeWallet, 
        address pancakeRouter, 
        uint256 targetChainId
    );
    event Deposited(address indexed party, uint256 amount);
    event TokenCreated(address indexed token, string name, string symbol, string logoURI);
    event MetadataUpdated(string name, string symbol, string logoURI);
    event LiquidityAdded(uint256 tokenAmount, uint256 bnbAmount, uint256 liquidityReceived, address lpToken);
    event RemainingTransferred(uint256 tokenAmount, uint256 bnbAmount);
    event LPLockInitiated(address indexed lpToken, address indexed locker, uint256 amount, uint256 duration);
    event LPLocked(address indexed lpToken, address indexed locker, uint256 amount, uint256 unlockTime);
    event Refunded(address indexed party, uint256 amount);
    event EmergencyRefunded(address indexed party, uint256 amount);
    event EmergencyWithdrawn(uint256 bnbBalance, uint256 tokenBalance);
    event StateChanged(LaunchState from, LaunchState to);
    event PendingWithdrawal(address indexed to, uint256 amount);
    event WithdrawalClaimed(address indexed claimer, uint256 amount);
    event LiquidityLockerSet(address indexed locker);

    modifier onlyParties() {
        require(
            hasRole(PARTY_A_ROLE, msg.sender) || hasRole(PARTY_B_ROLE, msg.sender), 
            "Only parties allowed"
        );
        _;
    }

    modifier atState(LaunchState _state) {
        require(state == _state, "Invalid state for operation");
        _;
    }

    modifier validAddress(address addr) {
        require(addr != address(0), "Invalid address");
        _;
    }

    constructor(
        address _partyA,
        address _partyB,
        address _safeWallet,
        address _pancakeRouter,
        uint256 _depositAmount,
        uint256 _liquidityBNB,
        uint256 _liquidityTokens,
        uint256 _totalSupply,
        uint8 _tokenDecimals,
        uint256 _slippageBps,
        uint256 _depositDeadline,
        uint256 _refundDelay,
        uint256 _liquidityDeadline,
        uint256 _targetChainId
    ) 
        validAddress(_partyA)
        validAddress(_partyB)
        validAddress(_safeWallet)
        validAddress(_pancakeRouter)
    {
        require(_partyA != _partyB, "Parties must be different");
        require(_depositAmount >= _liquidityBNB, "Insufficient deposit for liquidity");
        require(_liquidityTokens <= _totalSupply, "Liquidity tokens exceed total supply");
        require(_slippageBps <= 500, "Slippage too high"); // Max 5%
        require(_depositDeadline > 0 && _depositDeadline <= 7 days, "Invalid deposit deadline");
        require(_refundDelay > 0 && _refundDelay <= 30 days, "Invalid refund delay");
        require(_liquidityDeadline > 0 && _liquidityDeadline <= 7 days, "Invalid liquidity deadline");
        require(_tokenDecimals >= 8 && _tokenDecimals <= 18, "Invalid token decimals");
        
        // Validate chain ID
        uint256 chainId;
        assembly { chainId := chainid() }
        require(chainId == _targetChainId, "Wrong chain");
        
        // Enhanced Safe wallet validation
        _validateSafeWallet(_safeWallet);
        
        // Set immutable variables
        partyA = _partyA;
        partyB = _partyB;
        safeWallet = _safeWallet;
        pancakeRouter = _pancakeRouter;
        targetChainId = _targetChainId;
        depositAmount = _depositAmount;
        liquidityBNB = _liquidityBNB;
        liquidityTokens = _liquidityTokens;
        totalSupply = _totalSupply;
        tokenDecimals = _tokenDecimals;
        slippageBps = _slippageBps;
        depositDeadline = _depositDeadline;
        refundDelay = _refundDelay;
        liquidityDeadline = _liquidityDeadline;
        deploymentTime = block.timestamp;
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _safeWallet);
        _grantRole(PARTY_A_ROLE, _partyA);
        _grantRole(PARTY_B_ROLE, _partyB);
        _grantRole(CREATOR_ROLE, _partyA); // Party A creates token by default
        _grantRole(SAFE_ADMIN_ROLE, _safeWallet);
        
        state = LaunchState.Initialized;
        emit ContractDeployed(_partyA, _partyB, _safeWallet, _pancakeRouter, _targetChainId);
    }

    /// @notice Enhanced Safe wallet validation
    function _validateSafeWallet(address _safeWallet) internal view {
        require(_safeWallet.code.length > 0, "Safe must be a contract");
        
        // Try to call getOwners() to verify it's a Safe
        (bool success, bytes memory data) = _safeWallet.staticcall(
            abi.encodeWithSignature("getOwners()")
        );
        require(success && data.length > 0, "Invalid Safe wallet");
    }

    /// @notice Validate URI format
    function _isValidURI(string memory uri) internal pure returns (bool) {
        bytes memory uriBytes = bytes(uri);
        if (uriBytes.length == 0 || uriBytes.length > 200) return false;
        
        // Basic validation - must start with http:// or https://
        if (uriBytes.length < 7) return false;
        
        return (
            uriBytes[0] == 'h' && uriBytes[1] == 't' && uriBytes[2] == 't' && uriBytes[3] == 'p'
        );
    }

    /// @notice Safe ETH transfer with fallback to pending withdrawals
    function _safeTransferETH(address to, uint256 amount) internal {
        if (amount == 0) return;
        
        (bool success, ) = payable(to).call{value: amount, gas: 10000}("");
        if (!success) {
            pendingWithdrawals[to] += amount;
            emit PendingWithdrawal(to, amount);
        }
    }

    /// @notice Change state with event emission
    function _changeState(LaunchState newState) internal {
        LaunchState oldState = state;
        state = newState;
        emit StateChanged(oldState, newState);
    }

    /// @notice Deposit BNB from parties with enhanced validation
    function deposit() external payable onlyParties atState(LaunchState.Initialized) whenNotPaused nonReentrant {
        require(block.timestamp <= deploymentTime + depositDeadline, "Deposit deadline exceeded");
        require(msg.value == depositAmount, "Incorrect deposit amount");
        require(contributions[msg.sender] == 0, "Already deposited");
        
        contributions[msg.sender] = msg.value;
        emit Deposited(msg.sender, msg.value);
        
        // Check if both parties have deposited
        if (contributions[partyA] > 0 && contributions[partyB] > 0) {
            _changeState(LaunchState.Deposited);
        }
    }

    /// @notice Create BEP-20 token with enhanced validation
    function createToken(string calldata name, string calldata symbol, string calldata _logoURI)
        external
        onlyRole(CREATOR_ROLE)
        atState(LaunchState.Deposited)
        whenNotPaused
        nonReentrant
    {
        require(tokenAddress == address(0), "Token already created");
        require(bytes(name).length > 0 && bytes(name).length <= 50, "Invalid name length");
        require(bytes(symbol).length > 0 && bytes(symbol).length <= 10, "Invalid symbol length");
        require(_isValidURI(_logoURI), "Invalid logo URI");
        
        try new Memecoin(name, symbol, totalSupply, tokenDecimals) returns (Memecoin token) {
            tokenAddress = address(token);
            tokenName = name;
            tokenSymbol = symbol;
            logoURI = _logoURI;
            tokenCreationTime = block.timestamp;
            
            _changeState(LaunchState.TokenCreated);
            emit TokenCreated(tokenAddress, name, symbol, _logoURI);
        } catch {
            revert("Token creation failed");
        }
    }

    /// @notice Update metadata (Safe only)
    function setMetadata(string calldata name, string calldata symbol, string calldata _logoURI) 
        external 
        onlyRole(SAFE_ADMIN_ROLE) 
        whenNotPaused
    {
        require(bytes(name).length > 0 && bytes(name).length <= 50, "Invalid name length");
        require(bytes(symbol).length > 0 && bytes(symbol).length <= 10, "Invalid symbol length");
        require(_isValidURI(_logoURI), "Invalid logo URI");
        
        tokenName = name;
        tokenSymbol = symbol;
        logoURI = _logoURI;
        emit MetadataUpdated(name, symbol, _logoURI);
    }

    /// @notice Set approved liquidity locker
    function setLiquidityLocker(address _locker, uint256 _duration) 
        external 
        onlyRole(SAFE_ADMIN_ROLE) 
        validAddress(_locker)
        whenNotPaused
    {
        require(_duration >= 30 days && _duration <= 4 * 365 days, "Invalid lock duration");
        require(_locker.code.length > 0, "Locker must be contract");
        
        liquidityLocker = _locker;
        lockDuration = _duration;
        emit LiquidityLockerSet(_locker);
    }

    /// @notice Add liquidity to PancakeSwap V2 with enhanced security
    function addLiquidity() external onlyParties atState(LaunchState.TokenCreated) nonReentrant whenNotPaused {
        require(block.timestamp <= tokenCreationTime + liquidityDeadline, "Liquidity deadline exceeded");
        require(address(this).balance >= liquidityBNB, "Insufficient BNB for liquidity");
        
        IERC20 token = IERC20(tokenAddress);
        require(token.balanceOf(address(this)) >= liquidityTokens, "Insufficient tokens");
        
        // Approve router
        token.safeApprove(pancakeRouter, 0);
        token.safeApprove(pancakeRouter, liquidityTokens);
        
        // Calculate minimum amounts with slippage protection
        uint256 minTokenAmount = liquidityTokens * (10000 - slippageBps) / 10000;
        uint256 minBNBAmount = liquidityBNB * (10000 - slippageBps) / 10000;
        
        try IPancakeRouter(pancakeRouter).addLiquidityETH{value: liquidityBNB}(
            tokenAddress,
            liquidityTokens,
            minTokenAmount,
            minBNBAmount,
            address(this), // Receive LP tokens here first
            block.timestamp + 1800 // 30 minutes
        ) returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
            require(liquidity > 0, "No liquidity created");
            
            // Get LP token address
            lpToken = _getLPTokenAddress();
            require(lpToken != address(0), "LP token not found");
            
            // Transfer LP tokens to Safe
            IERC20(lpToken).safeTransfer(safeWallet, liquidity);
            
            // Renounce token ownership
            Memecoin(tokenAddress).renounceOwnership();
            
            liquidityAddedTime = block.timestamp;
            _changeState(LaunchState.LiquidityAdded);
            emit LiquidityAdded(amountToken, amountETH, liquidity, lpToken);

            // Transfer remaining assets to Safe
            uint256 remainingTokens = token.balanceOf(address(this));
            uint256 remainingBNB = address(this).balance;
            
            if (remainingTokens > 0) {
                token.safeTransfer(safeWallet, remainingTokens);
            }
            if (remainingBNB > 0) {
                _safeTransferETH(safeWallet, remainingBNB);
            }
            
            if (remainingTokens > 0 || remainingBNB > 0) {
                emit RemainingTransferred(remainingTokens, remainingBNB);
            }
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("Liquidity addition failed: ", reason)));
        } catch {
            revert("Liquidity addition failed");
        }
    }

    /// @notice Get LP token address from PancakeSwap factory
    function _getLPTokenAddress() internal view returns (address) {
        try IPancakeRouter(pancakeRouter).factory() returns (address factory) {
            try IPancakeRouter(pancakeRouter).WETH() returns (address weth) {
                (bool success, bytes memory data) = factory.staticcall(
                    abi.encodeWithSignature("getPair(address,address)", tokenAddress, weth)
                );
                if (success && data.length == 32) {
                    return abi.decode(data, (address));
                }
            } catch {}
        } catch {}
        return address(0);
    }

    /// @notice Lock LP tokens using approved locker
    function lockLP() external onlyParties atState(LaunchState.LiquidityAdded) nonReentrant whenNotPaused {
        require(liquidityLocker != address(0), "Liquidity locker not set");
        require(lpToken != address(0), "LP token not available");
        
        IERC20 lpTokenContract = IERC20(lpToken);
        uint256 lpBalance = lpTokenContract.balanceOf(safeWallet);
        require(lpBalance > 0, "No LP tokens in Safe");
        
        // Check if Safe has approved the locker
        require(
            lpTokenContract.allowance(safeWallet, liquidityLocker) >= lpBalance,
            "Safe must approve locker first"
        );
        
        uint256 unlockTime = block.timestamp + lockDuration;
        
        try ILiquidityLocker(liquidityLocker).lockTokens(
            lpToken,
            safeWallet,
            lpBalance,
            unlockTime
        ) {
            _changeState(LaunchState.LPLocked);
            emit LPLocked(lpToken, liquidityLocker, lpBalance, unlockTime);
        } catch Error(string memory reason) {
            emit LPLockInitiated(lpToken, liquidityLocker, lpBalance, lockDuration);
            revert(string(abi.encodePacked("LP lock failed: ", reason)));
        } catch {
            emit LPLockInitiated(lpToken, liquidityLocker, lpBalance, lockDuration);
            revert("LP lock failed - check locker compatibility");
        }
    }

    /// @notice Refund deposits with reentrancy protection
    function refund() external onlyParties nonReentrant whenNotPaused {
        uint256 refundAmount = contributions[msg.sender];
        require(refundAmount > 0, "No contribution to refund");
        
        bool canRefund = false;
        
        // Allow refunds in various scenarios
        if (state == LaunchState.Initialized) {
            // After deposit deadline if other party hasn't deposited
            require(block.timestamp > deploymentTime + depositDeadline, "Deposit deadline not passed");
            canRefund = (msg.sender == partyA && contributions[partyB] == 0) ||
                       (msg.sender == partyB && contributions[partyA] == 0);
        } else if (state == LaunchState.TokenCreated) {
            // After liquidity deadline
            require(block.timestamp > tokenCreationTime + liquidityDeadline, "Liquidity deadline not passed");
            canRefund = true;
        } else if (state == LaunchState.Failed) {
            canRefund = true;
        }
        
        require(canRefund, "Refund not available");
        
        contributions[msg.sender] = 0;
        _safeTransferETH(msg.sender, refundAmount);
        emit Refunded(msg.sender, refundAmount);
        
        // Check if this was the last refund
        if (contributions[partyA] == 0 && contributions[partyB] == 0) {
            _changeState(LaunchState.Refunded);
        }
    }

    /// @notice Emergency refund for critical situations
    function emergencyRefund() external onlyParties nonReentrant whenNotPaused {
        require(
            block.timestamp > deploymentTime + depositDeadline + refundDelay,
            "Emergency refund not yet available"
        );
        require(state != LaunchState.LPLocked, "Launch completed successfully");
        
        uint256 refundAmount = contributions[msg.sender];
        require(refundAmount > 0, "No contribution to refund");
        
        contributions[msg.sender] = 0;
        _changeState(LaunchState.Failed);
        
        _safeTransferETH(msg.sender, refundAmount);
        emit EmergencyRefunded(msg.sender, refundAmount);
    }

    /// @notice Claim pending ETH withdrawals
    function claimPendingWithdrawal() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "No pending withdrawal");
        
        pendingWithdrawals[msg.sender] = 0;
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Withdrawal failed");
        
        emit WithdrawalClaimed(msg.sender, amount);
    }

    /// @notice Emergency asset withdrawal (Safe only)
    function emergencyWithdraw() external onlyRole(SAFE_ADMIN_ROLE) nonReentrant whenNotPaused {
        require(
            state == LaunchState.Failed || 
            block.timestamp > deploymentTime + depositDeadline + refundDelay + 7 days,
            "Emergency withdrawal not authorized"
        );
        
        uint256 bnbBalance = address(this).balance;
        uint256 tokenBalance = 0;
        
        if (tokenAddress != address(0)) {
            tokenBalance = IERC20(tokenAddress).balanceOf(address(this));
            if (tokenBalance > 0) {
                IERC20(tokenAddress).safeTransfer(safeWallet, tokenBalance);
            }
        }
        
        if (bnbBalance > 0) {
            _safeTransferETH(safeWallet, bnbBalance);
        }
        
        emit EmergencyWithdrawn(bnbBalance, tokenBalance);
    }

    /// @notice Pause contract (Safe only)
    function pause() external onlyRole(SAFE_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause contract (Safe only)
    function unpause() external onlyRole(SAFE_ADMIN_ROLE) {
        _unpause();
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
        if (state == LaunchState.Failed) return "Failed";
        if (state == LaunchState.Refunded) return "Refunded";
        return "Unknown";
    }

    function getBalances() external view returns (uint256 bnbBalance, uint256 tokenBalance) {
        return (
            address(this).balance,
            tokenAddress == address(0) ? 0 : IERC20(tokenAddress).balanceOf(address(this))
        );
    }

    function getMetadata() external view returns (string memory name, string memory symbol, string memory uri) {
        return (tokenName, tokenSymbol, logoURI);
    }

    function getSafeAllowance(address token, address spender) external view returns (uint256) {
        return IERC20(token).allowance(safeWallet, spender);
    }

    function getSafeTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(safeWallet);
    }

    function getTimeRemaining() external view returns (uint256 depositTime, uint256 liquidityTime) {
        if (state == LaunchState.Initialized) {
            uint256 deadline = deploymentTime + depositDeadline;
            depositTime = block.timestamp >= deadline ? 0 : deadline - block.timestamp;
        }
        if (state == LaunchState.TokenCreated) {
            uint256 deadline = tokenCreationTime + liquidityDeadline;
            liquidityTime = block.timestamp >= deadline ? 0 : deadline - block.timestamp;
        }
    }

    function isRefundAvailable(address party) external view returns (bool available, string memory reason) {
        if (contributions[party] == 0) {
            return (false, "No contribution");
        }
        
        if (state == LaunchState.Initialized) {
            if (block.timestamp <= deploymentTime + depositDeadline) {
                return (false, "Deposit deadline not reached");
            }
            if (party == partyA && contributions[partyB] > 0) {
                return (false, "Other party has deposited");
            }
            if (party == partyB && contributions[partyA] > 0) {
                return (false, "Other party has deposited");
            }
            return (true, "Refund available");
        }
        
        if (state == LaunchState.TokenCreated) {
            if (block.timestamp <= tokenCreationTime + liquidityDeadline) {
                return (false, "Liquidity deadline not reached");
            }
            return (true, "Liquidity deadline passed");
        }
        
        if (state == LaunchState.Failed) {
            return (true, "Launch failed");
        }
        
        return (false, "Launch completed or refund not available");
    }

    receive() external payable {
        require(msg.sender == pancakeRouter, "Direct ETH transfers not allowed");
    }
}
