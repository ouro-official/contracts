// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./library.sol";

contract OURODist is IOURODist, Ownable {
    using SafeMath for uint;
    using SafeERC20 for IERC20;
    
    address public constant usdtContract = 0x55d398326f99059fF775485246999027B3197955;
    IOUROToken public constant ouroContract = IOUROToken(0x18221Fa6550E6Fd6EfEb9b4aE6313D07Acd824d5);
    IOGSToken public constant ogsContract = IOGSToken(0x0d06E5Cb94CC56DdAd96bF7100F01873406959Ba);
    IPancakeRouter02 public constant router = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address immutable internal WETH = router.WETH();
    uint256 constant internal swapDelay = 600;
    
    receive() external payable {}
    
    mapping(address => bool) public hasApproved;
    uint256 constant internal MAX_UINT256 = uint256(-1);

    constructor() public {
        // approve USDT
        IERC20(usdtContract).safeApprove(address(router), 0); 
        IERC20(usdtContract).safeIncreaseAllowance(address(router), MAX_UINT256);
        
        // approve OGS
        IERC20(ogsContract).safeApprove(address(router), 0); 
        IERC20(ogsContract).safeIncreaseAllowance(address(router), MAX_UINT256);
    }
     
    /** 
     * @dev reset allowance for special token
     */
    function resetAllowance(address token) external override onlyOwner {
       IERC20(token).safeApprove(address(router), 0); 
       IERC20(token).safeIncreaseAllowance(address(router), MAX_UINT256);
    }
    
    /**
     * @dev notify of revenue arrival
     */
    function revenueArrival(address token, uint256 revenueAmount) external override {
        if (!hasApproved[token]) {
            IERC20(token).safeApprove(address(router), 0); 
            IERC20(token).safeIncreaseAllowance(address(router), MAX_UINT256);
            hasApproved[token] = true;
        }
        
        // 50% - OGS token buy back and burn.
        uint256 revenueToBuyBackOGS = revenueAmount
                                    .mul(50)
                                    .div(100);
        _revenueToBuyBackOGS(token, revenueToBuyBackOGS);
        
        // 50% - Split to form LP tokens for the platform. 
        uint256 revenueToFormLP = revenueAmount.sub(revenueToBuyBackOGS);
        _revenueToFormLP(token, revenueToFormLP);
    }
    
    /**
     * @dev revenue to buy back OGS
     */
    function _revenueToBuyBackOGS(address token, uint256 assetAmount) internal {
       // buy back OGS
       address[] memory path;
       if (token == usdtContract) {
           path = new address[](2);
           path[0] = token;
           path[1] = address(ogsContract);
       } else {
           path = new address[](3);
           path[0] = token;
           path[1] = usdtContract; // use USDT to bridge
           path[2] = address(ogsContract);
       }

       uint [] memory amounts;
       // the path to swap OGS out
       // path:
       //  collateral -> USDT -> exact OGS
       if (token == WETH) {
           
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
    }

     /**
     * @dev revenue to form LP token
     */
    function _revenueToFormLP(address token, uint256 assetAmount) internal {
       // buy back OGS
       address[] memory path;
       if (token == usdtContract) {
           path = new address[](2);
           path[0] = token;
           path[1] = address(ogsContract);
       } else {
           path = new address[](3);
           path[0] = token;
           path[1] = usdtContract; // use USDT to bridge
           path[2] = address(ogsContract);
       }
       
       // half of the asset to buy OGS
       uint256 assetToBuyOGS = assetAmount.div(2);
           
       // the path to swap OGS out
       if (token == WETH) {
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

       // the rest revenue will be used to buy USDT
       if (token != usdtContract) {
           path = new address[](2);
           path[0] = token;
           path[1] = usdtContract; 
           
           // half of the asset to buy USDT
           uint256 assetToBuyUSDT = assetAmount.div(2);
           
           // the path to swap USDT out
           // path:
           //  collateral -> USDT
           if (token == WETH) {
               router.swapExactETHForTokens{value:assetToBuyUSDT}(
                   0, 
                   path, 
                   address(this), 
                   block.timestamp.add(swapDelay)
               );
               
           } else {
               router.swapExactTokensForTokens(
                   assetToBuyUSDT, 
                   0, 
                   path, 
                   address(this), 
                   block.timestamp.add(swapDelay)
               );
           }
        }
        
       // add liquidity to router
       // note we always use the maximum possible 
       uint256 token0Amt = IERC20(ogsContract).balanceOf(address(this));
       uint256 token1Amt = IERC20(usdtContract).balanceOf(address(this));
       router.addLiquidity(
           address(ogsContract),
           usdtContract,
           token0Amt,
           token1Amt,
           0,
           0,
           address(this),
           block.timestamp.add(swapDelay)
       );
    }
}