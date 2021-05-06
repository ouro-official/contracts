// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./library.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {ERC20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * We have followed general OpenZeppelin guidelines: functions revert instead
 * of returning `false` on failure. This behavior is nonetheless conventional
 * and does not conflict with the expectations of ERC20 applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IERC20-approve}.
 */
contract ERC20 is Context, IERC20 {
    using SafeMath for uint256;

    mapping (address => uint256) private _balances;
    mapping (address => mapping (address => uint256)) private _allowances;

    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 private _totalSupply;

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public override returns (bool) {
        require((allowance(_msgSender(), spender) == 0) || (amount == 0), "ERC20: change allowance use increaseAllowance or decreaseAllowance instead");
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    /**
     * @dev Moves tokens `amount` from `sender` to `recipient`.
     *
     * This is internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(sender, recipient, amount);

        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        _balances[account] = _balances[account].sub(amount, "ERC20: burn amount exceeds balance");
        _totalSupply = _totalSupply.sub(amount);
        emit Transfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be to transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual { }
}

/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
contract Pausable is Context {
    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    bool private _paused;

    /**
     * @dev Initializes the contract in unpaused state.
     */
    constructor () internal {
        _paused = false;
    }

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view returns (bool) {
        return _paused;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        require(!_paused, "Pausable: paused");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        require(_paused, "Pausable: not paused");
        _;
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() internal whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() internal whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }
}

/**
 * @notice OURO token contract (ERC20)
 */
contract OURToken is ERC20, Pausable, Ownable, IOUROToken {
    using SafeERC20 for IERC20;
    using SafeMath for uint;
    using Address for address payable;
    using SafeMath for uint256;
    using SafeERC20 for IOUROToken;
    using SafeERC20 for IOGSToken;

   /**
     * @dev Emitted when an account is set mintable
     */
    event Mintable(address account);
    /**
     * @dev Emitted when an account is set unmintable
     */
    event Unmintable(address account);
    
    // @dev mintable group
    mapping(address => bool) public mintableGroup;
    
    modifier onlyMintableGroup() {
        require(mintableGroup[msg.sender], "OURO: not in mintable group");
        _;
    }
        
    // @dev ouro dynamcis's address
    address public ouroDynamicAddress;
    
    modifier onlyOURODynamic() {
        require (msg.sender == ouroDynamicAddress, "OURO: access denied");
        _;
    }

    mapping(address => TimeLock) private _timelock;

    event BlockTransfer(address indexed account);
    event AllowTransfer(address indexed account);

    struct TimeLock {
        uint256 releaseTime;
        uint256 amount;
    }

    /**
     * @dev Initialize the contract give all tokens to the deployer
     */
    constructor(string memory _name, string memory _symbol, uint8 _decimals, uint256 _initialSupply) public {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        setMintable(owner(), true);
        _mint(_msgSender(), _initialSupply * (10 ** uint256(_decimals)));
    }
    
    /**
     * @dev set or remove address to mintable group
     */
    function setMintable(address account, bool allow) public onlyOwner {
        mintableGroup[account] = allow;
        if (allow) {
            emit Mintable(account);
        }  else {
            emit Unmintable(account);
        }
    }
    
    /**
     * @dev acquire native token, ONLY buy ouro stablizer(dynamics).
     */
    function acquireNative(uint256 amount) override external onlyOURODynamic {
        payable(ouroDynamicAddress).sendValue(amount);
    }
    
    /** 
     * @dev get system defined OURO price
     */
    function getPrice() external override returns(uint256) {
        return ouroPrice;
        
    }
    
    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     */
    function mint(address account, uint256 amount) public override onlyMintableGroup {
        _mint(account, amount);
        
    }
    /**
     * @dev Destroys `amount` tokens from the caller.
     *
     * See {ERC20-_burn}.
     */
    function burn(uint256 amount) public override {
        _burn(_msgSender(), amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, deducting from the caller's
     * allowance.
     *
     * See {ERC20-_burn} and {ERC20-allowance}.
     *
     * Requirements:
     *
     * - the caller must have allowance for ``accounts``'s tokens of at least
     * `amount`.
     */
    function burnFrom(address account, uint256 amount) public {
        uint256 decreasedAllowance = allowance(account, _msgSender()).sub(amount, "OURO: burn amount exceeds allowance");

        _approve(account, _msgSender(), decreasedAllowance);
        _burn(account, amount);
    }


    /**
     * @dev View `account` locked information
     */
    function timelockOf(address account) public view returns(uint256 releaseTime, uint256 amount) {
        TimeLock memory timelock = _timelock[account];
        return (timelock.releaseTime, timelock.amount);
    }

    /**
     * @dev Release the specified `amount` of locked amount
     * @notice only Owner call
     */
    function release(address account, uint256 releaseAmount) public onlyOwner {
        require(account != address(0), "EHC: release zero address");

        TimeLock storage timelock = _timelock[account];
        timelock.amount = timelock.amount.sub(releaseAmount);
        if(timelock.amount == 0) {
            timelock.releaseTime = 0;
        }
    }

    /**
     * @dev Triggers stopped state.
     * @notice only Owner call
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @dev Returns to normal state.
     * @notice only Owner call
     */
    function unpause() public onlyOwner {
        _unpause();
    }
    
    /**
     * @dev transfer with lock 
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     * - releaseTime.
     */
    function transferWithLock(address recipient, uint256 amount, uint256 releaseTime) public onlyOwner returns (bool) {
        require(recipient != address(0), "OURO: lockup zero address");
        require(releaseTime > block.timestamp, "OURO: release time before lock time");
        require(_timelock[recipient].releaseTime == 0, "OURO: already locked");

        TimeLock memory timelock = TimeLock({
            releaseTime : releaseTime,
            amount      : amount
        });
        _timelock[recipient] = timelock;
        
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev Batch transfer amount to recipient
     * @notice that excessive gas consumption causes transaction revert
     */
    function batchTransfer(address[] memory recipients, uint256[] memory amounts) public {
        require(recipients.length > 0, "OURO: least one recipient address");
        require(recipients.length == amounts.length, "OURO: number of recipient addresses does not match the number of tokens");

        for(uint256 i = 0; i < recipients.length; ++i) {
            _transfer(_msgSender(), recipients[i], amounts[i]);
        }
    }

    /**
     * @dev See {ERC20-_beforeTokenTransfer}.
     *
     * Requirements:
     *
     * - the contract must not be paused.
     * - accounts must not trigger the locked `amount` during the locked period.
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        require(!paused(), "OURO: token transfer while paused");

        // Check whether the locked amount is triggered
        TimeLock storage timelock = _timelock[from];
        if(timelock.releaseTime != 0 && balanceOf(from).sub(amount) < timelock.amount) {
            require(block.timestamp >= timelock.releaseTime, "OURO: current time is before from account release time");

            // Update the locked `amount` if the current time reaches the release time
            timelock.amount = balanceOf(from).sub(amount);
            if(timelock.amount == 0) {
                timelock.releaseTime = 0;
            }
        }

        super._beforeTokenTransfer(from, to, amount);
    }
    
    
    
    /**
     * ======================================================================================
     * 
     * @dev OURO's deposit & withdraw
     * 
     * ======================================================================================
     */
     
    IOUROToken public ouroContract = IOUROToken(0xEe5bCf20a21e0539Da126d8c86531E7BeE25933F);
    IOGSToken public ogsContract = IOGSToken(0xEe5bCf20a21e0539Da126d8c86531E7BeE25933F);
    IERC20 public usdtContract = IERC20(0x55d398326f99059fF775485246999027B3197955);

    uint256 public OURO_PRICE_UNIT = 1e18;
    
    IPancakeRouter02 public router = IPancakeRouter02(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    uint256 constant internal MAX_UINT256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    bool public ouroApprovedToRouter;
    
    // @dev ouro price 
    uint256 public ouroPrice;

    /**
     * @dev user deposit assets and receive OURO
     * @notice for ERC20 tokens, user needs approve to this contract first
     */
    function deposit(IERC20 token, uint256 amount) external payable {
        // lookup asset price
        bool valid;
        CollateralInfo memory collateral;
        for (uint i=0;i<collaterals.length;i++) {
            collateral = collaterals[i];
            if (collateral.token == token ){
                valid = true;
                break;
            }
        }
        require(valid, "not in the collateral set");

        uint256 ouroToMint;
        if (address(token) == router.WETH()) {
            // for native token, check msg.value only
            require(msg.value > 0, "0 deposit");
            amount = 0;
            
            // lookup asset price
            uint256 unitPrice = getAssetPrice(collateral.priceFeed);
            
            // convert to OURO equivalent
            ouroToMint = unitPrice.mul(msg.value)
                                            .div(collateral.priceUnit)
                                            .div(ouroPrice);
        } else {
            // transfer from user's balance
            token.safeTransferFrom(msg.sender, address(this), amount);
            
            // lookup asset price
            uint256 unitPrice = getAssetPrice(collateral.priceFeed);
            
            // convert to OURO equivalent
            ouroToMint = unitPrice.mul(amount)
                                            .div(collateral.priceUnit)
                                            .div(ouroPrice);

        }
                                        
        // mint to sender
        _mint(msg.sender, ouroToMint);
    }
    
    /**
     * @dev user swap his OURO to assets
     */
    function withdraw(IERC20 token, uint256 amountAsset) external payable {
        // lookup asset price
        bool valid;
        CollateralInfo memory collateral;
        for (uint i=0;i<collaterals.length;i++) {
            collateral = collaterals[i];
            if (collateral.token == token ){
                valid = true;
                break;
            }
        }
        require(valid, "not in the collateral set");

        // lookup asset value in USDT
        uint256 assetValueInUSDT = amountAsset
                                                    .mul(getAssetPrice(collateral.priceFeed))
                                                    .div(collateral.priceUnit);
        // asset value in OURO
        uint256 assetValueInOuro = assetValueInUSDT.mul(OURO_PRICE_UNIT)
                                                    .div(ouroPrice);
                                                    
        
        // make sure user have enough OURO
        require (balanceOf(msg.sender) >= assetValueInOuro, "not enough OURO");
                                        
        // check if we have insufficient assets to return to user
        uint256 balance = token.balanceOf(address(this));
        if (balance < amountAsset) {
            // buy from swaps
            uint256 assetsToBuy = amountAsset.sub(balance);
            
            // find how many OUROs required to swap assets out
            address[] memory path = new address[](2);
            path[0] = address(this);
            path[1] = address(token);
            
            // calc amount OGS required to swap out given collateral
            uint [] memory amounts = router.getAmountsIn(assetsToBuy, path);
            uint256 ouroRequired = amounts[0];
            
            // make sure user have enough OURO to buy assets
            require (balanceOf(msg.sender) >= assetValueInOuro, "not enough OURO to buy back"); 
            
            // make sure we approved OGS to router
            if (!ogsApprovedToRouter) {
                ogsContract.approve(address(router), MAX_UINT256);
                ogsApprovedToRouter = true;
            }
            
            // buy assets back to this contract
            if (address(token) == router.WETH()) {
                router.swapTokensForExactETH(assetsToBuy, ouroRequired, path, address(this), block.timestamp);
            } else {
                // swap out tokens out to OURO contract
                router.swapTokensForExactTokens(assetsToBuy, ouroRequired, path, address(this), block.timestamp);
            }
        }
                                        
        // burn OURO
        _burn(msg.sender, assetValueInOuro);
        
        // transfer back assets
        token.safeTransfer(msg.sender, amountAsset);
    }




    /**
     * ======================================================================================
     * 
     * @dev OURO's stablizer
     *
     * ======================================================================================
     */
     
    // 1. The system will only mint new OGS and sell them for collateral when the value of the 
    //    assets held in the pool is more than 3% less than the value of the issued OURO.
    // 2. The system will only use excess collateral in the pool to conduct OGS buy back and 
    //    burn when the value of the assets held in the pool is 3% higher than the value of the issued OURO
    uint public threshold = 3;
    
    // CollateralInfo
    struct CollateralInfo {
        IERC20 token;
        uint256 priceUnit; // usually 1e18
        AggregatorV3Interface priceFeed; // asset price feed for xxx/USDT
        bool approvedToRouter;
    }
    
    // registered collaterals for OURO
    CollateralInfo [] public collaterals;
    
    // mark OGS approved to router
    bool public ogsApprovedToRouter;
    
    /**
     * @dev update is the stability dynamic for ouro
     */
    function update() external {
        
        // get total collateral value(USDT)
        uint256 totalCollateralValue;
        for (uint i=0;i<collaterals.length;i++) {
            CollateralInfo storage collateral = collaterals[i];
            
            if (address(collateral.token) == router.WETH()) {
                // native assets, such as:
                // ETH on ethereum , BNB on binance smart chain
                totalCollateralValue += getAssetPrice(collateral.priceFeed)
                                        .mul(address(ouroContract).balance)
                                        .div(collateral.priceUnit);
            } else {
                // ERC20 assets (tokens)
                totalCollateralValue += getAssetPrice(collateral.priceFeed)
                                        .mul(collateral.token.balanceOf(address(ouroContract)))
                                        .div(collateral.priceUnit);
            }
        }
        
        // get total OURO value(USDT)
        uint256 totalOUROValue = ouroContract.totalSupply()
                                        .mul(ouroContract.getPrice())
                                        .div(OURO_PRICE_UNIT);
        
        // compute values diff
        uint256 valueDiff;
        bool buyOGS;
        if (totalCollateralValue >= totalOUROValue.mul(100+threshold).div(100)) {
            // collaterals has excessive value to OURO value, 
            // 70% of the extra collateral would be used to BUY BACK OGS on secondary markets 
            // and conduct a token burn
            valueDiff = totalCollateralValue.sub(totalOUROValue)
                                                        .mul(70).div(100);
            buyOGS = true;
            
        } else if (totalCollateralValue <= totalOUROValue.mul(100-threshold).div(100)) {
            // collaterals has less value to OURO value, mint new OGS to buy assets
            valueDiff = totalOUROValue.sub(totalCollateralValue);
        }
        
        // if no value diff found, return here, nothing should happen!
        if (valueDiff == 0 ){
            return;
        }
        
        // buyback operations in pro-rata basis
        for (uint i=0;i<collaterals.length;i++) {
            CollateralInfo storage collateral = collaterals[i];
            
            uint256 slotValue;
            if (address(collateral.token) == router.WETH()) {
                slotValue = getAssetPrice(collateral.priceFeed)
                                        .mul(address(ouroContract).balance)
                                        .div(collateral.priceUnit);
                                    
            } else {
                slotValue = getAssetPrice(collateral.priceFeed)
                                        .mul(collateral.token.balanceOf(address(ouroContract)))
                                        .div(collateral.priceUnit);
            }
            
            // calc pro-rata buy back value(in USDT) for this collateral
            uint256 slotBuyBackValue = slotValue.mul(valueDiff)
                                        .div(totalCollateralValue);
                                
            // execute buyback
            if (buyOGS) {
                buybackOGSWithCollateral(collateral, slotBuyBackValue);
            } else {
                buybackCollateralWithOGS(collateral, slotBuyBackValue);
            }
        }
    }
    
    /**
     * @dev buy back OGS with collateral
     */
    function buybackOGSWithCollateral(CollateralInfo storage collateral, uint256 slotValue) internal {
        uint256 collateralToBuyOGS = slotValue
                                        .mul(collateral.priceUnit)
                                        .div(getAssetPrice(collateral.priceFeed));

        // the path to swap OGS out
        address[] memory path = new address[](2);
        path[0] = address(collateral.token);
        path[1] = address(ogsContract);
        
        // calc amount OGS that could be swapped out with given collateral
        uint [] memory amounts = router.getAmountsOut(collateralToBuyOGS, path);
        uint256 ogsAmountOut = amounts[1];
        
        if (address(collateral.token) == router.WETH()) {
            // for native assets, call ouro contract to transfer ETH, BNB to THIS contract
            ouroContract.acquireNative(collateralToBuyOGS);

            // swap OGS out with native assets to THIS contract
            payable(address(router)).functionCallWithValue(
                abi.encodeWithSelector(router.swapExactETHForTokens.selector, ogsAmountOut, path, address(this), block.timestamp),
                collateralToBuyOGS
            );
            
        } else {
            // for ERC20 assets, transfer the tokens from ouro contract to THIS contract
            // NOTE: ouroContract contract MUST authorized THIS contract the right to transfer assets
            collateral.token.safeTransferFrom(address(ouroContract), address(this), collateralToBuyOGS);
            
            // make sure we approved token to router
            if (!collateral.approvedToRouter) {
                collateral.token.approve(address(router), MAX_UINT256);
                collateral.approvedToRouter = true;
            }
            
            // swap OGS out to THIS contract
            router.swapExactTokensForTokens(collateralToBuyOGS, ogsAmountOut, path, address(this), block.timestamp);
        }

        // burn OGS
        ogsContract.burn(ogsAmountOut);
    }
    
    /**
     * @dev buy back collateral with OGS
     */
    function buybackCollateralWithOGS(CollateralInfo storage collateral, uint256 slotValue) internal {
        uint256 collateralToBuyBack = slotValue
                                        .mul(collateral.priceUnit)
                                        .div(getAssetPrice(collateral.priceFeed));
                                             
        // the path to swap collateral out
        address[] memory path = new address[](2);
        path[0] = address(ogsContract);
        path[1] = address(collateral.token);
        
        // calc amount OGS required to swap out given collateral
        uint [] memory amounts = router.getAmountsIn(collateralToBuyBack, path);
        uint256 ogsRequired = amounts[0];
                    
        // mint OGS to this contract to buy back collateral           
        // NOTE: ogs contract MUST authorized THIS contract the right to mint
        ogsContract.mint(address(this), ogsRequired);
        
        // make sure we approved OGS to router
        if (!ogsApprovedToRouter) {
            ogsContract.approve(address(router), MAX_UINT256);
            ogsApprovedToRouter = true;
        }

        if (address(collateral.token) == router.WETH()) {
            // swap out native assets ETH, BNB with OGS to OURO contract
            router.swapTokensForExactETH(ogsRequired, collateralToBuyBack, path, address(ouroContract), block.timestamp);

        } else {
            // swap out tokens out to OURO contract
            router.swapTokensForExactTokens(ogsRequired, collateralToBuyBack, path, address(ouroContract), block.timestamp);
        }
    }
    
    /**
     * @dev get asset price for 1 price unit
     * @notice DO NOT div by ASSET PRICE HERE
     */
    function getAssetPrice(AggregatorV3Interface feed) public view returns(uint256) {
        (, int latestPrice, , , ) = feed.latestRoundData();

        if (latestPrice > 0) {
            return uint(latestPrice);
        }
        return 0;
    }
}
