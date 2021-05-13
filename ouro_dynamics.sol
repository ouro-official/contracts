// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./library.sol";

/**
 * @notice OURO stability dynamics 
 */
contract OURODynamics is IOURODynamics,Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint;
    using Address for address payable;
    using SafeMath for uint256;
    using SafeERC20 for IOUROToken;
    using SafeERC20 for IOGSToken;
    
    // @dev ouro price 
    uint256 public ouroPrice = 1e18; // current ouro price, initially 1 USDT on bsc
    uint256 public ouroPriceAtMonthStart = 1e18; // ouro price at the begining of a monty, initially set to 1 USDT on bsc
    uint256 public OURO_PRICE_UNIT = 1e18; // 1 OURO
    
    uint public appreciationLimit = 3; // 3 percent monthly apprecation limit
    uint public ouroLastPriceUpdate = block.timestamp;
    uint public ouroPriceUpdatePeriod = MONTH;
    
    /** 
     * @dev get system defined OURO price
     */
    function getPrice() public override returns(uint256) {
        return ouroPrice;
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

    IPancakeRouter02 public router = IPancakeRouter02(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    uint256 constant internal MAX_UINT256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    
    // @dev issue schedule in million OURO
    uint16 [] public issueSchedule = [10,30,50,70,100,150,200,300,400,500,650,800];
    uint256 internal constant issueUnit = 1e18 * 1e6;
    
    // @dev scheduled issue from
    uint256 public issueFrom = block.timestamp;
    uint256 internal constant DAY = 86400;
    uint256 internal constant MONTH = 30 * DAY;

    // try rebase for user's deposit and withdraw
    modifier tryRebase() {
        if (lastRebaseTimestamp + rebasePeriod >= block.timestamp) {
            rebase();
        }
        _;    
    }
    
    /**
     * @dev find the given collateral info
     */
    function findCollateral(IERC20 token) internal view returns (CollateralInfo memory, bool) {
        // lookup asset price
        bool valid;
        CollateralInfo memory collateral;
        for (uint i=0;i<collaterals.length;i++) {
            collateral = collaterals[i];
            if (collateral.token == token){
                valid = true;
                break;
            }
        }
        
        return (collateral, valid);
    }
    
    /**
     * @dev find the given collateral info
     */
    function lookupAssetOUROValue(CollateralInfo memory collateral, uint256 amountAsset) internal view returns (uint256 amountOURO) {
              // lookup asset value in USDT
        uint256 unitPrice = getAssetPrice(collateral.priceFeed);
        
        uint256 assetValueInUSDT =              amountAsset
                                                    .mul(unitPrice)
                                                    .div(collateral.priceUnit);
        // asset value in OURO
        uint256 assetValueInOuro = assetValueInUSDT.mul(OURO_PRICE_UNIT)
                                                    .div(ouroPrice);
                                                    
        return assetValueInOuro;
    }

    /**
     * ======================================================================================
     * 
     * @dev OURO's deposit & withdraw
     *
     * ======================================================================================
     */
     
    /**
     * @dev user deposit assets and receive OURO
     * @notice users need approve() assets to this contract
     */
    function deposit(IERC20 token, uint256 amountAsset) external payable tryRebase {
        
        (CollateralInfo memory collateral, bool valid) = findCollateral(token);
        require(valid, "not a collateral");

        // for native token, use msg.value instead
        if (address(token) == router.WETH()) {
            require(msg.value > 0, "0 deposit");
            amountAsset = msg.value;
        }
        
        // calc equivalent OURO value
        uint256 assetValueInOuro = lookupAssetOUROValue(collateral, amountAsset);
        
        // check issuance limit
        uint month = block.timestamp.sub(issueFrom).div(MONTH);
        if (month < issueSchedule.length) {
            require(assetValueInOuro + ouroContract.totalSupply()
                        <=
                    uint256(issueSchedule[month]).mul(issueUnit),
                    "issuance limited"
            );
        }
        
        // transfer token assets to this contract
        if (address(token) != router.WETH()) {
            token.safeTransferFrom(msg.sender, address(this), amountAsset);
        }
                                        
        // mint OURO to sender
        ouroContract.mint(msg.sender, assetValueInOuro);
        
        // log
        emit Deposit(msg.sender, assetValueInOuro);
    }
    
    /**
     * @dev user swap his OURO back to assets
     * @notice users need approve() OURO assets to this contract
     */
    function withdraw(IERC20 token, uint256 amountAsset) external tryRebase {
        (CollateralInfo memory collateral, bool valid) = findCollateral(token);
        require(valid, "not a collateral");
        
        // calc equivalent OURO value
        uint256 assetValueInOuro = lookupAssetOUROValue(collateral, amountAsset);
                                                    
        // check if we have insufficient assets to return to user
        uint256 assetBalance = token.balanceOf(address(this));
        
        if (assetBalance >= amountAsset) {
            
            // transfer OURO to this contract
            ouroContract.safeTransferFrom(msg.sender, address(this), assetValueInOuro);
            
            // burn OURO
            ouroContract.burn(assetValueInOuro);

        } else {
            
            // if we don't have enough assets to return
            // we buy extra assets from swaps with user's OURO
            uint256 assetsToBuy = amountAsset.sub(assetBalance);
            
            // current asset value in ouro(in our vault)
            uint256 currentAssetValueInOuro = lookupAssetOUROValue(collateral, assetBalance);
    
            // find how many extra OUROs required to swap assets out
            address[] memory path = new address[](2);
            path[0] = address(this);
            path[1] = address(token);
            
            uint [] memory amounts = router.getAmountsIn(assetsToBuy, path);
            uint256 ouroRequired = amounts[0];
            
            // transfer total OURO to this contract
            ouroContract.safeTransferFrom(msg.sender, address(this), ouroRequired.add(currentAssetValueInOuro));
    
            // buy assets back to this contract
            if (address(token) == router.WETH()) {
                router.swapTokensForExactETH(assetsToBuy, ouroRequired, path, address(this), block.timestamp);
            } else {
                // swap out tokens out to OURO contract
                router.swapTokensForExactTokens(assetsToBuy, ouroRequired, path, address(this), block.timestamp);
            }
            
            // only burn the vault part
            ouroContract.burn(currentAssetValueInOuro);
        }
        
        if (address(token) == router.WETH()) {
            payable(msg.sender).sendValue(amountAsset);
        } else {
            // transfer back assets
            token.safeTransfer(msg.sender, amountAsset);
        }
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
    uint public buyBackRatio = 70; // 70% to buy back OGS
    
    // CollateralInfo
    struct CollateralInfo {
        IERC20 token;
        uint256 priceUnit; // usually 1e18
        uint256 lastPrice; // record latest collateral price
        AggregatorV3Interface priceFeed; // asset price feed for xxx/USDT
        bool approvedToRouter;
    }
    
    // registered collaterals for OURO
    CollateralInfo [] public collaterals;
    
    // mark OGS approved to router
    bool public ogsApprovedToRouter;
    
    // record last Rebase time
    uint public lastRebaseTimestamp = block.timestamp;
    
    // rebase period
    uint public rebasePeriod = DAY;

    // multiplier
    uint constant MULTIPLIER = 1e12;

    /**
     * set rebase period
     */
    function setRebasePeriod(uint period) external onlyOwner {
        require(period > 0);
        rebasePeriod = period;
    }
    
    /**
     * rebase
     */
    function rebase() public {
         // rebase period check
        require(lastRebaseTimestamp + rebasePeriod < block.timestamp,"aggressive rebase");
        
        // rebase collaterals
        _rebase();
        // book keeping after rebase
        _bookkeeping();
        // update time
        lastRebaseTimestamp += rebasePeriod;
        
        // log
        emit Rebased(msg.sender);
    }
 
    /**
     * @dev rebase is the stability dynamic for ouro
     */
    function _rebase() internal {
        // get total collateral value(USDT)
        uint256 totalCollateralValue = _getTotalCollateralValue();
        // get total OURO value(USDT)
        uint256 totalOUROValue = ouroContract.totalSupply()
                                        .mul(getPrice())
                                        .div(OURO_PRICE_UNIT);
        
        // compute values deviates
        if (totalCollateralValue >= totalOUROValue.mul(100+threshold).div(100)) {
            // collaterals has excessive value to OURO value, 
            // 70% of the extra collateral would be used to BUY BACK OGS on secondary markets 
            // and conduct a token burn
            uint256 excessiveValue = totalCollateralValue.sub(totalOUROValue)
                                                        .div(100);
                                                        
            // check if price has already reached monthly limit 
            uint256 priceUpperLimit = ouroPriceAtMonthStart
                                            .mul(100+appreciationLimit)
                                            .div(100);
                                            
            // conduct a ouro default price change                                
            if (ouroPrice < priceUpperLimit) {
                // However, since there is a 3% limit on how much the OURO Default Exchange Price can increase per month, 
                // only [100,000,000*0.03 = 3,000,000] BUSD worth of excess assets can be utilized. This 3,000,000 BUSD worth of 
                // assets will remain in the Reserve Pool, while the remaining [50,000,000-3,000,000=47,000,000] BUSD worth 
                // of assets will be used for OGS buyback and burns. 
                
                // (limit - current ouro price) / current ouro price
                // eg : (1.03 - 1.01) / 1.01 = 0.0198
                uint256 ouroRisingSpace = priceUpperLimit.sub(ouroPrice)  // non-negative substraction
                                                    .mul(MULTIPLIER)
                                                    .div(ouroPrice);

                // maxiumum values required to raise price to limit;
                uint256 ouroApprecationValueLimit = ouroRisingSpace
                                                    .mul(totalOUROValue)
                                                    .div(MULTIPLIER);
                
                // maximum excessive value usable (30%)
                uint256 maximumUsableValue = excessiveValue
                                                    .mul(100-buyBackRatio);
                
                // use the smaller one to appreciate OURO
                uint256 valueToAppreciate = ouroApprecationValueLimit < maximumUsableValue?ouroApprecationValueLimit:maximumUsableValue;
                
                // value appreciation:
                // ouroPrice = ouroPrice * (totalOUROValue + appreciateValue) / totalOUROValue
                ouroPrice = ouroPrice.mul(totalOUROValue+valueToAppreciate).div(totalOUROValue);
                
                // substract excessiveValue
                excessiveValue = excessiveValue.sub(valueToAppreciate);
            }
            
            if (excessiveValue > 0) {
                // rebalance the collaterals
                _executeRebalance(true, excessiveValue);
                
                // finally we need to update all collateral prices after rebalancing
                _updateCollateralPrices();
            }
            
        } else if (totalCollateralValue <= totalOUROValue.mul(100-threshold).div(100)) {
            // collaterals has less value to OURO value, mint new OGS to buy assets
            uint256 valueDeviates = totalOUROValue.sub(totalCollateralValue);
            
            // rebalance the collaterals
            _executeRebalance(false, valueDeviates);
            
            // finally we need to update all collateral prices after rebalancing
            _updateCollateralPrices();
        }
    }
    
    /**
     * @dev value deviates, execute buy back operations
     */
    function _executeRebalance(bool buyOGS, uint256 valueDeviates) internal {
        uint256 deviatedCollateralValue = _getTotalDeviatedValue(buyOGS);
        
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
            uint256 slotBuyBackValue = slotValue.mul(valueDeviates)
                                        .div(deviatedCollateralValue);
                                
            // execute different buyback operations
            if (buyOGS) {
                _buybackOGSWithCollateral(collateral, slotBuyBackValue);
            } else {
                _buybackCollateralWithOGS(collateral, slotBuyBackValue);
            }
        }
    }
    
    /**
     * @dev update prices to latest 
     */
    function _updateCollateralPrices() internal {
        for (uint i=0;i<collaterals.length;i++) {
            CollateralInfo storage collateral = collaterals[i];
            collateral.lastPrice = getAssetPrice(collateral.priceFeed);
        }
    }
    
    /**
     * @dev book keeping after rebase
     */
    function _bookkeeping() internal {
        if (block.timestamp < ouroLastPriceUpdate + ouroPriceUpdatePeriod) {
            return;
        }
        
        // update price for next month
        ouroLastPriceUpdate = block.timestamp;
        ouroPriceAtMonthStart = ouroPrice;
    }
       
    /**
     * @dev get total collateral value
     */
    function _getTotalCollateralValue() internal view returns(uint256) {
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
        
        return totalCollateralValue;
    }
    
    /**
     * @dev get total deviated collateral value
     */
    function _getTotalDeviatedValue(bool buyOGS) internal view returns(uint256) {
        // count total deviated collateral value 
        uint256 deviatedCollateralValue;
        for (uint i=0;i<collaterals.length;i++) {
            CollateralInfo storage collateral = collaterals[i];
            
            // check new price of the assets & omit those not deviated assets
            uint256 newPrice = getAssetPrice(collateral.priceFeed);
            if (buyOGS) {
                //  omit assets deviated negatively
                if (newPrice < collateral.lastPrice) {
                    continue;
                }
            } else {
                // omit assets deviated positively
                if (newPrice > collateral.lastPrice) {
                    continue;
                }
            }
            
            if (address(collateral.token) == router.WETH()) {
                // native assets, such as:
                // ETH on ethereum , BNB on binance smart chain
                deviatedCollateralValue += getAssetPrice(collateral.priceFeed)
                                        .mul(address(ouroContract).balance)
                                        .div(collateral.priceUnit);
            } else {
                // ERC20 assets (tokens)
                deviatedCollateralValue += getAssetPrice(collateral.priceFeed)
                                        .mul(collateral.token.balanceOf(address(ouroContract)))
                                        .div(collateral.priceUnit);
            }
        }
        
        return deviatedCollateralValue;
    }
    
    /**
     * @dev buy back OGS with collateral
     */
    function _buybackOGSWithCollateral(CollateralInfo storage collateral, uint256 slotValue) internal {
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
    function _buybackCollateralWithOGS(CollateralInfo storage collateral, uint256 slotValue) internal {
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
    
    /**
     * ======================================================================================
     * 
     * @dev OURO's events
     *
     * ======================================================================================
     */
     event Deposit(address account, uint256 ouroAmount);
     event Withdraw(address account, address token, uint256 assetAmount);
     event Rebased(address account);
}