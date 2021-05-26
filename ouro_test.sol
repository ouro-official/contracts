// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./ouro_reserve.sol";
import "./ouro_dist.sol";

contract OUROReserveTest is OUROReserve {
    function testbuybackOGS(address token ,address vTokenAddress, uint256 assetUnit, AggregatorV3Interface priceFeed, uint256 slotValue) public onlyOwner {
        _buybackOGS(token, vTokenAddress, assetUnit, priceFeed, slotValue);
    }
        
    function testbuybackCollateral(address token ,address vTokenAddress, uint256 assetUnit, AggregatorV3Interface priceFeed, uint256 slotValue) public onlyOwner {
        _buybackCollateral(token, vTokenAddress, assetUnit, priceFeed, slotValue);
    }
    
    function testSetRebasePeriod(uint period) external onlyOwner {
        require(period > 0, "period 0");
        rebasePeriod = period;
    }
            
    function testSetPriceLimitResetPeriod(uint period) external onlyOwner {
        require(period > 0, "period 0");
        ouroPriceResetPeriod = period;
    }
    function testSetOuroIssuePeriod(uint period) external onlyOwner {
        require(period > 0, "period 0");
        ouroIssuePeriod = period;
    }
}