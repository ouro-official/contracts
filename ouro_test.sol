// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./ouro_reserve.sol";
import "./ouro_dist.sol";

contract OUROReserveTest is OUROReserve {
    function testFindCollateral(address token) internal view onlyOwner returns (CollateralInfo memory, bool) {
        return _findCollateral(token);
    }
    
    function testGetTotalCollateralValue() public view onlyOwner returns(uint256)  {
        return _getTotalCollateralValue();
    }
    
    function testLookupAssetValueInOURO(AggregatorV3Interface priceFeed, uint256 assetUnit, uint256 amountAsset) public view onlyOwner returns(uint256) {
        return _lookupAssetValueInOURO(priceFeed, assetUnit, amountAsset);
    }
    
    function testHandleExcessiveValue(uint256 totalCollateralValue, uint256 totalIssuedOUROValue) public onlyOwner {
        _handleExcessiveValue(totalCollateralValue, totalIssuedOUROValue);
    }
    
    function testExecuteRebalance(bool buyOGS, uint256 valueDeviates) public onlyOwner {
        _executeRebalance(buyOGS, valueDeviates);
    }
    
    function testbuybackOGS(address token ,address vTokenAddress, uint256 assetUnit, AggregatorV3Interface priceFeed, uint256 slotValue) public onlyOwner {
        _buybackOGS(token, vTokenAddress, assetUnit, priceFeed, slotValue);
    }
        
    function testbuybackCollateral(address token ,address vTokenAddress, uint256 assetUnit, AggregatorV3Interface priceFeed, uint256 slotValue) public onlyOwner {
        _buybackCollateral(token, vTokenAddress, assetUnit, priceFeed, slotValue);
    }
            
    function testSetPriceLimitResetPeriod(uint period) external onlyOwner {
        require(period > 0, "period 0");
        ouroPriceResetPeriod = period;
    }
    function testSetOuroIssuePeriod(uint period) external onlyOwner {
        require(period > 0, "period 0");
        ouroIssuePeriod = period;
    }
    
    function testDistributeXVS() external onlyOwner {
        _distributeXVS();
    }
    
    function testDistributeAssetRevenue() external onlyOwner {
        _distributeAssetRevenue();
    }
}