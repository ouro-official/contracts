// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./library.sol";

contract OURODist is IOURODist, Ownable {
    using SafeMath for uint;
    using SafeERC20 for IERC20;
    
    address public constant busdContract = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    IOUROToken public constant ouroContract = IOUROToken(0x19D11637a7aaD4bB5D1dA500ec4A31087Ff17628);
    IOGSToken public constant ogsContract = IOGSToken(0x19F521235CaBAb5347B137f9D85e03D023Ccc76E);
    IPancakeRouter02 public constant router = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address immutable internal WBNB = router.WETH();
    uint256 constant internal swapDelay = 600;
    
    receive() external payable {}
    
    uint256 constant internal MAX_UINT256 = uint256(-1);

    constructor() public {
        // approve USD
        IERC20(busdContract).safeIncreaseAllowance(address(router), MAX_UINT256);
        
        // approve OGS
        IERC20(ogsContract).safeIncreaseAllowance(address(router), MAX_UINT256);
    }
    
    /**
     * @dev add a function for sanity check
     */
    function isDist() external override view returns (bool) { return true; }
     
    /** 
     * @dev reset allowance for special token
     */
    function resetAllowance(address token) external override onlyOwner {
       IERC20(token).safeApprove(address(router), 0); 
       IERC20(token).safeIncreaseAllowance(address(router), MAX_UINT256);
       
       // log
       emit ResetAllowance(token);
    }
    
    /**
     * @dev notify of revenue arrival
     */
    function revenueArrival(address token, uint256 revenueAmount) external override {
        // lazy approve
        if (IERC20(token).allowance(address(this), address(router)) == 0) {
            IERC20(token).safeIncreaseAllowance(address(router), MAX_UINT256);
        }
        
        // 50% - OGS token buy back and burn.
        uint256 revenueToBuyBackOGS = revenueAmount
                                    .mul(50)
                                    .div(100);
        _revenueToBuyBackOGS(token, revenueToBuyBackOGS);
        
        // 50% - Split to form LP tokens for the platform. 
        uint256 revenueToFormLP = revenueAmount.sub(revenueToBuyBackOGS);
        _revenueToFormLP(token, revenueToFormLP);
        
        // log
        emit RevenuArrival(token, revenueAmount);
    }
    
    /**
     * @dev revenue to buy back OGS
     */
    function _revenueToBuyBackOGS(address token, uint256 assetAmount) internal {
       // buy back OGS
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

        // swap & burn
        if (assetAmount > 0) {
            uint [] memory amounts;
            if (token == WBNB) {
                // swap OGS out with native assets to THIS contract
                amounts = router.swapExactETHForTokens{value:assetAmount}(
                   0, 
                   path, 
                   address(this), 
                   block.timestamp.add(600)
                );
               
            } else {
               // swap OGS out to THIS contract
                amounts = router.swapExactTokensForTokens(
                   assetAmount, 
                   0,
                   path, 
                   address(this), 
                   block.timestamp.add(600)
               );
            }
    
            // burn OGS the actual swapped out
            ogsContract.burn(amounts[amounts.length - 1]);
           
            // log
            emit OGSBurned(amounts[amounts.length - 1]);
        }
    }

     /**
     * @dev revenue to form LP token
     */
    function _revenueToFormLP(address token, uint256 assetAmount) internal {
       // buy back OGS
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
       
       // half of the asset to buy OGS
       uint256 assetToBuyOGS = assetAmount.div(2);
  
        // swap & burn
        if (assetToBuyOGS > 0) {         
           // the path to swap OGS out
            if (token == WBNB) {
                router.swapExactETHForTokens{value:assetToBuyOGS}(
                   0, 
                   path, 
                   address(this), 
                   block.timestamp.add(swapDelay)
                );
               
            } else {
                router.swapExactTokensForTokens(
                   assetToBuyOGS, 
                   0, 
                   path, 
                   address(this), 
                   block.timestamp.add(swapDelay)
                );
            }
        }

       // the rest revenue will be used to buy USD
       if (token != busdContract) {
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
           
           // half of the asset to buy USD
           uint256 assetToBuyUSD = assetAmount.sub(assetToBuyOGS);
           
           if (assetAmount > 0) {
                if (token == WBNB) {
                    router.swapExactETHForTokens{value:assetToBuyUSD}(
                       0, 
                       path, 
                       address(this), 
                       block.timestamp.add(swapDelay)
                    );
                   
                } else {
                    router.swapExactTokensForTokens(
                       assetToBuyUSD, 
                       0, 
                       path, 
                       address(this), 
                       block.timestamp.add(swapDelay)
                    );
                }
           }
        }
        
       // add liquidity to router
       // note we always use the maximum possible 
       uint256 token0Amt = IERC20(ogsContract).balanceOf(address(this));
       uint256 token1Amt = IERC20(busdContract).balanceOf(address(this));
       
       if (token0Amt > 0 && token1Amt > 0) {
           (uint amountA, uint amountB, uint liquidity) = router.addLiquidity(
               address(ogsContract),
               busdContract,
               token0Amt,
               token1Amt,
               0,
               0,
               address(this),
               block.timestamp.add(swapDelay)
           );
           
           // log
           emit LiquidityAdded(amountA, amountB, liquidity);
       }
    }
    
    /**
     * ======================================================================================
     * 
     * OURO Distribution events
     *
     * ======================================================================================
     */
     event ResetAllowance(address token);
     event RevenuArrival(address token, uint256 amount);
     event OGSBurned(uint ogsAmount);
     event LiquidityAdded(uint ogsAmount, uint usdAmount, uint liquidity);
}