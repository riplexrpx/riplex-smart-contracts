// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice Minimal BEP-20 interface used for LP-token transfers.
interface IBEP20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Minimal PancakeSwap router interface required for swaps and liquidity.
interface IPancakeRouter {
    function factory() external view returns (address);

    /// @dev PancakeSwap keeps the Uniswap name WETH(), but on BSC this returns WBNB.
    function WETH() external view returns (address);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

/// @notice Minimal PancakeSwap factory interface required to create the RPX/WBNB pair.
interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @title Riplex Token
/// @notice BEP-20 token for Binance Smart Chain with fixed supply, launch protection, automatic tax conversion, and LP locking.
contract BEP20RPX {
    string public constant name = "Riplex";
    string public constant symbol = "RPX";
    uint8 public constant decimals = 18;

    uint256 public constant MAX_SUPPLY = 100_000_000_000 ether;
    uint256 public constant MAX_TAX_PERCENT = 10;
    uint256 public constant MAX_DEAD_BLOCKS = 10;
    uint256 public constant MAX_SWAP_SLIPPAGE_BPS = 1_000;
    uint256 public constant SHARE_DENOMINATOR = 10_000;
    uint256 public constant MAX_TRACKED_LAUNCH_ACCOUNTS = 32;

    uint256 private constant PERCENT_DENOMINATOR = 100;
    uint8 private constant FEE_STEP_NONE = 0;
    uint8 private constant FEE_STEP_QUOTE = 1;
    uint8 private constant FEE_STEP_SWAP = 2;
    uint8 private constant FEE_STEP_LIQUIDITY = 3;

    mapping(address account => uint256) private _balances;
    mapping(address account => mapping(address spender => uint256)) private _allowances;

    address public owner;
    address public pendingOwner;
    bool public tradingEnabled;

    mapping(address account => bool) public isExcludedFromFees;
    mapping(address account => bool) public isExcludedFromLimits;
    mapping(address account => bool) public isExcludedFromProtection;

    uint256 public maxTxAmount;
    uint256 public maxWalletAmount;
    uint256 public swapTokensAtAmount;
    uint256 public swapSlippageBps = 500;

    uint256 public buyTax = 3;
    uint256 public sellTax = 5;
    uint256 public transferTax = 1;

    address public liquidityWallet;
    address public marketingWallet;
    address public developmentWallet;

    uint256 public liquidityShare = 5_000;
    uint256 public marketingShare = 3_000;
    uint256 public developmentShare = 2_000;

    IPancakeRouter public immutable router;
    address public immutable WBNB;
    address public immutable pair;

    uint256 public launchBlock;
    uint256 public deadBlocks = 3;

    bool public cooldownEnabled = true;
    uint256 public cooldownTime = 30 seconds;
    mapping(address account => uint256) public lastTransferTime;
    mapping(address account => uint256) public lastBuyBlock;

    uint256 public lpUnlockTime;
    bool public lpLockPermanent;
    uint256 public pendingMarketingBNB;
    uint256 public pendingDevelopmentBNB;
    bool public feeProcessingFailed;
    uint256 public lastFeeProcessingFailureBlock;
    uint8 public lastFeeProcessingFailureStep;

    bool private _inSwap;
    bool private _entered;
    address[] private _trackedLaunchAccounts;
    mapping(address account => bool) private _isTrackedLaunchAccount;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferCancelled(address indexed currentOwner, address indexed cancelledPendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TradingEnabled(uint256 indexed blockNumber);
    event InitialLiquidityAdded(uint256 tokenAmount, uint256 bnbAmount, uint256 liquidity);
    event TaxesUpdated(uint256 buyTax, uint256 sellTax, uint256 transferTax);
    event TaxWalletsUpdated(address indexed liquidityWallet, address indexed marketingWallet, address indexed developmentWallet);
    event TaxSharesUpdated(uint256 liquidityShare, uint256 marketingShare, uint256 developmentShare);
    event LimitsUpdated(uint256 maxTxAmount, uint256 maxWalletAmount);
    event SwapTokensAtAmountUpdated(uint256 amount);
    event SwapSlippageUpdated(uint256 slippageBps);
    event FeeExclusionUpdated(address indexed account, bool status);
    event LimitExclusionUpdated(address indexed account, bool status);
    event ProtectionExclusionUpdated(address indexed account, bool status);
    event DeadBlocksUpdated(uint256 deadBlocks);
    event CooldownUpdated(bool enabled, uint256 cooldownTime);
    event LiquidityLockExtended(uint256 unlockTime);
    event LiquidityLockMadePermanent();
    event LiquidityUnlocked(address indexed to, uint256 amount);
    event LiquidityRecovered(address indexed to, uint256 amount);
    event ForeignTokenRescued(address indexed token, address indexed to, uint256 amount);
    event BNBRescued(address indexed to, uint256 amount);
    event PendingBNBAccrued(uint256 marketingAmount, uint256 developmentAmount);
    event PendingBNBClaimed(address indexed wallet, address indexed recipient, uint256 amount);
    event FeeProcessingFailureRecorded(uint8 indexed step, uint256 indexed blockNumber);
    event FeeProcessingRecovered();
    event FeeProcessingTriggered(address indexed caller, uint256 tokenAmount);
    event FeeProcessingCompleted(
        uint256 tokenAmount,
        uint256 liquidityTokenAmount,
        uint256 liquidityBNBAmount,
        uint256 marketingBNBAmount,
        uint256 developmentBNBAmount
    );
    event OwnershipRenounced(address indexed previousOwner);
    event LaunchFinalized(address indexed previousOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "RPX: caller is not owner");
        _;
    }

    modifier beforeLaunch() {
        require(!tradingEnabled, "RPX: launch finalized");
        _;
    }

    modifier afterLaunch() {
        require(tradingEnabled, "RPX: trading disabled");
        _;
    }

    modifier lockSwap() {
        _inSwap = true;
        _;
        _inSwap = false;
    }

    modifier nonReentrant() {
        require(!_entered, "RPX: reentrant call");
        _entered = true;
        _;
        _entered = false;
    }

    /// @param routerAddress PancakeSwap-compatible router used to create the RPX/WBNB pair.
    constructor(address routerAddress) {
        require(routerAddress != address(0), "RPX: zero router");
        require(routerAddress.code.length > 0, "RPX: router not contract");

        uint256 initialSupply = MAX_SUPPLY;

        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);

        IPancakeRouter pancakeRouter = IPancakeRouter(routerAddress);
        address factoryAddress = pancakeRouter.factory();
        address wbnb = pancakeRouter.WETH();
        require(factoryAddress != address(0), "RPX: zero factory");
        require(factoryAddress.code.length > 0, "RPX: factory not contract");
        require(wbnb != address(0), "RPX: zero WBNB");
        require(wbnb.code.length > 0, "RPX: WBNB not contract");

        router = pancakeRouter;
        WBNB = wbnb;
        address existingPair = IPancakeFactory(factoryAddress).getPair(address(this), wbnb);
        if (existingPair == address(0)) {
            existingPair = IPancakeFactory(factoryAddress).createPair(address(this), wbnb);
        }

        pair = existingPair;
        require(pair != address(0), "RPX: zero pair");
        require(pair.code.length > 0, "RPX: pair not contract");

        liquidityWallet = msg.sender;
        marketingWallet = msg.sender;
        developmentWallet = msg.sender;

        maxTxAmount = initialSupply / 100;
        if (maxTxAmount == 0) {
            maxTxAmount = initialSupply;
        }

        maxWalletAmount = initialSupply / 50;
        if (maxWalletAmount == 0) {
            maxWalletAmount = initialSupply;
        }

        swapTokensAtAmount = initialSupply / 100_000;
        if (swapTokensAtAmount == 0) {
            swapTokensAtAmount = initialSupply;
        }
        lpUnlockTime = block.timestamp + 365 days;

        _setFeeExcluded(msg.sender, true);
        _setFeeExcluded(address(this), true);
        _setLimitExcluded(msg.sender, true);
        _setLimitExcluded(address(this), true);
        _setProtectionExcluded(msg.sender, true);
        _setProtectionExcluded(address(this), true);

        _balances[msg.sender] = initialSupply;

        emit Transfer(address(0), msg.sender, initialSupply);
    }

