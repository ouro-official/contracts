// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./library.sol";

/**
 * @title OURO community reserve
 */
contract OUROReserve is IOUROReserve,Ownable,ReentrancyGuard,Pausable {
    using SafeERC20 for IERC20;
    using SafeMath for uint;
    using Address for address payable;
    using SafeMath for uint256;
    using SafeERC20 for IOUROToken;
    using SafeERC20 for IOGSToken;
    
    /** 
     * ======================================================================================
     * 
     * SHARED SETTINGS
     * 
     * ======================================================================================
     */

    // @dev ouro price 
    uint256 public ouroPrice = 1e18; // current ouro price, initially 1 OURO = 1 USD
    uint256 public ouroPriceAtMonthStart = 1e18; // ouro price at the begining of a month, initially set to 1 USD
    uint256 public constant OURO_PRICE_UNIT = 1e18; // 1 OURO = 1e18
    uint public ouroLastPriceUpdate = block.timestamp; 
    uint public ouroPriceResetPeriod = 30 days; // price limit reset mothly
    uint public ouroIssuePeriod = 30 days; // ouro issuance limit
    uint public appreciationLimit = 3; // 3% monthly OURO price appreciation limit

    // contracts
    address public constant busdContract = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    IOUROToken public constant ouroContract = IOUROToken(0x0a4FC79921f960A4264717FeFEE518E088173a79);
    IOGSToken public constant ogsContract = IOGSToken(0x416947e6Fc78F158fd9B775fA846B72d768879c2);
    IOURODist public ouroDistContact = IOURODist(0x15a59d5f5847df9f6c24272096E967fa10ffb18a);
    address public constant unitroller = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address public constant xvsAddress = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
    IPancakeRouter02 public constant router = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address public lastResortFund;
    
    address immutable internal WBNB = router.WETH();
    uint256 constant internal USD_UNIT = 1e18;
    uint256 constant internal MAX_UINT256 = uint256(-1);
    
    // @dev montly OURO issuance schedule in 100k(1e5) OURO
    uint16 [] public issueSchedule = [1,10,30,50,70,100,150,200,300,400,500,650,800];
    uint256 internal constant issueUnit = 1e5 * OURO_PRICE_UNIT;
    
    // @dev scheduled issue from
    uint256 public immutable issueFrom = block.timestamp;
    
    // a struct to store collateral asset info
    struct CollateralInfo {
        address token;
        address vTokenAddress;
        uint256 assetUnit; // usually 1e18
        uint256 lastPrice; // record latest collateral price
        AggregatorV3Interface priceFeed; // asset price feed for xxx/USDT
    }
    
    // all registered collaterals for OURO
    CollateralInfo [] private collaterals;
    
    // a mapping to track the balance of assets;
    mapping (address => uint256) private _assetsBalance;
    
    // whitelist for deposit assets 
    bool public whiteListEnabled;
    mapping (address => bool) private _whitelist;
    
    /**
     * ======================================================================================
     * 
     * VIEW FUNCTIONS
     * 
     * ======================================================================================
     */
     
    /**
     * @dev get specific collateral balance
     */
    function getAssetBalance(address token) external override view returns(uint256) { return _assetsBalance[token]; }
    
    /**
     * @dev get specific collateral info
     */
    function getCollateral(address token) external override view returns (
        address vTokenAddress,
        uint256 assetUnit, // usually 1e18
        uint256 lastPrice, // record latest collateral price
        AggregatorV3Interface priceFeed // asset price feed for xxx/USDT
    ) {
        (CollateralInfo memory collateral, bool valid) = _findCollateral(token);
        if (valid) {
            return (
                collateral.vTokenAddress,
                collateral.assetUnit,
                collateral.lastPrice,
                collateral.priceFeed
            );
        }
    }

    /** 
     * @dev get system defined OURO price
     */
    function getPrice() public view override returns(uint256) { return ouroPrice; }
    
    /**
     * @dev get asset price in USDT for 1 unit of asset
     */
    function getAssetPrice(AggregatorV3Interface feed) public override view returns(uint256) {
        // query price from chainlink
        (, int latestPrice, , , ) = feed.latestRoundData();

        // avert negative price
        _require(latestPrice > 0);
        
        // return price corrected to USD decimal
        // always align the price to USD decimal, which is 1e18 on BSC and 1e6 on Ethereum
        return uint256(latestPrice)
                        .mul(USD_UNIT)
                        .div(10**uint256(feed.decimals()));
    }

    /**
     * @dev returns OURO required to swap given assets out
     */
    function getOuroIn(uint256 amount, address token) external override view returns(uint256) {
        (CollateralInfo memory collateral, bool valid) = _findCollateral(token);
        _require(valid);
        return _lookupAssetValueInOURO(collateral.priceFeed, collateral.assetUnit, amount);
    }

    /**
     * @dev returns assets required to mint given amount of OURO out
     */
    function getAssetsIn(uint256 amountOURO, address token) external override view returns(uint256) {
        (CollateralInfo memory collateral, bool valid) = _findCollateral(token);
        _require(valid);

        // ouro USD value
        uint256 ouroValue = amountOURO
                            .mul(ouroPrice)
                            .div(OURO_PRICE_UNIT);

        // get 1 unit(collateral.assetUnit) asset value in USD 
        uint256 assetUnitPrice = getAssetPrice(collateral.priceFeed);

        // assets required
        return ouroValue
                            .mul(collateral.assetUnit)
                            .div(assetUnitPrice);
    }
    
     /**
     * ======================================================================================
     * 
     * SYSTEM FUNCTIONS
     * 
     * ======================================================================================
     */
     
    receive() external payable {}
    
    // code size cheaper version of require
    function _require(bool condition, string memory text) private pure {
        require (condition, text);
    }
    
    function _require(bool condition) private pure {
        require (condition);
    }

    modifier checkWhiteList() {
        if (whiteListEnabled) {
            _require(_whitelist[msg.sender]);
        }        
        _;
    }
    
    constructor() public {
        lastResortFund = msg.sender;
        // approve xvs to router
        IERC20(xvsAddress).safeApprove(address(router), MAX_UINT256);
        // approve ogs to router
        IERC20(ogsContract).safeApprove(address(router), MAX_UINT256);
        // approve ouro to router
        IERC20(ouroContract).safeApprove(address(router), MAX_UINT256);
    }
    
    /**
     * @dev set fund of last resort address
     */
    function setLastResortFund(address account) external onlyOwner {
        _require(account != address(0));
        lastResortFund = account;
        emit LastResortFundSet(account);
    }

    /**
     * @dev adjust OGS buy back ratio
     */
    function setOGSBuyBackRatio(uint ratio) external onlyOwner {
        _require(ratio >= 0 && ratio <= 100);
        OGSbuyBackRatio = ratio;
        emit OGSbuyBackRatioSet(ratio);
    }

    /**
     * @dev adjust rebase period
     */
    function setRebasePeriod(uint period) external onlyOwner {
        _require(period >= 1 hours && period <= 24 hours);
        rebasePeriod = period;
        emit RebasePeriodSet(period);
    }

    /**
     * @dev owner add new collateral
     */
    function newCollateral(
        address token, 
        address vTokenAddress,
        uint8 assetDecimal,
        AggregatorV3Interface priceFeed
        ) external onlyOwner
    {
        (, bool exist) = _findCollateral(token);
        _require(!exist);
        if (address(token) != WBNB) {
            _require(IVToken(vTokenAddress).underlying() == token, "vtoken");
        }

        uint256 currentPrice = getAssetPrice(priceFeed);
        
        // create collateral info 
        CollateralInfo memory info;
        info.token = token;
        info.vTokenAddress = vTokenAddress;
        info.assetUnit = 10 ** uint256(assetDecimal);
        info.lastPrice = currentPrice;
        info.priceFeed = priceFeed;

        collaterals.push(info);
        
        // approve ERC20 collateral to swap router & vToken
        if (address(token) != WBNB) {
            IERC20(token).safeApprove(address(router), 0);
            IERC20(token).safeIncreaseAllowance(address(router), MAX_UINT256);
            
            IERC20(token).safeApprove(vTokenAddress, 0);
            IERC20(token).safeIncreaseAllowance(vTokenAddress, MAX_UINT256);
        }
        
        // enter markets
        address[] memory venusMarkets = new address[](1);
        venusMarkets[0] = vTokenAddress;
        IVenusDistribution(unitroller).enterMarkets(venusMarkets);

        // log
        emit NewCollateral(token);
    }
    
    /**
     * @dev owner remove collateral
     */
    function removeCollateral(address token) external onlyOwner {
        uint n = collaterals.length;
        for (uint i=0;i<n;i++) {
            if (collaterals[i].token == token){
                
                // found! revoke router & vToken allowance to 0
                if (address(token) != WBNB) {
                    IERC20(token).safeApprove(address(router), 0);
                    IERC20(token).safeApprove(collaterals[i].vTokenAddress, 0);
                }
                
                // exit venus markets
                IVenusDistribution(unitroller).exitMarket(collaterals[i].vTokenAddress);
                
                // copy the last element [n-1] to [i],
                collaterals[i] = collaterals[n-1];
                // and pop out the last element
                collaterals.pop();
                
                // log
                emit RemoveCollateral(token);
                
                return;
            }
        } 
        
        revert("nonexistent");
    }
    
    /**
     * @dev owner reset allowance to maximum
     * to avert uint256 exhausting
     */
    function resetAllowances() external onlyOwner {
        uint n = collaterals.length;
        for (uint i=0;i<n;i++) {
            IERC20 token = IERC20(collaterals[i].token);
            if (address(token) != WBNB) {
                // re-approve asset to venus
                token.safeApprove(address(router), 0);
                token.safeIncreaseAllowance(address(router), MAX_UINT256);
                
                token.safeApprove(collaterals[i].vTokenAddress, 0);
                token.safeIncreaseAllowance(collaterals[i].vTokenAddress, MAX_UINT256);
            }
        }
        
        // re-approve xvs to router
        IERC20(xvsAddress).safeApprove(address(router), 0);
        IERC20(xvsAddress).safeIncreaseAllowance(address(router), MAX_UINT256);
        
        // re-approve ogs to router
        IERC20(ogsContract).safeApprove(address(router), 0);
        IERC20(ogsContract).safeIncreaseAllowance(address(router), MAX_UINT256);
        
        // re-approve ouro to router
        IERC20(ouroContract).safeApprove(address(router), 0);
        IERC20(ouroContract).safeIncreaseAllowance(address(router), MAX_UINT256);
        
        // log
        emit AllowanceReset();
    }
         
     /**
      * @dev change ouro revenue distribution contract address
      * in case of severe bug
      */
     function changeOURODist(address newContract) external onlyOwner {
         _require (IOURODist(newContract).isDist());
         ouroDistContact = IOURODist(newContract);
         
         emit OuroDistChanged(newContract);
     }
    
    /**
     * @dev toggle deposit whitelist enabled
     */
    function toggleWhiteList() external onlyOwner {
        whiteListEnabled = whiteListEnabled?false:true;
        
        emit WhiteListToggled(whiteListEnabled);
    }
    
    /**
     * @dev set to whiteist
     */
    function setToWhiteList(address account, bool allow) external onlyOwner {
        _whitelist[account] = allow;
        
        emit WhiteListSet(account, allow);
    }

    /**
     * @dev emergency withdraw the vTokens, only when severe contract vulnerability found.
     */
    function emergencyWithdraw(address to) external onlyOwner {
        uint n = collaterals.length;
        for (uint i=0;i<n;i++) {            
            // withdraw all tokens
            uint256 amount = IERC20(collaterals[i].vTokenAddress).balanceOf(address(this));
            if (amount > 0) {
                IERC20(collaterals[i].vTokenAddress).safeTransfer(to, amount);
            }
        }

        // log
        emit EmergencyWithdraw(msg.sender, to);
    }
    
    /**
     * @dev called by the owner to pause, triggers stopped state
     **/
    function pause() onlyOwner external { _pause(); }

    /**
    * @dev called by the owner to unpause, returns to normal state
    */
    function unpause() onlyOwner external { _unpause(); }
    
    /**
     * ======================================================================================
     * 
     * OURO's collateral deposit & withdraw
     *
     * ======================================================================================
     */
    /**
     * @dev user deposit assets and receive OURO
     * @notice users need approve() assets to this contract
     * returns OURO minted
     * the minimum amount of OURO willing to receive is given as minAmountOuro.
     */
    function deposit(address token, uint256 amountAsset, uint256 minAmountOuro) 
        external 
        override 
        payable 
        checkWhiteList 
        nonReentrant 
        whenNotPaused 
        returns (uint256 OUROMinted) {

        // ouro balance of user BEFORE deposit
        uint256 amountOuroMinted = IERC20(ouroContract).balanceOf(msg.sender);

        // deposit
        _deposit(token, amountAsset); 

        // diff of ouro balance of user AFTER deposit
        amountOuroMinted = IERC20(ouroContract).balanceOf(msg.sender).sub(amountOuroMinted);

        _require(amountOuroMinted >= minAmountOuro);

        return amountOuroMinted;
    }

    function _deposit(address token, uint256 amountAsset) private {
        // locate collateral
        (CollateralInfo memory collateral, bool valid) = _findCollateral(token);
        _require(valid);

        // for native token, replace amountAsset with use msg.value instead
        if (token == WBNB) {
            amountAsset = msg.value;
        }
        
        // non-0 deposit check
        _require(amountAsset > 0);

        // get equivalent OURO value
        uint256 assetValueInOuro = _lookupAssetValueInOURO(collateral.priceFeed, collateral.assetUnit, amountAsset);
        
        // check periodical OURO issuance limit
        uint periodN = block.timestamp.sub(issueFrom).div(ouroIssuePeriod);
        if (periodN < issueSchedule.length) { // still in control
            _require(assetValueInOuro.add(IERC20(ouroContract).totalSupply()) 
                        <=
                    uint256(issueSchedule[periodN]).mul(issueUnit),
                    "limited"
            );
        }
        
        // transfer token assets to this contract
        // @notice for ERC20 assets, users need to approve() to this reserve contract 
        if (token != WBNB) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amountAsset);
        }
                                        
        // mint OURO to sender
        IOUROToken(ouroContract).mint(msg.sender, assetValueInOuro);
        
        // update asset balance
        _assetsBalance[token] = _assetsBalance[token].add(amountAsset);

        // finally we farm the assets received
        _supply(collateral.token, collateral.vTokenAddress, amountAsset);
        
        // log
        emit Deposit(msg.sender, assetValueInOuro);
    }
    
    /**
     * @dev farm the user's deposit
     */
    function _supply(address token, address vTokenAddress, uint256 amountAsset) internal {
        if (token == WBNB) {
            IVBNB(vTokenAddress).mint{value: amountAsset}();
        } else {
            IVToken(vTokenAddress).mint(amountAsset);
        }
    }
    
    /**
     * @dev user swap his OURO back to assets
     * @notice users need approve() OURO assets to this contract
     * the max amount of OURO willing to swap in is given by maxAmountOuro
     */
    function withdraw(address token, uint256 amountAsset, uint256 maxAmountOuro) external override nonReentrant returns (uint256 OUROTaken) {
        // ouro balance of user BEFORE deposit
        uint256 amountOuroTaken = IERC20(ouroContract).balanceOf(msg.sender);

        // withdraw
        _withdraw(token, amountAsset); 

        // diff of ouro balance of user AFTER withdraw
        amountOuroTaken = amountOuroTaken.sub(IERC20(ouroContract).balanceOf(msg.sender));

        _require(amountOuroTaken <= maxAmountOuro);

        return amountOuroTaken;
    }

    function _withdraw(address token, uint256 amountAsset) private { 
        // non 0 check
        _require(amountAsset > 0);
        _require(_assetsBalance[token] > 0);
        
        // locate collateral
        (CollateralInfo memory collateral, bool valid) = _findCollateral(token);
        _require(valid);

        // CAP amountAsset to maximum available
        amountAsset = amountAsset > _assetsBalance[token] ? _assetsBalance[token]: amountAsset;

        // substract asset balance
        _assetsBalance[token] = _assetsBalance[token].sub(amountAsset);
        
        // transfer user's equivalent OURO token to this contract directly, and burn OURO
        uint256 assetValueInOuro = _lookupAssetValueInOURO(collateral.priceFeed, collateral.assetUnit, amountAsset);
        IERC20(ouroContract).safeTransferFrom(msg.sender, address(this), assetValueInOuro);
        IOUROToken(ouroContract).burn(assetValueInOuro);
        
        // Find out the exact number of assets redeemed to return to caller
        //--------------------------------------------------------------------------------
        // balance - BEFORE ( normally should be 0 )
        uint256 amountRedeemed;
        if (token == WBNB) {
            amountRedeemed = address(this).balance;
        } else {
            amountRedeemed = IERC20(token).balanceOf(address(this));
        }

        // redeem assets
        _redeemSupply(collateral.vTokenAddress, amountAsset);

        // balance - AFTER
        if (token == WBNB) {
            amountRedeemed = address(this).balance.sub(amountRedeemed);
            msg.sender.sendValue(amountRedeemed);
        } else {
            amountRedeemed = IERC20(token).balanceOf(address(this)).sub(amountRedeemed);
            IERC20(token).safeTransfer(msg.sender, amountRedeemed);
        }
        //--------------------------------------------------------------------------------

        // log withdraw
        emit Withdraw(msg.sender, address(token), amountAsset);
    }
    
    /**
     * @dev redeem assets from farm
     */
    function _redeemSupply(address vTokenAddress, uint256 amountAsset) internal {
        _require(IVToken(vTokenAddress).redeemUnderlying(amountAsset) == 0,"venus");
    }

    /**
     * @dev find the given collateral info
     */
    function _findCollateral(address token) internal view returns (CollateralInfo memory, bool) {
        uint n = collaterals.length;
        for (uint i=0;i<n;i++) {
            if (collaterals[i].token == token){
                return (collaterals[i], true);
            }
        }
    }
    
    /**
     * @dev find the given asset value priced in OURO
     */
    function _lookupAssetValueInOURO(AggregatorV3Interface priceFeed, uint256 assetUnit, uint256 amountAsset) internal view returns (uint256 amountOURO) {
        // get lastest asset value in USD
        uint256 assetUnitPrice = getAssetPrice(priceFeed);
        
        // compute total USD value
        uint256 assetValueInUSD = amountAsset
                                                    .mul(assetUnitPrice)
                                                    .div(assetUnit);
                                                    
        // convert asset USD value to OURO value
        uint256 assetValueInOuro = assetValueInUSD.mul(OURO_PRICE_UNIT)
                                                    .div(ouroPrice);
                                                    
        return assetValueInOuro;
    }

    /**
     * ======================================================================================
     * 
     * OURO's stablizer
     *
     * ======================================================================================
     */
     
    // 1. The system will only mint new OGS and sell them for collateral when the value of the 
    //    assets held in the pool is more than 3% less than the value of the issued OURO.
    // 2. The system will only use excess collateral in the pool to conduct OGS buy back and 
    //    burn when the value of the assets held in the pool is 3% higher than the value of the issued OURO
    uint public rebalanceThreshold = 30;  // milli(1/1000)
    uint public OGSbuyBackRatio = 70; // 70% to buy back OGS

    // record last Rebase time
    uint public lastRebaseTimestamp = block.timestamp;
    
    // rebase period
    uint public rebasePeriod = 6 hours;

    // multiplier
    uint internal constant MULTIPLIER = 1e18;
    
    /**
     * @dev rebase entry
     * public method for all external caller
     */
    function rebase() public {
        // only from EOA or owner address
        _require((msg.sender == owner()) || (!msg.sender.isContract() && msg.sender == tx.origin));

        // rebase period check for non-owner
        // owner of this contract has the right to rebase without period check
        if (msg.sender != owner()) {
            _require(block.timestamp > lastRebaseTimestamp + rebasePeriod, "aggressive");
        }
                
        // update rebase time
        lastRebaseTimestamp = block.timestamp;
        
        // rebase collaterals
        _rebase();

        // book keeping after rebase
        if (block.timestamp > ouroLastPriceUpdate + ouroPriceResetPeriod) {
            // record price at month begins
            ouroPriceAtMonthStart = ouroPrice;
            ouroLastPriceUpdate = block.timestamp;
        }

        // log
        emit Rebased(msg.sender);
    }
 
    /**
     * @dev rebase is the stability dynamics for OURO
     */
    function _rebase() internal {
        // get total collateral value priced in USD
        uint256 totalCollateralValue = _getTotalCollateralValue();
        // get total issued OURO value priced in USD
        uint256 totalIssuedOUROValue =              ouroContract.totalSupply()
                                                    .mul(getPrice())
                                                    .div(OURO_PRICE_UNIT);
        
        // compute values deviates
        if (totalCollateralValue >= totalIssuedOUROValue.mul(1000+rebalanceThreshold).div(1000)) {
            _handleExcessiveValue(totalCollateralValue, totalIssuedOUROValue);
          
        } else if (totalCollateralValue <= totalIssuedOUROValue.mul(1000-rebalanceThreshold).div(1000)) {
            // collaterals has less value to OURO value, mint new OGS to buy assets
            uint256 valueDeviates = totalIssuedOUROValue.sub(totalCollateralValue);
            
            // rebalance the collaterals
            _executeRebalance(false, valueDeviates);
        }
    }
    
    /**
     * @dev function to handle excessive value
     */
    function _handleExcessiveValue(uint256 totalCollateralValue, uint256 totalIssuedOUROValue) internal {
        // collaterals has excessive value to OURO value, 
        // 70% of the extra collateral would be used to BUY BACK OGS on secondary markets 
        // and conduct a token burn
        uint256 excessiveValue = totalCollateralValue.sub(totalIssuedOUROValue);
                                                    
        // check if price has already reached monthly limit 
        uint256 priceUpperLimit =               ouroPriceAtMonthStart
                                                .mul(100+appreciationLimit)
                                                .div(100);
                                        
        // conduct an ouro default price change                                
        if (ouroPrice < priceUpperLimit) {
            // However, since there is a 3% limit on how much the OURO Default Exchange Price can increase per month, 
            // only [100,000,000*0.03 = 3,000,000] USD worth of excess assets can be utilized. This 3,000,000 USD worth of 
            // assets will remain in the Reserve Pool, while the remaining [50,000,000-3,000,000=47,000,000] USD worth 
            // of assets will be used for OGS buyback and burns. 
            
            // (limit - current ouro price) / current ouro price
            // eg : (1.03 - 1.01) / 1.01 = 0.0198
            uint256 ouroRisingSpace =           priceUpperLimit.sub(ouroPrice)  // non-negative substraction
                                                .mul(MULTIPLIER)
                                                .div(ouroPrice);

            // a) maxiumum values required to raise price to limit; (totalIssuedOUROValue * 0.0198)
            uint256 ouroApprecationValueLimit = ouroRisingSpace
                                                .mul(totalIssuedOUROValue)
                                                .div(MULTIPLIER);
            
            // b) maximum excessive value usable (30%)
            uint256 maximumUsableValue =        excessiveValue
                                                .mul(100-OGSbuyBackRatio)
                                                .div(100);
            
            // use the smaller one from a) & b) to appreciate OURO
            uint256 valueToAppreciate = ouroApprecationValueLimit < maximumUsableValue?ouroApprecationValueLimit:maximumUsableValue;
            
            // IMPORTANT: value appreciation:
            // ouroPrice = ouroPrice * (totalOUROValue + appreciateValue) / totalOUROValue
            ouroPrice =                         ouroPrice
                                                .mul(totalIssuedOUROValue.add(valueToAppreciate))
                                                .div(totalIssuedOUROValue);
            // log
            emit Appreciation(ouroPrice);
            
            // substract excessive value which has used to appreciate OURO price
            excessiveValue = excessiveValue.sub(valueToAppreciate);
        }
        
        // after price appreciation, if we still have excessive value
        if (excessiveValue > 0) {
            // rebalance the collaterals
            _executeRebalance(true, excessiveValue);
        }
    }
    
    /**
     * @dev value deviates, execute buy back operations
     * valueDeviates is priced in USD
     */
    function _executeRebalance(bool isExcessive, uint256 valueDeviates) internal {
        // step 1. sum total deviated collateral value 
        uint256 totalCollateralValueDeviated;
        for (uint i=0;i<collaterals.length;i++) {
            CollateralInfo memory collateral = collaterals[i];
            
            // check new price of the assets & omit those not deviated
            uint256 newPrice = getAssetPrice(collateral.priceFeed);
            if (isExcessive) {
                // omit assets deviated negatively
                if (newPrice < collateral.lastPrice) {
                    continue;
                }
            } else {
                // omit assets deviated positively
                if (newPrice > collateral.lastPrice) {
                    continue;
                }
            }
            
            // accumulate value in USD
            totalCollateralValueDeviated += newPrice
                                                .mul(_assetsBalance[collateral.token])
                                                .div(collateral.assetUnit);
        }
        
        // step 2. buyback operations in pro-rata basis
        for (uint i=0;i<collaterals.length;i++) {
            CollateralInfo memory collateral = collaterals[i];
        
            // check new price of the assets & omit those not deviated
            uint256 newPrice = getAssetPrice(collateral.priceFeed);
            if (isExcessive) {
                // omit assets deviated negatively
                if (newPrice < collateral.lastPrice) {
                    continue;
                }
            } else {
                // omit assets deviated positively
                if (newPrice > collateral.lastPrice) {
                    continue;
                }
            }
            
            // calc slot value in USD
            uint256 slotValue = newPrice
                                                .mul(_assetsBalance[collateral.token])
                                                .div(collateral.assetUnit);
            
            // calc pro-rata buy back value(in USD) for this collateral
            uint256 slotBuyBackValue = slotValue.mul(valueDeviates)
                                                .div(totalCollateralValueDeviated);
                                
            // non zero check
            if (slotBuyBackValue > 0) {
                // execute different buyback operations
                if (isExcessive) {
                    _buybackOGS(
                        collateral.token, 
                        collateral.vTokenAddress,
                        collateral.assetUnit,
                        collateral.priceFeed,
                        slotBuyBackValue
                    );
                } else {
                    _buybackCollateral(
                        collateral.token, 
                        collateral.vTokenAddress,
                        collateral.assetUnit,
                        collateral.priceFeed,
                        slotBuyBackValue
                    );
                }
            }
        }

        // step 3. update price reference point
        for (uint i=0;i<collaterals.length;i++) {
            collaterals[i].lastPrice = getAssetPrice(collaterals[i].priceFeed);
        }
    }

    /**
     * @dev get total collateral value in USD
     */
    function _getTotalCollateralValue() internal view returns(uint256) {
        uint256 totalCollateralValue;
        for (uint i=0;i<collaterals.length;i++) {
            CollateralInfo memory collateral = collaterals[i];
            totalCollateralValue += getAssetPrice(collateral.priceFeed)
                                    .mul(_assetsBalance[collateral.token])
                                    .div(collateral.assetUnit);
        }
        
        return totalCollateralValue;
    }
    
    /**
     * @dev buy back OGS with collateral
     * 1. to form an insurance fund (50%)
     * 2. conduct a ogs burn(50%)
     */
    function _buybackOGS(address token ,address vTokenAddress, uint256 assetUnit, AggregatorV3Interface priceFeed, uint256 slotValue) internal {
        uint256 collateralToRedeem = slotValue
                                        .mul(assetUnit)
                                        .div(getAssetPrice(priceFeed));
         
        // balance - before redeeming 
        uint256 redeemedAmount;
        if (token == WBNB) {
            redeemedAmount = address(this).balance;
        } else {
            redeemedAmount = IERC20(token).balanceOf(address(this));
        }
        
        // redeem supply from farming
        // NOTE:
        //  if venus has insufficient liquidity, this will return non 0, but the process continues
        IVToken(vTokenAddress).redeemUnderlying(collateralToRedeem);
        
        // balance - after redeeming
        if (token == WBNB) {
            redeemedAmount = address(this).balance.sub(redeemedAmount);
        } else {
            redeemedAmount = IERC20(token).balanceOf(address(this)).sub(redeemedAmount);
        }

        // accounting
        _assetsBalance[token] = _assetsBalance[token].sub(redeemedAmount);

        // split assets allocation
        uint256 assetToInsuranceFund = redeemedAmount.mul(50).div(100);
        uint256 assetToBuyBackOGS = redeemedAmount.sub(assetToInsuranceFund);
        
        // allocation a)
        // swap to BUSD to form last resort insurance fund (50%)
        if (assetToInsuranceFund >0) {
            if (token == busdContract) {
                // transfer assetToInsuranceFund(50%) to last resort fund
                IERC20(busdContract).safeTransfer(lastResortFund, assetToInsuranceFund);
            } else {
                address[] memory path;
                if (token == WBNB) {
                    // path: WBNB -> BUSD
                    path = new address[](2);
                    path[0] = token;
                    path[1] = busdContract;
                } else {
                    // path: token -> WBNB -> BUSD
                    path = new address[](3);
                    path[0] = token;
                    path[1] = WBNB;
                    path[2] = busdContract;
                }
                
                // swap USD out
                if (token == WBNB) {
                    router.swapExactETHForTokens{value:assetToInsuranceFund}(
                        0, 
                        path, 
                        address(this), 
                        block.timestamp.add(600)
                    );
                    
                } else {
                    router.swapExactTokensForTokens(
                        assetToInsuranceFund,
                        0, 
                        path, 
                        address(this), 
                        block.timestamp.add(600)
                    );
                }
                
                // transfer all swapped USD to last resort fund
                uint256 amountUSD = IERC20(busdContract).balanceOf(address(this));
                IERC20(busdContract).safeTransfer(lastResortFund, amountUSD);
            }
        }
        
        // allocation b)
        // conduct a OGS burning process
        // the path to find how many OGS can be swapped
        address[] memory path;
        if (token == busdContract) {
            // path: BUSD -> OGS
            path = new address[](2);
            path[0] = token;
            path[1] = address(ogsContract);
        } else if (token == WBNB) {
            // path: WBNB -> BUSD -> OGS
            path = new address[](3);
            path[0] = token;
            path[1] = busdContract;
            path[2] = address(ogsContract);
        } else {
            // path: token -> WBNB -> BUSD -> OGS
            path = new address[](4);
            path[0] = token;
            path[1] = WBNB; 
            path[2] = busdContract;
            path[3] = address(ogsContract);
        }
        
        // swap OGS out
        uint [] memory amounts;
        if (assetToBuyBackOGS > 0) {
            if (token == WBNB) {
                amounts = router.swapExactETHForTokens{value:assetToBuyBackOGS}(
                    0, 
                    path, 
                    address(this), 
                    block.timestamp.add(600)
                );
                
            } else {
                amounts = router.swapExactTokensForTokens(
                    assetToBuyBackOGS,
                    0, 
                    path, 
                    address(this), 
                    block.timestamp.add(600)
                );
            }
            
            // burn OGS
            ogsContract.burn(amounts[amounts.length - 1]);
                    
            // log
            emit OGSBurned(amounts[amounts.length - 1]);
        }
    }
    
    /**
     * @dev buy back collateral with OGS
     * slotValue is priced in BUSD 
     */
    function _buybackCollateral(address token ,address vTokenAddress, uint256 assetUnit, AggregatorV3Interface priceFeed, uint256 slotValue) internal {
        uint256 collateralToBuyBack = slotValue
                                        .mul(assetUnit)
                                        .div(getAssetPrice(priceFeed));
                                             
        // the path to find how many OGS required to swap collateral out
        address[] memory path;
        if (token == busdContract) {
            // path: OGS-> BUSD
            path = new address[](2);
            path[0] = address(ogsContract);
            path[1] = token;
        } else if (token == WBNB) {
            // path: OGS-> BUSD -> WBNB
            path = new address[](3);
            path[0] = address(ogsContract);
            path[1] = busdContract; // use USD to bridge
            path[2] = token;
        } else {
            // path: OGS-> BUSD -> WBNB -> collateral
            path = new address[](4);
            path[0] = address(ogsContract);
            path[1] = busdContract; // use USD to bridge
            path[2] = WBNB;
            path[3] = token;
        }
        
        if (collateralToBuyBack > 0) {
            // calc amount OGS required to swap out given collateral
            uint [] memory amounts = router.getAmountsIn(collateralToBuyBack, path);
            uint256 ogsRequired = amounts[0];
                        
            // mint OGS to this contract to buy back collateral           
            // NOTE: ogs contract MUST authorized THIS contract the privilege to mint
            ogsContract.mint(address(this), ogsRequired);
    
            // swap collateral out
            if (token == WBNB) {
                amounts = router.swapExactTokensForETH(
                    ogsRequired,
                    0,
                    path, 
                    address(this), 
                    block.timestamp.add(600)
                );
            } else {
                amounts = router.swapExactTokensForTokens(
                    ogsRequired,
                    0, 
                    path, 
                    address(this), 
                    block.timestamp.add(600)
                );
            }
            
            uint256 swappedOut = amounts[amounts.length - 1];
            
            // as we brought back the collateral, farm the asset
            _supply(token, vTokenAddress, swappedOut);
            
            // accounting
            _assetsBalance[token] = _assetsBalance[token].add(swappedOut);
            
            // log
            emit CollateralBroughtBack(token, swappedOut);
        }
    }
    
    /**
     * ======================================================================================
     * 
     * OURO's farming revenue distribution
     *
     * ======================================================================================
     */

     /**
      * @dev a public function accessible to anyone to distribute revenue
      */
     function distributeRevenue() external {
         // only from EOA
         _require(!msg.sender.isContract() && msg.sender == tx.origin);
         
         _distributeXVS();
         _distributeAssetRevenue();
                 
        // log 
        emit RevenueDistributed();
     }
     
     function _distributeXVS() internal {
        // get venus markets
        address[] memory venusMarkets = new address[](collaterals.length);
        for (uint i=0;i<collaterals.length;i++) {
            venusMarkets[i] = collaterals[i].vTokenAddress;
        }
        
        // balance - before
        uint256 xvsAmount = IERC20(xvsAddress).balanceOf(address(this));

        // claim venus XVS reward
        IVenusDistribution(unitroller).claimVenus(address(this), venusMarkets);

        // and exchange XVS to OGS
        // XVS -> WBNB -> BUSD -> OGS
        address[] memory path = new address[](4);
        path[0] = xvsAddress;
        path[1] = WBNB;
        path[2] = busdContract;
        path[3] = address(ogsContract);

        // balance - after swap all XVS to OGS
        xvsAmount = IERC20(xvsAddress).balanceOf(address(this)).sub(xvsAmount);

        if (xvsAmount > 0) {
            // swap OGS out
            uint [] memory amounts = router.swapExactTokensForTokens(
                xvsAmount,
                0, 
                path, 
                address(this), 
                block.timestamp.add(600)
            );
            uint256 ogsAmountOut = amounts[amounts.length - 1];
    
            // burn OGS
            ogsContract.burn(ogsAmountOut);
        }
                
        // log
        emit XVSDist(xvsAmount);
     }
     
     function _distributeAssetRevenue() internal {   
        // distribute assets revenue 
        uint n = collaterals.length;
        for (uint i=0;i<n;i++) {
            CollateralInfo memory collateral = collaterals[i];
            // get underlying balance
            uint256 farmBalance = IVToken(collateral.vTokenAddress).balanceOfUnderlying(address(this));
            
            // revenue generated
            if (farmBalance > _assetsBalance[collateral.token]) {        
                // the diff is the revenue
                uint256 revenue = farmBalance.sub(_assetsBalance[collateral.token]);

                // balance - before
                uint256 redeemedAmount;
                if (collateral.token == WBNB) {
                    redeemedAmount = address(this).balance;
                } else {
                    redeemedAmount = IERC20(collateral.token).balanceOf(address(this));
                }
                
                // redeem asset
                // NOTE: 
                //  just use redeemUnderlying w/o return value check here.
                IVToken(collateral.vTokenAddress).redeemUnderlying(revenue);

                // get actual revenue redeemed and
                // transfer asset to ouro revenue distribution contract
                if (collateral.token == WBNB) {
                    // balance - after
                    redeemedAmount = address(this).balance.sub(redeemedAmount);
                    payable(address(ouroDistContact)).sendValue(redeemedAmount);
                } else {
                    // balance - after
                    redeemedAmount = IERC20(collateral.token).balanceOf(address(this)).sub(redeemedAmount);
                    IERC20(collateral.token).safeTransfer(address(ouroDistContact), redeemedAmount);
                }
                
                // notify ouro revenue contract
                if (redeemedAmount > 0) {
                    ouroDistContact.revenueArrival(collateral.token, redeemedAmount);
                }
            }
        }
     }
    
    /**
     * ======================================================================================
     * 
     * OURO Reserve's events
     *
     * ======================================================================================
     */
     event Deposit(address account, uint256 ouroAmount);
     event Withdraw(address account, address token, uint256 assetAmount);
     event Appreciation(uint256 price);
     event Rebased(address account);
     event NewCollateral(address token);
     event RemoveCollateral(address token);
     event CollateralBroughtBack(address token, uint256 amount);
     event OGSBurned(uint ogsAmount);
     event AllowanceReset();
     event XVSDist(uint256 amount);
     event RevenueDistributed();
     event LastResortFundSet(address account);
     event OuroDistChanged(address account);
     event WhiteListToggled(bool enabled);
     event WhiteListSet(address account, bool allow);
     event EmergencyWithdraw(address account, address to);
     event OGSbuyBackRatioSet(uint256 ratio);
     event RebasePeriodSet(uint256 period);
}
