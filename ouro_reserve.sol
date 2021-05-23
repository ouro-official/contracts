// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./library.sol";

/**
 * @notice OURO reserve
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
    uint256 public OURO_PRICE_UNIT = 1e18; // 1 OURO = 1e18
    
    uint256 internal constant MONTH = 30 days;
    uint public appreciationLimit = 3; // 3 percent monthly OURO price appreciation limit
    uint public ouroLastPriceUpdate = block.timestamp;
    uint public ouroPriceUpdatePeriod = MONTH;

    IOUROToken public ouroContract = IOUROToken(0xEe5bCf20a21e0539Da126d8c86531E7BeE25933F);
    IOGSToken public ogsContract = IOGSToken(0xEe5bCf20a21e0539Da126d8c86531E7BeE25933F);
    IERC20 public usdtContract = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 public cakeContract = IERC20(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);

    IPancakeRouter02 public router = IPancakeRouter02(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    uint256 constant internal MAX_UINT256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    
    // @dev issue schedule in million(1e6) OURO
    uint16 [] public issueSchedule = [10,30,50,70,100,150,200,300,400,500,650,800];
    uint256 internal constant issueUnit = 1e18 * 1e6;
    
    // @dev scheduled issue from
    uint256 public issueFrom = block.timestamp;
    
    // CollateralInfo
    struct CollateralInfo {
        IERC20 token;
        address vTokenAddress;
        uint256 assetUnit; // usually 1e18
        uint256 lastPrice; // record latest collateral price
        AggregatorV3Interface priceFeed; // asset price feed for xxx/USDT
        bool approvedToRouter;
    }
    
    // registered collaterals for OURO
    CollateralInfo [] public collaterals;
    
    // a mapping to track the balance of assets;
    mapping (address => uint256) private _assetsBalance;
    
    // try rebase for user's deposit and withdraw
    modifier tryRebase() {
        if (lastRebaseTimestamp + rebasePeriod >= block.timestamp) {
            rebase();
        }
        _;    
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
    function getPrice() public override returns(uint256) { return ouroPrice; }
    
    /**
     * @dev get asset price in USDT(decimal=8) for 1 unit of asset
     */
    function getAssetPrice(AggregatorV3Interface feed) public view returns(uint256) {
        // always align the price to BUSD decimal, which is 1e18
        uint256 priceAlignMultiplier = 1e18 / (10**uint256(feed.decimals()));
        
        // query price from chainlink
        (, int latestPrice, , , ) = feed.latestRoundData();

        // avert negative price
        if (latestPrice > 0) {
            return uint256(latestPrice).mul(priceAlignMultiplier);
        }
        return 0;
    }
    
    /**
     * @dev user deposit assets and receive OURO
     * @notice users need approve() assets to this contract
     */
    function deposit(IERC20 token, uint256 amountAsset) external override payable tryRebase {
        
        // locate collateral
        (CollateralInfo memory collateral, bool valid) = _findCollateral(token);
        require(valid, "not a valid collateral");

        // for native token, omit amountAsset and use msg.value instead
        if (address(token) == router.WETH()) {
            require(msg.value > 0, "0 deposit");
            amountAsset = msg.value;
        }
        
        // get equivalent OURO value
        uint256 assetValueInOuro = _lookupAssetValueInOURO(collateral, amountAsset);
        
        // check monthly OURO issuance limit
        uint monthN = block.timestamp.sub(issueFrom).div(MONTH);
        if (monthN < issueSchedule.length) { // still needs control
            require(assetValueInOuro + ouroContract.totalSupply() 
                        <=
                    uint256(issueSchedule[monthN]).mul(issueUnit),
                    "issuance limited"
            );
        }
        
        // transfer token assets to this contract
        // @notice for ERC20 assets, users need to approve() to this reserve contract 
        if (address(token) != router.WETH()) {
            token.safeTransferFrom(msg.sender, address(this), amountAsset);
        }
                                        
        // mint OURO to sender
        ouroContract.mint(msg.sender, assetValueInOuro);
        
        // update asset balance
        _assetsBalance[address(token)] += amountAsset;
        
        // log
        emit Deposit(msg.sender, assetValueInOuro);
        
        // finally we farm the assets
        _farmDeposit(collateral, amountAsset);
    }
    
    /**
     * @dev farm the user's deposit
     */
    function _farmDeposit(CollateralInfo memory collateral, uint256 amountAsset) internal {
        // CAKE will be transferred to PancakeSwap’s “Auto CAKE” pool to earn CAKE rewards. 
        // other assets will be transferred to Venus to earn yield from lending. 
        if (collateral.token != cakeContract) {
            _supplyToVenus(collateral.vTokenAddress, amountAsset);
        }
    }
    
    /**
     * @dev user swap his OURO back to assets
     * @notice users need approve() OURO assets to this contract
     */
    function withdraw(IERC20 token, uint256 amountAsset) external override tryRebase {
        
        // locate collateral
        (CollateralInfo memory collateral, bool valid) = _findCollateral(token);
        require(valid, "not a collateral");
                                                    
        // check if we have sufficient assets to return to user
        uint256 assetBalance = _assetsBalance[address(token)];
        
        // perform OURO token burn
        if (assetBalance >= amountAsset) {
            // redeem assets
            _redeemToWithdraw(collateral, amountAsset);
                    
            // sufficent asset satisfied! transfer user's equivalent OURO to this contract directly
            uint256 assetValueInOuro = _lookupAssetValueInOURO(collateral, amountAsset);
            ouroContract.safeTransferFrom(msg.sender, address(this), assetValueInOuro);
            
            // and burn OURO.
            ouroContract.burn(assetValueInOuro);

        } else {
            
            // insufficient assets, redeem ALL
            _redeemToWithdraw(collateral, assetBalance);
            
            // redeemed assets value in OURO
            uint256 redeemedAssetValue = _lookupAssetValueInOURO(collateral, assetBalance);
            
            // as we don't have enough assets to return to user
            // we buy extra assets from swaps with user's OURO
            uint256 extraAssets = amountAsset.sub(assetBalance);
    
            // find how many extra OUROs required to swap the extra assets out
            // path:
            //  (??? ouro) -> WETH -> token
            address[] memory path = new address[](2);
            path[0] = address(ouroContract);
            path[1] = router.WETH(); // always use native asset(BNB) to bridge
            path[2] = address(token);
            
            uint [] memory amounts = router.getAmountsIn(extraAssets, path);
            uint256 extraOuroRequired = amounts[0];
            
            // @notice user needs sufficient OURO to swap assets out
            // transfer total OURO to this contract, if user has insufficient OURO, the transaction will revert!
            uint256 totalOuroToBurn = extraOuroRequired.add(redeemedAssetValue);
            ouroContract.safeTransferFrom(msg.sender, address(this), totalOuroToBurn);
    
            // buy assets back to this contract
            // path:
            //  ouro-> WETH -> token
            if (address(token) == router.WETH()) {
                router.swapTokensForExactETH(extraAssets, extraOuroRequired, path, address(this), block.timestamp);
            } else {
                // swap out tokens out to OURO contract
                router.swapTokensForExactTokens(extraAssets, extraOuroRequired, path, address(this), block.timestamp);
            }
            
            // burn OURO
            ouroContract.burn(totalOuroToBurn);
        }
        
        // finally we transfer the assets based on assset type back to user
        if (address(token) == router.WETH()) {
            msg.sender.sendValue(amountAsset);
        } else {
            token.safeTransfer(msg.sender, amountAsset);
        }
        
        // update asset balance
        _assetsBalance[address(token)] -= amountAsset;
        
        // log withdraw
        emit Withdraw(msg.sender, address(token), amountAsset);
    }
    
    /**
     * @dev redeem assets from farm
     */
    function _redeemToWithdraw(CollateralInfo memory collateral, uint256 amountAsset) internal {
        // CAKE will be transferred to PancakeSwap’s “Auto CAKE” pool to earn CAKE rewards. 
        // other assets will be transferred to Venus to earn yield from lending. 
        if (collateral.token != cakeContract) {
            _removeSupplyFromVenus(collateral.vTokenAddress, amountAsset);
        }
    }

    /**
     * @dev find the given collateral info
     */
    function _findCollateral(IERC20 token) internal view returns (CollateralInfo memory, bool) {
        uint n = collaterals.length;
        for (uint i=0;i<n;i++) {
            if (collaterals[i].token == token){
                return (collaterals[i], true);
            }
        }
    }
    
    /**
     * @dev find the given collateral info
     */
    function _lookupAssetValueInOURO(CollateralInfo memory collateral, uint256 amountAsset) internal view returns (uint256 amountOURO) {
        // get asset value in USDT
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
     * @dev supply assets to venus and get vToken
     */
    function _supplyToVenus(address vTokenAddress, uint256 amount) internal {
        if (vTokenAddress == router.WETH()) {
            IVBNB(vTokenAddress).mint{value: amount}();
        } else {
            IVToken(vTokenAddress).mint(amount);
        }
    }
    
    /**
     * @dev remove supply buy redeeming vToken
     */
    function _removeSupplyFromVenus(address vTokenAddress, uint256 amount) internal {
        IVToken(vTokenAddress).redeemUnderlying(amount);
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
    uint public threshold = 3;
    uint public OGSbuyBackRatio = 70; // 70% to buy back OGS
    
    // mark OGS approved to router
    bool public ogsApprovedToRouter;
    
    // record last Rebase time
    uint public lastRebaseTimestamp = block.timestamp;
    
    // rebase period
    uint public rebasePeriod = 1 days;

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
                                                    .mul(100-OGSbuyBackRatio);
                
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
                                        .div(collateral.assetUnit);
                                    
            } else {
                slotValue = getAssetPrice(collateral.priceFeed)
                                        .mul(collateral.token.balanceOf(address(ouroContract)))
                                        .div(collateral.assetUnit);
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
                                        .div(collateral.assetUnit);
            } else {
                // ERC20 assets (tokens)
                totalCollateralValue += getAssetPrice(collateral.priceFeed)
                                        .mul(collateral.token.balanceOf(address(ouroContract)))
                                        .div(collateral.assetUnit);
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
                                        .div(collateral.assetUnit);
            } else {
                // ERC20 assets (tokens)
                deviatedCollateralValue += getAssetPrice(collateral.priceFeed)
                                        .mul(collateral.token.balanceOf(address(ouroContract)))
                                        .div(collateral.assetUnit);
            }
        }
        
        return deviatedCollateralValue;
    }
    
    /**
     * @dev buy back OGS with collateral
     */
    function _buybackOGSWithCollateral(CollateralInfo storage collateral, uint256 slotValue) internal {
        uint256 collateralToBuyOGS = slotValue
                                        .mul(collateral.assetUnit)
                                        .div(getAssetPrice(collateral.priceFeed));

        // the path to swap OGS out
        address[] memory path = new address[](2);
        path[0] = address(collateral.token);
        path[1] = router.WETH(); // always use native asset(BNB) to bridge
        path[2] = address(ogsContract);
        
        // calc amount OGS that could be swapped out with given collateral
        uint [] memory amounts = router.getAmountsOut(collateralToBuyOGS, path);
        uint256 ogsAmountOut = amounts[2];
        
        if (address(collateral.token) == router.WETH()) {
            
            // swap OGS out with native assets to THIS contract
            router.swapExactETHForTokens{value:collateralToBuyOGS}(ogsAmountOut, path, address(this), block.timestamp);
            
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
                                        .mul(collateral.assetUnit)
                                        .div(getAssetPrice(collateral.priceFeed));
                                             
        // the path to swap collateral out
        address[] memory path = new address[](2);
        path[0] = address(ogsContract);
        path[1] = router.WETH(); // always use native asset(BNB) to bridge
        path[2] = address(collateral.token);
        
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
     * ======================================================================================
     * 
     * OURO Reserve's events
     *
     * ======================================================================================
     */
     event Deposit(address account, uint256 ouroAmount);
     event Withdraw(address account, address token, uint256 assetAmount);
     event Rebased(address account);
}