    receive() external payable {}

    // -------------------------------------------------------------------------
    // BEP-20 API
    // -------------------------------------------------------------------------

    function totalSupply() public pure returns (uint256) {
       return MAX_SUPPLY;
    }

    /// @notice BEP-20 compatibility helper used by BscScan and some BSC wallets.
    function getOwner() external view returns (address) {
        return owner;
    }

    /// @notice Returns the pre-launch accounts currently tracked for exclusion cleanup.
    function trackedLaunchAccounts() external view returns (address[] memory) {
        return _trackedLaunchAccounts;
    }

    /// @notice Returns fee-processing health and pending balances for operations monitoring.
    function feeProcessingStatus()
        external
        view
        returns (
            bool failed,
            uint256 failureBlock,
            uint8 failureStep,
            uint256 contractTokenBalance,
            uint256 marketingBNBAmount,
            uint256 developmentBNBAmount
        )
    {
        return (
            feeProcessingFailed,
            lastFeeProcessingFailureBlock,
            lastFeeProcessingFailureStep,
            _balances[address(this)],
            pendingMarketingBNB,
            pendingDevelopmentBNB
        );
    }

    /// @notice Returns the amount of tax tokens eligible for the next fee-processing call.
    function nextFeeProcessingAmount() external view returns (uint256) {
        uint256 contractTokenBalance = _balances[address(this)];
        if (contractTokenBalance == 0) {
            return 0;
        }

        if (contractTokenBalance < swapTokensAtAmount && !feeProcessingFailed) {
            return 0;
        }

        return _selectSwapAmount(contractTokenBalance);
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function allowance(address account, address spender) public view returns (uint256) {
        return _allowances[account][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "RPX: allowance exceeded");

        if (currentAllowance != type(uint256).max) {
            unchecked {
                _approve(from, msg.sender, currentAllowance - amount);
            }
        }

        _transfer(from, to, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 currentAllowance = _allowances[msg.sender][spender];
        require(currentAllowance >= subtractedValue, "RPX: decreased allowance below zero");

        unchecked {
            _approve(msg.sender, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    // -------------------------------------------------------------------------
    // Pre-launch owner controls
    // -------------------------------------------------------------------------

    /// @notice Seeds initial LP through the contract so the resulting LP tokens can be locked on-chain.
    function addInitialLiquidity(
        uint256 tokenAmount,
        uint256 amountTokenMin,
        uint256 amountBNBMin
    ) external payable onlyOwner beforeLaunch nonReentrant {
        require(tokenAmount > 0, "RPX: zero token amount");
        require(msg.value > 0, "RPX: zero BNB amount");

        uint256 ownerBalance = _balances[owner];
        require(ownerBalance >= tokenAmount, "RPX: insufficient balance");

        unchecked {
            _balances[owner] = ownerBalance - tokenAmount;
            _balances[address(this)] += tokenAmount;
        }

        emit Transfer(owner, address(this), tokenAmount);

        _approve(address(this), address(router), tokenAmount);

        (uint256 amountTokenUsed, uint256 amountBNBUsed, uint256 liquidity) = router.addLiquidityETH{value: msg.value}(
            address(this),
            tokenAmount,
            amountTokenMin,
            amountBNBMin,
            address(this),
            block.timestamp
        );

        uint256 refundTokens = tokenAmount - amountTokenUsed;
        if (refundTokens > 0) {
            unchecked {
                _balances[address(this)] -= refundTokens;
                _balances[owner] += refundTokens;
            }

            emit Transfer(address(this), owner, refundTokens);
        }

        if (msg.value > amountBNBUsed) {
            _sendBNB(owner, msg.value - amountBNBUsed);
        }

        emit InitialLiquidityAdded(amountTokenUsed, amountBNBUsed, liquidity);
    }

    /// @notice Enables public trading. After this point sensitive launch settings are frozen.
    function enableTrading() external onlyOwner beforeLaunch {
        require(IBEP20(pair).balanceOf(address(this)) > 0, "RPX: no locked LP");

        _clearLaunchExclusions();
        _setFeeExcluded(address(this), true);
        _setLimitExcluded(address(this), true);
        _setProtectionExcluded(address(this), true);
        if (!lpLockPermanent) {
            lpLockPermanent = true;
            emit LiquidityLockMadePermanent();
        }
        lpUnlockTime = type(uint256).max;
        tradingEnabled = true;
        launchBlock = block.number;

        emit TradingEnabled(block.number);
    }

    function setTaxes(uint256 newBuyTax, uint256 newSellTax, uint256 newTransferTax) external onlyOwner beforeLaunch {
        require(
            newBuyTax <= MAX_TAX_PERCENT &&
                newSellTax <= MAX_TAX_PERCENT &&
                newTransferTax <= MAX_TAX_PERCENT,
            "RPX: tax too high"
        );

        buyTax = newBuyTax;
        sellTax = newSellTax;
        transferTax = newTransferTax;

        emit TaxesUpdated(newBuyTax, newSellTax, newTransferTax);
    }

    function setTaxWallets(
        address newLiquidityWallet,
        address newMarketingWallet,
        address newDevelopmentWallet
    ) external onlyOwner beforeLaunch {
        _validateLiquidityWallet(newLiquidityWallet);
        _validateClaimWallet(newMarketingWallet);
        _validateClaimWallet(newDevelopmentWallet);

        liquidityWallet = newLiquidityWallet;
        marketingWallet = newMarketingWallet;
        developmentWallet = newDevelopmentWallet;

        emit TaxWalletsUpdated(newLiquidityWallet, newMarketingWallet, newDevelopmentWallet);
    }

    function setTaxShares(
        uint256 newLiquidityShare,
        uint256 newMarketingShare,
        uint256 newDevelopmentShare
    ) external onlyOwner beforeLaunch {
        require(
            newLiquidityShare + newMarketingShare + newDevelopmentShare == SHARE_DENOMINATOR,
            "RPX: invalid shares"
        );
        require(newMarketingShare + newDevelopmentShare > 0, "RPX: no claim share");

        liquidityShare = newLiquidityShare;
        marketingShare = newMarketingShare;
        developmentShare = newDevelopmentShare;

        emit TaxSharesUpdated(newLiquidityShare, newMarketingShare, newDevelopmentShare);
    }

    function setLimits(uint256 newMaxTxAmount, uint256 newMaxWalletAmount) external onlyOwner beforeLaunch {
        require(newMaxTxAmount > 0, "RPX: zero max tx");
        require(newMaxWalletAmount >= newMaxTxAmount, "RPX: wallet below tx");

        maxTxAmount = newMaxTxAmount;
        maxWalletAmount = newMaxWalletAmount;

        emit LimitsUpdated(newMaxTxAmount, newMaxWalletAmount);
    }

    function setSwapTokensAtAmount(uint256 newAmount) external onlyOwner beforeLaunch {
        require(newAmount > 0, "RPX: zero swap amount");
        require(newAmount <= maxTxAmount, "RPX: swap amount too high");

        swapTokensAtAmount = newAmount;
        emit SwapTokensAtAmountUpdated(newAmount);
    }

    function setSwapSlippageBps(uint256 newSlippageBps) external onlyOwner beforeLaunch {
        require(newSlippageBps <= MAX_SWAP_SLIPPAGE_BPS, "RPX: slippage too high");

        swapSlippageBps = newSlippageBps;
        emit SwapSlippageUpdated(newSlippageBps);
    }

    function setExcludedFromFees(address account, bool status) external onlyOwner beforeLaunch {
        require(account != address(0), "RPX: zero account");
        require(account != address(this), "RPX: system account");
        _setFeeExcluded(account, status);
    }

    function setExcludedFromLimits(address account, bool status) external onlyOwner beforeLaunch {
        require(account != address(0), "RPX: zero account");
        require(account != address(this), "RPX: system account");
        _setLimitExcluded(account, status);
    }

    function setExcludedFromProtection(address account, bool status) external onlyOwner beforeLaunch {
        require(account != address(0), "RPX: zero account");
        require(account != address(this), "RPX: system account");
        _setProtectionExcluded(account, status);
    }

    function setDeadBlocks(uint256 newDeadBlocks) external onlyOwner beforeLaunch {
        require(newDeadBlocks <= MAX_DEAD_BLOCKS, "RPX: dead blocks too high");

        deadBlocks = newDeadBlocks;
        emit DeadBlocksUpdated(newDeadBlocks);
    }

    function setCooldown(bool enabled, uint256 newCooldownTime) external onlyOwner beforeLaunch {
        require(newCooldownTime <= 1 hours, "RPX: cooldown too high");

        cooldownEnabled = enabled;
        cooldownTime = newCooldownTime;

        emit CooldownUpdated(enabled, newCooldownTime);
    }

    // -------------------------------------------------------------------------
    // LP lock and ownership
    // -------------------------------------------------------------------------

    function extendLiquidityLock(uint256 newUnlockTime) external onlyOwner beforeLaunch {
        require(!lpLockPermanent, "RPX: LP permanently locked");
        require(newUnlockTime > lpUnlockTime, "RPX: invalid unlock");

        lpUnlockTime = newUnlockTime;
        emit LiquidityLockExtended(newUnlockTime);
    }

    function lockLiquidityForever() external onlyOwner beforeLaunch {
        require(!lpLockPermanent, "RPX: LP permanently locked");
        lpLockPermanent = true;
        lpUnlockTime = type(uint256).max;

        emit LiquidityLockMadePermanent();
    }

    function unlockLiquidity() external onlyOwner afterLaunch nonReentrant {
        require(!lpLockPermanent, "RPX: LP permanently locked");
        require(block.timestamp >= lpUnlockTime, "RPX: LP locked");

        uint256 lpBalance = IBEP20(pair).balanceOf(address(this));
        require(lpBalance > 0, "RPX: no LP");
        require(IBEP20(pair).transfer(liquidityWallet, lpBalance), "RPX: LP transfer failed");

        emit LiquidityUnlocked(liquidityWallet, lpBalance);
    }

    function recoverUnlockedLP(address to, uint256 amount) external onlyOwner afterLaunch nonReentrant {
        require(to != address(0), "RPX: zero address");
        require(!lpLockPermanent, "RPX: LP permanently locked");
        require(block.timestamp >= lpUnlockTime, "RPX: LP locked");
        require(amount > 0, "RPX: zero amount");
        require(IBEP20(pair).balanceOf(address(this)) >= amount, "RPX: insufficient LP");
        require(IBEP20(pair).transfer(to, amount), "RPX: LP transfer failed");

        emit LiquidityRecovered(to, amount);
    }

    /// @notice Recovers non-RPX tokens sent to the contract by mistake.
    function rescueForeignToken(address token, address to, uint256 amount) external onlyOwner beforeLaunch nonReentrant {
        require(token != address(0) && to != address(0), "RPX: zero address");
        require(token != address(this), "RPX: cannot rescue RPX");
        require(token != pair, "RPX: use LP functions");
        require(amount > 0, "RPX: zero amount");
        require(IBEP20(token).balanceOf(address(this)) >= amount, "RPX: insufficient token");

        require(IBEP20(token).transfer(to, amount), "RPX: token rescue failed");
        emit ForeignTokenRescued(token, to, amount);
    }

    /// @notice Recovers BNB dust that may remain in the contract.
    function rescueBNB(address to, uint256 amount) external onlyOwner beforeLaunch nonReentrant {
        require(to != address(0), "RPX: zero address");
        require(amount > 0, "RPX: zero amount");
        require(address(this).balance >= amount, "RPX: insufficient BNB");

        _sendBNB(to, amount);
        emit BNBRescued(to, amount);
    }

    function claimMarketingBNB(address recipient) external nonReentrant {
        require(recipient == marketingWallet, "RPX: invalid recipient");
        _claimPendingBNB(recipient, pendingMarketingBNB, true);
    }

    function claimDevelopmentBNB(address recipient) external nonReentrant {
        require(recipient == developmentWallet, "RPX: invalid recipient");
        _claimPendingBNB(recipient, pendingDevelopmentBNB, false);
    }

    function processFees() external afterLaunch nonReentrant {
        require(!_inSwap, "RPX: swap in progress");

        uint256 contractTokenBalance = _balances[address(this)];
        require(contractTokenBalance > 0, "RPX: no tax tokens");
        require(contractTokenBalance >= swapTokensAtAmount || feeProcessingFailed, "RPX: below threshold");

        _processCollectedFees(msg.sender, contractTokenBalance);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        _validateOwnerCandidate(newOwner);
        require(newOwner != owner, "RPX: already owner");

        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        address cancelledPendingOwner = pendingOwner;
        require(cancelledPendingOwner != address(0), "RPX: no pending owner");

        pendingOwner = address(0);
        emit OwnershipTransferCancelled(owner, cancelledPendingOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "RPX: not pending owner");

        address previousOwner = owner;
        address newOwner = pendingOwner;

        if (!tradingEnabled) {
            _setFeeExcluded(previousOwner, false);
            _setLimitExcluded(previousOwner, false);
            _setProtectionExcluded(previousOwner, false);
            _setFeeExcluded(newOwner, true);
            _setLimitExcluded(newOwner, true);
            _setProtectionExcluded(newOwner, true);
        }

        owner = newOwner;
        pendingOwner = address(0);

        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /// @notice Permanently locks LP and renounces ownership after launch.
    function finalizeDecentralization() external onlyOwner afterLaunch {

        address previousOwner = owner;

        if (!lpLockPermanent) {
            lpLockPermanent = true;
            emit LiquidityLockMadePermanent();
        }
        lpUnlockTime = type(uint256).max;
        owner = address(0);
        pendingOwner = address(0);

        emit OwnershipTransferred(previousOwner, address(0));
        emit OwnershipRenounced(previousOwner);
        emit LaunchFinalized(previousOwner);
    }

    // -------------------------------------------------------------------------
    // Internal token logic
    // -------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0) && to != address(0), "RPX: zero address");

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "RPX: insufficient balance");

        if (from != owner && to != owner && from != address(this) && !tradingEnabled) {
            revert("RPX: trading disabled");
        }

        _enforceProtection(from, to);

        uint256 taxAmount = _calculateTax(from, to, amount);
        uint256 receivedAmount = amount - taxAmount;

        _enforceLimits(from, to, amount, receivedAmount);

        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += receivedAmount;
        }

        emit Transfer(from, to, receivedAmount);

        if (taxAmount > 0) {
            _balances[address(this)] += taxAmount;
            emit Transfer(from, address(this), taxAmount);
        }

        _maybeSwapAndLiquify(to);
    }

    function _approve(address account, address spender, uint256 amount) private {
        require(account != address(0) && spender != address(0), "RPX: zero address");

        _allowances[account][spender] = amount;
        emit Approval(account, spender, amount);
    }

    function _enforceProtection(address from, address to) private {
        if (_inSwap || isExcludedFromProtection[from] || isExcludedFromProtection[to]) {
            return;
        }

        if (from == pair) {
            if (launchBlock != 0 && block.number < launchBlock + deadBlocks) {
                revert("RPX: launch protection");
            }

            if (cooldownEnabled) {
                require(block.timestamp >= lastTransferTime[to] + cooldownTime, "RPX: cooldown");
                lastTransferTime[to] = block.timestamp;
            }

            lastBuyBlock[to] = block.number;
        }

        if (to == pair) {
            require(lastBuyBlock[from] != block.number, "RPX: same-block sell");
        }
    }

    function _calculateTax(address from, address to, uint256 amount) private view returns (uint256) {
        if (isExcludedFromFees[from] || isExcludedFromFees[to]) {
            return 0;
        }

        if (from == pair) {
            return (amount * buyTax) / PERCENT_DENOMINATOR;
        }

        if (to == pair) {
            return (amount * sellTax) / PERCENT_DENOMINATOR;
        }

        return (amount * transferTax) / PERCENT_DENOMINATOR;
    }

    function _enforceLimits(
        address from,
        address to,
        uint256 sentAmount,
        uint256 receivedAmount
    ) private view {
        if (isExcludedFromLimits[from] || isExcludedFromLimits[to]) {
            return;
        }

        require(sentAmount <= maxTxAmount, "RPX: tx limit");

        if (to != pair) {
            require(_balances[to] + receivedAmount <= maxWalletAmount, "RPX: wallet limit");
        }
    }

    function _maybeSwapAndLiquify(address to) private {
        uint256 contractTokenBalance = _balances[address(this)];

        if (_inSwap || to != pair || contractTokenBalance < swapTokensAtAmount) {
            return;
        }

        _processCollectedFees(msg.sender, contractTokenBalance);
    }

    /// @dev Converts collected tax tokens into LP, marketing BNB, and development BNB.
    function _swapAndLiquify(uint256 amount) private lockSwap {
        uint256 tokensForLiquidity = (amount * liquidityShare) / SHARE_DENOMINATOR;
        uint256 halfLiquidity = tokensForLiquidity / 2;
        uint256 tokensToSwap = amount - halfLiquidity;

        if (tokensToSwap == 0) {
            return;
        }

        uint256 receivedBNB = _swapTokensForBNB(tokensToSwap);
        if (receivedBNB == 0) {
            return;
        }

        (bool hadLiquidityFailure, uint256 liquidityTokenUsed, uint256 liquidityBNBUsed) =
            _addLiquidityPortion(halfLiquidity, tokensToSwap, receivedBNB);

        (uint256 bnbForMarketing, uint256 bnbForDevelopment) =
            _accruePendingBNB(receivedBNB - liquidityBNBUsed);

        emit FeeProcessingCompleted(amount, liquidityTokenUsed, liquidityBNBUsed, bnbForMarketing, bnbForDevelopment);

        if (!hadLiquidityFailure) {
            _clearFeeProcessingFailure();
        }
    }

    function _processCollectedFees(address caller, uint256 contractTokenBalance) private {
        uint256 amountToSwap = _selectSwapAmount(contractTokenBalance);
        emit FeeProcessingTriggered(caller, amountToSwap);
        _swapAndLiquify(amountToSwap);
    }

    function _sendBNB(address to, uint256 amount) private {
        if (amount == 0) {
            return;
        }

        (bool success, ) = payable(to).call{value: amount}("");
        require(success, "RPX: BNB transfer failed");
    }

    function _getMinimumSwapOutput(uint256 amountIn, address[] memory path) private view returns (uint256) {
        try router.getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            if (amounts.length == 0) {
                return 0;
            }

            uint256 quotedBNB = amounts[amounts.length - 1];
            if (quotedBNB == 0) {
                return 0;
            }

            return (quotedBNB * (SHARE_DENOMINATOR - swapSlippageBps)) / SHARE_DENOMINATOR;
        } catch {
            return 0;
        }
    }

    function _swapTokensForBNB(uint256 tokensToSwap) private returns (uint256 receivedBNB) {
        uint256 initialBNBBalance = address(this).balance;
        _approve(address(this), address(router), tokensToSwap);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WBNB;

        uint256 amountOutMin = _getMinimumSwapOutput(tokensToSwap, path);
        if (amountOutMin == 0) {
            _markFeeProcessingFailure(FEE_STEP_QUOTE);
            return 0;
        }

        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokensToSwap,
            amountOutMin,
            path,
            address(this),
            block.timestamp
        ) {} catch {
            _markFeeProcessingFailure(FEE_STEP_SWAP);
            return 0;
        }

        receivedBNB = address(this).balance - initialBNBBalance;
        if (receivedBNB == 0) {
            _markFeeProcessingFailure(FEE_STEP_SWAP);
        }
    }

    function _addLiquidityPortion(
        uint256 halfLiquidity,
        uint256 tokensToSwap,
        uint256 receivedBNB
    ) private returns (bool hadFailure, uint256 liquidityTokenUsed, uint256 liquidityBNBUsed) {
        uint256 bnbForLiquidity = (receivedBNB * halfLiquidity) / tokensToSwap;
        if (halfLiquidity == 0 || bnbForLiquidity == 0) {
            return (false, 0, 0);
        }

        _approve(address(this), address(router), halfLiquidity);

        try router.addLiquidityETH{value: bnbForLiquidity}(
            address(this),
            halfLiquidity,
            0,
            0,
            address(this),
            block.timestamp
        ) returns (uint256 amountTokenUsed, uint256 amountETHUsed, uint256) {
            return (false, amountTokenUsed, amountETHUsed);
        } catch {
            _markFeeProcessingFailure(FEE_STEP_LIQUIDITY);
            return (true, 0, 0);
        }
    }

    function _accruePendingBNB(uint256 remainingBNB) private returns (uint256 bnbForMarketing, uint256 bnbForDevelopment) {
        uint256 nonLiquidityShares = marketingShare + developmentShare;

        if (nonLiquidityShares > 0) {
            bnbForMarketing = (remainingBNB * marketingShare) / nonLiquidityShares;
        }

        bnbForDevelopment = remainingBNB - bnbForMarketing;

        if (bnbForMarketing > 0) {
            pendingMarketingBNB += bnbForMarketing;
        }

        if (bnbForDevelopment > 0) {
            pendingDevelopmentBNB += bnbForDevelopment;
        }

        if (bnbForMarketing > 0 || bnbForDevelopment > 0) {
            emit PendingBNBAccrued(bnbForMarketing, bnbForDevelopment);
        }
    }

    function _selectSwapAmount(uint256 contractTokenBalance) private view returns (uint256) {
        if (contractTokenBalance < swapTokensAtAmount) {
            return contractTokenBalance;
        }

        return swapTokensAtAmount;
    }

    function _setFeeExcluded(address account, bool status) private {
        isExcludedFromFees[account] = status;
        _syncLaunchAccount(account);
        emit FeeExclusionUpdated(account, status);
    }

    function _setLimitExcluded(address account, bool status) private {
        isExcludedFromLimits[account] = status;
        _syncLaunchAccount(account);
        emit LimitExclusionUpdated(account, status);
    }

    function _setProtectionExcluded(address account, bool status) private {
        isExcludedFromProtection[account] = status;
        _syncLaunchAccount(account);
        emit ProtectionExclusionUpdated(account, status);
    }

    function _clearLaunchExclusions() private {
        uint256 trackedLength = _trackedLaunchAccounts.length;

        for (uint256 i = 0; i < trackedLength; i++) {
            address account = _trackedLaunchAccounts[i];
            _isTrackedLaunchAccount[account] = false;

            if (account == address(this)) {
                continue;
            }

            if (isExcludedFromFees[account]) {
                isExcludedFromFees[account] = false;
                emit FeeExclusionUpdated(account, false);
            }

            if (isExcludedFromLimits[account]) {
                isExcludedFromLimits[account] = false;
                emit LimitExclusionUpdated(account, false);
            }

            if (isExcludedFromProtection[account]) {
                isExcludedFromProtection[account] = false;
                emit ProtectionExclusionUpdated(account, false);
            }
        }

        delete _trackedLaunchAccounts;
    }

    function _syncLaunchAccount(address account) private {
        bool shouldTrack =
            isExcludedFromFees[account] ||
            isExcludedFromLimits[account] ||
            isExcludedFromProtection[account];

        if (shouldTrack) {
            if (_isTrackedLaunchAccount[account]) {
                return;
            }

            require(_trackedLaunchAccounts.length < MAX_TRACKED_LAUNCH_ACCOUNTS, "RPX: too many launch accounts");
            _isTrackedLaunchAccount[account] = true;
            _trackedLaunchAccounts.push(account);
            return;
        }

        if (!_isTrackedLaunchAccount[account]) {
            return;
        }

        uint256 trackedLength = _trackedLaunchAccounts.length;
        uint256 lastIndex = trackedLength - 1;

        for (uint256 i = 0; i < trackedLength; i++) {
            if (_trackedLaunchAccounts[i] == account) {
                if (i != lastIndex) {
                    _trackedLaunchAccounts[i] = _trackedLaunchAccounts[lastIndex];
                }

                _trackedLaunchAccounts.pop();
                _isTrackedLaunchAccount[account] = false;
                return;
            }
        }
    }

    function _claimPendingBNB(address recipient, uint256 amount, bool isMarketingClaim) private {
        require(recipient != address(0), "RPX: zero recipient");
        require(amount > 0, "RPX: no BNB");

        if (isMarketingClaim) {
            pendingMarketingBNB = 0;
            emit PendingBNBClaimed(marketingWallet, recipient, amount);
        } else {
            pendingDevelopmentBNB = 0;
            emit PendingBNBClaimed(developmentWallet, recipient, amount);
        }

        _sendBNB(recipient, amount);
    }

    function _validateLiquidityWallet(address wallet) private view {
        require(wallet != address(0), "RPX: zero wallet");
        require(wallet != address(this) && wallet != pair && wallet != address(router), "RPX: invalid liquidity wallet");
    }

    function _validateClaimWallet(address wallet) private view {
        require(wallet != address(0), "RPX: zero wallet");
        require(wallet != address(this) && wallet != pair && wallet != address(router), "RPX: invalid claim wallet");
    }

    function _validateOwnerCandidate(address candidate) private view {
        require(candidate != address(0), "RPX: zero owner");
        require(candidate != address(this) && candidate != pair && candidate != address(router), "RPX: invalid owner");
    }

    function _markFeeProcessingFailure(uint8 step) private {
        feeProcessingFailed = true;
        lastFeeProcessingFailureBlock = block.number;
        lastFeeProcessingFailureStep = step;
        emit FeeProcessingFailureRecorded(step, block.number);
    }

    function _clearFeeProcessingFailure() private {
        if (!feeProcessingFailed) {
            return;
        }

        feeProcessingFailed = false;
        lastFeeProcessingFailureBlock = 0;
        lastFeeProcessingFailureStep = FEE_STEP_NONE;
        emit FeeProcessingRecovered();
    }
}