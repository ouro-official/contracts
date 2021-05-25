// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./library.sol";

/**
 * @title OURO community reserve
 */
contract OUROReserve is IOUROReserve,Ownable {
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
    uint256 public ouroPrice = 1e18; // current ouro price, initially 1 OURO = 1 USDT
    uint256 public ouroPriceAtMonthStart = 1e18; // ouro price at the begining of a month, initially set to 1 USDT
    uint256 public constant OURO_PRICE_UNIT = 1e18; // 1 OURO = 1e18
    
    uint256 internal constant MONTH = 30 days;
    uint public appreciationLimit = 3; // 3 perce nt monthly OURO price appreciation limit
    uint public ouroLastPriceUpdate = block.timestamp;
    uint public constant ouroPriceUpdatePeriod = MONTH;

    address public constant usdtContract = 0x55d398326f99059fF775485246999027B3197955;
    IOUROToken public constant ouroContract = IOUROToken(0x18221Fa6550E6Fd6EfEb9b4aE6313D07Acd824d5);
    IOGSToken public constant ogsContract = IOGSToken(0x0d06E5Cb94CC56DdAd96bF7100F01873406959Ba);
    IOURODist public ouroDistContact = IOURODist(0x7341a9e16120a7b6aa3a98e51851f33Fb5F07E07);
    address public constant unitroller = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address public constant xvsAddress = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
    IPancakeRouter02 public constant router = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    
    address immutable internal WETH = router.WETH();
    uint256 constant internal USDT_UNIT = 1e18;
    uint256 constant internal MAX_UINT256 = uint256(-1);
    
    // @dev montly OURO issuance schedule in million(1e6) OURO
    uint16 [] public issueSchedule = [10,30,50,70,100,150,200,300,400,500,650,800];
    uint256 internal constant issueUnit = 1e18 * 1e6;
    
    // @dev scheduled issue from
    uint256 public immutable issueFrom = block.timestamp;
    
    // a struct to storge collateral asset info
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
    
    /**
     * ======================================================================================
     * 
     * VIEW FUNCTIONS
     * 
     * ======================================================================================
     */
    function getAssetBalance(address token) external view returns(uint256) {
        return _assetsBalance[token];
    }
    
    function getCollateral(address token) external view returns (
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
     * ======================================================================================
     * 
     * SYSTEM FUNCTIONS
     * 
     * ======================================================================================
     */
     
    receive() external payable {}
    
    // try rebase for user's deposit and withdraw
    modifier tryRebase() {
        if (block.timestamp > lastRebaseTimestamp + rebasePeriod) {
            rebase();
        }
        _;    
    }
    
    constructor() public {
        // approve xvs to router
        IERC20(xvsAddress).safeApprove(address(router), MAX_UINT256);
        // approve ogs to router
        IERC20(ogsContract).safeApprove(address(router), MAX_UINT256);
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
        require(!exist, "exist");
        
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
        if (address(token) != WETH) {
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
                if (address(token) != WETH) {
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
            if (address(token) != WETH) {
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
        
        // log
        emit ResetAllowance();
    }

    /**
     * ======================================================================================
     * 
     * OURO's collateral deposit & withdraw
     *
     * ======================================================================================
     */
        
    /** 
     * @dev get system defined OURO price
     */
    function getPrice() public view override returns(uint256) { return ouroPrice; }
    
    /**
     * @dev get asset price in USDT(decimal=8) for 1 unit of asset
     */
    function getAssetPrice(AggregatorV3Interface feed) public view returns(uint256) {
        // always align the price to USDT decimal, which is 1e18 on BSC and 1e6 on Ethereum
        uint256 priceAlignMultiplier = USDT_UNIT / (10**uint256(feed.decimals()));
        
        // query price from chainlink
        (, int latestPrice, , , ) = feed.latestRoundData();

        // avert negative price
        require (latestPrice > 0, "invalid price");
        
        // return price corrected to USDT decimal
        return uint256(latestPrice).mul(priceAlignMultiplier);
    }
    
    /**
     * @dev user deposit assets and receive OURO
     * @notice users need approve() assets to this contract
     */
    function deposit(address token, uint256 amountAsset) external override payable tryRebase {
        
        // locate collateral
        (CollateralInfo memory collateral, bool valid) = _findCollateral(token);
        require(valid, "invalid collateral");

        // for native token, replace amountAsset with use msg.value instead
        if (token == WETH) {
            amountAsset = msg.value;
        }
        
        // non-0 deposit check
        require(amountAsset > 0, "0 deposit");

        // get equivalent OURO value
        uint256 assetValueInOuro = _lookupAssetValueInOURO(collateral, amountAsset);
        
        // check monthly OURO issuance limit
        uint monthN = block.timestamp.sub(issueFrom).div(MONTH);
        if (monthN < issueSchedule.length) { // still in control
            require(assetValueInOuro + IERC20(ouroContract).totalSupply() 
                        <=
                    uint256(issueSchedule[monthN]).mul(issueUnit),
                    "limited"
            );
        }
        
        // transfer token assets to this contract
        // @notice for ERC20 assets, users need to approve() to this reserve contract 
        if (token != WETH) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amountAsset);
        }
                                        
        // mint OURO to sender
        IOUROToken(ouroContract).mint(msg.sender, assetValueInOuro);
        
        // update asset balance
        _assetsBalance[address(token)] += amountAsset;

        // finally we farm the assets received
        _supply(collateral, amountAsset);
        
        // log
        emit Deposit(msg.sender, assetValueInOuro);
    }
    
    /**
     * @dev farm the user's deposit
     */
    function _supply(CollateralInfo memory collateral, uint256 amountAsset) internal {
        if (collateral.token == WETH) {
            IVBNB(collateral.vTokenAddress).mint{value: amountAsset}();
        } else {
            IVToken(collateral.vTokenAddress).mint(amountAsset);
        }
    }
    
    /**
     * @dev user swap his OURO back to assets
     * @notice users need approve() OURO assets to this contract
     */
    function withdraw(address token, uint256 amountAsset) external override tryRebase {
        
        // locate collateral
        (CollateralInfo memory collateral, bool valid) = _findCollateral(token);
        require(valid, "not a collateral");
                                                    
        // check if we have sufficient assets to return to user
        uint256 assetBalance = _assetsBalance[address(token)];
        
        // perform OURO token burn
        if (assetBalance >= amountAsset) {
            // substract asset balance
            _assetsBalance[address(token)] -= amountAsset;
            
            // redeem assets
            _redeemSupply(collateral.token, collateral.vTokenAddress, amountAsset);
                    
            // sufficient asset satisfied! transfer user's equivalent OURO token to this contract directly
            uint256 assetValueInOuro = _lookupAssetValueInOURO(collateral, amountAsset);
            IERC20(ouroContract).safeTransferFrom(msg.sender, address(this), assetValueInOuro);
            
            // and burn OURO.
            IOUROToken(ouroContract).burn(assetValueInOuro);

        } else {
            // drain asset balance
            _assetsBalance[address(token)] = 0;
            
            // insufficient assets, redeem ALL
             _redeemSupply(collateral.token, collateral.vTokenAddress, assetBalance);

            // redeemed assets value in OURO
            uint256 redeemedAssetValue = _lookupAssetValueInOURO(collateral, assetBalance);
            
            // as we don't have enough assets to return to user
            // we buy extra assets from swaps with user's OURO
            uint256 extraAssets = amountAsset.sub(assetBalance);
    
            // find how many extra OUROs required to swap the extra assets out
            // path:
            //  (??? ouro) -> USDT -> collateral
            
            address[] memory path;
            
            if (token == usdtContract) {
                path = new address[](2);
                path[0] = address(ouroContract);
                path[1] = token;
            } else {
                path = new address[](3);
                path[0] = address(ouroContract);
                path[1] = usdtContract; // use USDT to bridge
                path[2] = token;
            }

            uint [] memory amounts = router.getAmountsIn(extraAssets, path);
            uint256 extraOuroRequired = amounts[0];
            
            // @notice user needs sufficient OURO to swap assets out
            // transfer total OURO to this contract, if user has insufficient OURO, the transaction will revert!
            uint256 totalOuroToBurn = extraOuroRequired.add(redeemedAssetValue);
            ouroContract.safeTransferFrom(msg.sender, address(this), totalOuroToBurn);
    
            // buy assets back to this contract
            // path:
            //  ouro-> (USDT) -> collateral
            if (token == WETH) {
                router.swapTokensForExactETH(
                    extraAssets, 
                    extraOuroRequired, 
                    path, 
                    address(this), 
                    block.timestamp.add(600)
                );
            } else {
                // swap out tokens out to OURO contract
                router.swapTokensForExactTokens(
                    extraAssets, 
                    extraOuroRequired, 
                    path, 
                    address(this), 
                    block.timestamp.add(600)
                );
            }
            
            // burn OURO
            ouroContract.burn(totalOuroToBurn);
        }
        
        // finally we transfer the assets based on asset type back to user
        if (token == WETH) {
            uint256 value = address(this).balance < amountAsset? address(this).balance:amountAsset;
            msg.sender.sendValue(value);
        } else {
            uint256 value = IERC20(token).balanceOf(address(this)) < amountAsset? IERC20(token).balanceOf(address(this)):amountAsset;
            IERC20(token).safeTransfer(msg.sender, value);
        }
        
        // log withdraw
        emit Withdraw(msg.sender, address(token), amountAsset);
    }
    
    /**
     * @dev redeem assets from farm
     */
    function _redeemSupply(address token, address vToken, uint256 amountAsset) internal {
        if (token == WETH) {
            IVBNB(vToken).redeemUnderlying(amountAsset);
        } else {
            IVToken(vToken).redeemUnderlying(amountAsset);
        }
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
    function _lookupAssetValueInOURO(CollateralInfo memory collateral, uint256 amountAsset) internal view returns (uint256 amountOURO) {
        // get lastest asset value in USDT
        uint256 assetUnitPrice = getAssetPrice(collateral.priceFeed);
        
        // compute total USDT value
        uint256 assetValueInUSDT = amountAsset
                                                    .mul(assetUnitPrice)
                                                    .div(collateral.assetUnit);
                                                    
        // convert asset USDT value to OURO value
        uint256 assetValueInOuro = assetValueInUSDT.mul(OURO_PRICE_UNIT)
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
    uint public rebalanceThreshold = 3;
    uint public OGSbuyBackRatio = 70; // 70% to buy back OGS

    // record last Rebase time
    uint public lastRebaseTimestamp = block.timestamp;
    
    // rebase period
    uint public rebasePeriod = 1 days;

    // multiplier
    uint internal constant MULTIPLIER = 1e12;

    /**
     * @dev set rebase period
     */
    function setRebasePeriod(uint period) external onlyOwner {
        require(period > 0, "period 0");
        rebasePeriod = period;
    }
    
    /**
     * @dev rebase entry
     * public method for all external caller
     */
    function rebase() public {
         // rebase period check
        require(block.timestamp > lastRebaseTimestamp + rebasePeriod, "aggressive rebase");
        
        // rebase collaterals
        _rebase();
                
        // update rebase time
        lastRebaseTimestamp += rebasePeriod;
        
        // book keeping after rebase
        if (block.timestamp > ouroLastPriceUpdate + ouroPriceUpdatePeriod) {
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
        // get total collateral value priced in USDT
        uint256 totalCollateralValue = _getTotalCollateralValue();
        // get total issued OURO value priced in USDT
        uint256 totalIssuedOUROValue =              ouroContract.totalSupply()
                                                    .mul(getPrice())
                                                    .div(OURO_PRICE_UNIT);
        
        // compute values deviates
        if (totalCollateralValue >= totalIssuedOUROValue.mul(100+rebalanceThreshold).div(100)) {
            // collaterals has excessive value to OURO value, 
            // 70% of the extra collateral would be used to BUY BACK OGS on secondary markets 
            // and conduct a token burn
            uint256 excessiveValue =                totalCollateralValue
                                                    .sub(totalIssuedOUROValue)
                                                    .div(100);
                                                        
            // check if price has already reached monthly limit 
            uint256 priceUpperLimit =               ouroPriceAtMonthStart
                                                    .mul(100+appreciationLimit)
                                                    .div(100);
                                            
            // conduct a ouro default price change                                
            if (ouroPrice < priceUpperLimit) {
                // However, since there is a 3% limit on how much the OURO Default Exchange Price can increase per month, 
                // only [100,000,000*0.03 = 3,000,000] USDT worth of excess assets can be utilized. This 3,000,000 USDT worth of 
                // assets will remain in the Reserve Pool, while the remaining [50,000,000-3,000,000=47,000,000] USDT worth 
                // of assets will be used for OGS buyback and burns. 
                
                // (limit - current ouro price) / current ouro price
                // eg : (1.03 - 1.01) / 1.01 = 0.0198
                uint256 ouroRisingSpace =           priceUpperLimit.sub(ouroPrice)  // non-negative substraction
                                                    .mul(MULTIPLIER)
                                                    .div(ouroPrice);

                // a) maxiumum values required to raise price to limit;
                uint256 ouroApprecationValueLimit = ouroRisingSpace
                                                    .mul(totalIssuedOUROValue)
                                                    .div(MULTIPLIER);
                
                // b) maximum excessive value usable (30%)
                uint256 maximumUsableValue =        excessiveValue
                                                    .mul(100-OGSbuyBackRatio);
                
                // use the smaller one from a) & b) to appreciate OURO
                uint256 valueToAppreciate = ouroApprecationValueLimit < maximumUsableValue?ouroApprecationValueLimit:maximumUsableValue;
                
                // value appreciation:
                // ouroPrice = ouroPrice * (totalOUROValue + appreciateValue) / totalOUROValue
                ouroPrice =                         ouroPrice
                                                    .mul(totalIssuedOUROValue.add(valueToAppreciate))
                                                    .div(totalIssuedOUROValue);
                
                // substract excessive value which has used to appreciate OURO price
                excessiveValue = excessiveValue.sub(valueToAppreciate);
            }
            
            // after price appreciation, if we still have excessive value
            // conduct a collateral rebalance
            if (excessiveValue > 0) {
                // rebalance the collaterals
                _executeRebalance(true, excessiveValue);
            }
            
        } else if (totalCollateralValue <= totalIssuedOUROValue.mul(100-rebalanceThreshold).div(100)) {
            // collaterals has less value to OURO value, mint new OGS to buy assets
            uint256 valueDeviates = totalIssuedOUROValue.sub(totalCollateralValue);
            
            // rebalance the collaterals
            _executeRebalance(false, valueDeviates);
        }
    }
    
    /**
     * @dev value deviates, execute buy back operations
     * valueDeviates is priced in USDT
     */
    function _executeRebalance(bool buyOGS, uint256 valueDeviates) internal {
        // step 1. sum total deviated collateral value 
        uint256 totalCollateralValueDeviated;
        for (uint i=0;i<collaterals.length;i++) {
            CollateralInfo storage collateral = collaterals[i];
            
            // check new price of the assets & omit those not deviated
            uint256 newPrice = getAssetPrice(collateral.priceFeed);
            if (buyOGS) {
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
            
            // accumulate value in USDT
            totalCollateralValueDeviated += getAssetPrice(collateral.priceFeed)
                                                .mul(_assetsBalance[collateral.token])
                                                .div(collateral.assetUnit);
        }
        
        // step 2. buyback operations in pro-rata basis
        for (uint i=0;i<collaterals.length;i++) {
            CollateralInfo storage collateral = collaterals[i];
        
            // check new price of the assets & omit those not deviated
            uint256 newPrice = getAssetPrice(collateral.priceFeed);
            if (buyOGS) {
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
            
            // calc slot value in USDT
            uint256 slotValue = getAssetPrice(collateral.priceFeed)
                                                .mul(_assetsBalance[collateral.token])
                                                .div(collateral.assetUnit);
            
            // calc pro-rata buy back value(in USDT) for this collateral
            uint256 slotBuyBackValue = slotValue.mul(valueDeviates)
                                                .div(totalCollateralValueDeviated);
                                
            // execute different buyback operations
            if (buyOGS) {
                _buybackOGS(collateral, slotBuyBackValue);
            } else {
                _buybackCollateral(collateral, slotBuyBackValue);
            }
            
            // update the collateral price to lastest
            collateral.lastPrice = newPrice;
        }
    }

    /**
     * @dev get total collateral value in USDT
     */
    function _getTotalCollateralValue() internal view returns(uint256) {
        uint256 totalCollateralValue;
        for (uint i=0;i<collaterals.length;i++) {
            CollateralInfo storage collateral = collaterals[i];
            totalCollateralValue += getAssetPrice(collateral.priceFeed)
                                    .mul(_assetsBalance[collateral.token])
                                    .div(collateral.assetUnit);
        }
        
        return totalCollateralValue;
    }
    
    /**
     * @dev buy back OGS with collateral
     * slotValue is priced in USDT 
     */
    function _buybackOGS(CollateralInfo storage collateral, uint256 slotValue) internal {
        uint256 collateralToBuyOGS = slotValue
                                        .mul(collateral.assetUnit)
                                        .div(getAssetPrice(collateral.priceFeed));

        // redeem supply from farming
        _redeemSupply(collateral.token, collateral.vTokenAddress, collateralToBuyOGS);
        uint256 redeemedAmount;
        if (collateral.token == WETH) {
            redeemedAmount = address(this).balance;
        } else {
            redeemedAmount = IERC20(collateral.token).balanceOf(address(this));
        }
        
        // the path to find how many OGS can be swapped
        // path:
        //  collateral -> USDT -> (??? OGS)

        address[] memory path;
        if (collateral.token == usdtContract) {
            path = new address[](2);
            path[0] = collateral.token;
            path[1] = address(ogsContract);
        } else {
            path = new address[](3);
            path[0] = collateral.token;
            path[1] = usdtContract; // use USDT to bridge
            path[2] = address(ogsContract);
        }
        
        // calc amount OGS that could be swapped out with given collateral
        uint [] memory amounts = router.getAmountsOut(redeemedAmount, path);
        uint256 ogsAmountOut = amounts[amounts.length - 1];
        
        // the path to swap OGS out
        // path:
        //  collateral -> USDT -> exact OGS
        if (collateral.token == WETH) {
            
            // swap OGS out with native assets to THIS contract
            router.swapExactETHForTokens{value:redeemedAmount}(
                ogsAmountOut, 
                path, 
                address(this), 
                block.timestamp.add(600)
            );
            
        } else {
            
            // swap OGS out to THIS contract
            router.swapExactTokensForTokens(
                redeemedAmount, 
                ogsAmountOut, 
                path, 
                address(this), 
                block.timestamp.add(600)
            );
        }

        // burn OGS
        ogsContract.burn(ogsAmountOut);
        
        // accounting
        _assetsBalance[collateral.token] = _assetsBalance[collateral.token].sub(redeemedAmount);
    }
    
    /**
     * @dev buy back collateral with OGS
     * slotValue is priced in USDT 
     */
    function _buybackCollateral(CollateralInfo storage collateral, uint256 slotValue) internal {
        uint256 collateralToBuyBack = slotValue
                                        .mul(collateral.assetUnit)
                                        .div(getAssetPrice(collateral.priceFeed));
                                             
        // the path to find how many OGS required to swap collateral out
        // path:
        //  (??? OGS) -> USDT -> collateral
        address[] memory path;
        if (collateral.token == usdtContract) {
            path = new address[](2);
            path[0] = address(ogsContract);
            path[1] = collateral.token;
        } else {
            path = new address[](3);
            path[0] = address(ogsContract);
            path[1] = usdtContract; // use USDT to bridge
            path[2] = collateral.token;
        }
        
        // calc amount OGS required to swap out given collateral
        uint [] memory amounts = router.getAmountsIn(collateralToBuyBack, path);
        uint256 ogsRequired = amounts[0];
                    
        // mint OGS to this contract to buy back collateral           
        // NOTE: ogs contract MUST authorized THIS contract the privilege to mint
        ogsContract.mint(address(this), ogsRequired);

        // the path to swap collateral out
        // path:
        //  (exact OGS) -> USDT -> collateral
        if (address(collateral.token) == WETH) {
            
            // swap out native assets ETH, BNB with OGS to OURO contract
            router.swapTokensForExactETH(
                ogsRequired, 
                collateralToBuyBack, 
                path, 
                address(this), 
                block.timestamp.add(600)
            );

        } else {
            // swap out tokens out to OURO contract
            router.swapTokensForExactTokens(
                ogsRequired, 
                collateralToBuyBack, 
                path, 
                address(this), 
                block.timestamp.add(600)
            );
        }
        
        // as we brought back the collateral, farm the asset
        _supply(collateral, collateralToBuyBack);
        
        // accounting
        _assetsBalance[collateral.token] = _assetsBalance[collateral.token].add(collateralToBuyBack);
    }
    
    /**
     * ======================================================================================
     * 
     * OURO's farming revenue distribution
     *
     * ======================================================================================
     */
     
     /**
      * @dev change ouro revenue distribution contract address
      * in case of severe bug
      */
     function changeOURODist(address newContract) external onlyOwner {
         ouroDistContact = IOURODist(newContract);
     }
     
     /**
      * @dev a public function accessible to anyone to distribute revenue
      */
     function distributeRevenue() external {
        // get venus markets
        address[] memory venusMarkets = new address[](collaterals.length);
        for (uint i=0;i<collaterals.length;i++) {
            venusMarkets[i] = collaterals[i].vTokenAddress;
        }
        // claim venus XVS reward
        IVenusDistribution(unitroller).claimVenus(address(this), venusMarkets);
        
        // and exchange XVS to OGS
        address[] memory path = new address[](3);
        path[0] = xvsAddress;
        path[1] = usdtContract;
        path[2] = address(ogsContract);

        // swap all XVS to OGS
        uint256 xvsAmount = IERC20(xvsAddress).balanceOf(address(this));
        uint [] memory amounts = router.getAmountsOut(xvsAmount, path);
        uint256 ogsAmountOut = amounts[path.length - 1];
        
        // swap OGS out
        router.swapTokensForExactTokens(
            ogsAmountOut, 
            xvsAmount, 
            path, 
            address(this), 
            block.timestamp.add(600)
        );

        // burn OGS
        ogsContract.burn(ogsAmountOut);
        
        // distribute assets revenue 
        uint n = collaterals.length;
        for (uint i=0;i<n;i++) {
            CollateralInfo storage collateral = collaterals[i];
            // get underlying balance
            uint256 farmBalance = IVToken(collateral.vTokenAddress).balanceOfUnderlying(address(this));
            
            // revenue generated
            if (farmBalance > _assetsBalance[collateral.token]) {
                // redeem asset
                uint256 revenue = farmBalance.sub(_assetsBalance[collateral.token]);
                IVToken(collateral.vTokenAddress).redeemUnderlying(revenue);
                
                // get actual revenue redeemed
                uint256 redeemedAmount;
                if (collateral.token == WETH) {
                    redeemedAmount = address(this).balance;
                } else {
                    redeemedAmount = IERC20(collateral.token).balanceOf(address(this));
                }
                
                // transfer asset to ouro revenue distribution contract
                if (collateral.token == WETH) {
                    payable(address(ouroDistContact)).sendValue(redeemedAmount);
                } else {
                    IERC20(collateral.token).safeTransfer(address(ouroDistContact), redeemedAmount);
                }
                
                // notify ouro revenue contract
                ouroDistContact.revenueArrival(collateral.token, redeemedAmount);
            }
        }
        
        // log 
        emit RevenueDistributed();
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
     event Rebased(address account);
     event NewCollateral(address token);
     event RemoveCollateral(address token);
     event ResetAllowance();
     event RevenueDistributed();
}