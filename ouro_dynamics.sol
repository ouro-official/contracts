// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./library.sol";

interface IPancakeFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}

// helper methods for interacting with ERC20 tokens and sending ETH that do not consistently return true/false
library TransferHelper {
    function safeApprove(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('approve(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: APPROVE_FAILED');
    }

    function safeTransfer(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FAILED');
    }

    function safeTransferFrom(address token, address from, address to, uint value) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FROM_FAILED');
    }

    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'TransferHelper: ETH_TRANSFER_FAILED');
    }
}

interface IPancakeRouter01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IPancakeRouter02 is IPancakeRouter01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

/**
 * @notice OURO stability dynamics 
 */
contract OURODynamics {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IOUROToken;
    using SafeERC20 for IOGSToken;
    using Address for address payable;

    IPancakeRouter02 public router = IPancakeRouter02(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    IOUROToken public ouroContract = IOUROToken(0xEe5bCf20a21e0539Da126d8c86531E7BeE25933F);
    IOGSToken public ogsContract = IOGSToken(0xEe5bCf20a21e0539Da126d8c86531E7BeE25933F);
    IERC20 public usdtContract = IERC20(0x55d398326f99059fF775485246999027B3197955);

    uint256 public OURO_PRICE_UNIT = 1e18;

    uint constant internal MAX_SWAP_LATENCY = 1; // swap should be done immediately
    uint256 constant internal MAX_UINT256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    
    // 1. The system will only mint new OGS and sell them for collateral when the value of the 
    //    assets held in the pool is more than 3% less than the value of the issued OURO.
    // 2. The system will only use excess collateral in the pool to conduct OGS buy back and 
    //    burn when the value of the assets held in the pool is 3% higher than the value of the issued OURO
    uint public threshold = 3;
    
    // CollateralInfo
    struct CollateralInfo {
        IERC20 token;
        bool isNative; // native asset
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
            
            if (collateral.isNative) {
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
            if (collateral.isNative) {
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
                buybackOGS(collateral, slotBuyBackValue);
            } else {
                buybackCollateral(collateral, slotBuyBackValue);
            }
        }
    }
    
    /**
     * @dev buy back OGS with collateral
     */
    function buybackOGS(CollateralInfo storage collateral, uint256 slotValue) internal {
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
        
        if (collateral.isNative) {
            // for native assets, call ouro contract to transfer ETH, BNB to THIS contract
            ouroContract.acquireNative(collateralToBuyOGS);

            // swap OGS out with native assets to THIS contract
            payable(address(router)).functionCallWithValue(
                abi.encodeWithSelector(router.swapExactETHForTokens.selector, ogsAmountOut, path, address(this), block.timestamp.add(MAX_SWAP_LATENCY)),
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
            router.swapExactTokensForTokens(collateralToBuyOGS, ogsAmountOut, path, address(this), block.timestamp.add(MAX_SWAP_LATENCY));
        }

        // burn OGS
        ogsContract.burn(ogsAmountOut);
    }
    
    /**
     * @dev buy back collateral with OGS
     */
    function buybackCollateral(CollateralInfo storage collateral, uint256 slotValue) internal {
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

        if (collateral.isNative) {
            // swap out native assets ETH, BNB with OGS to OURO contract
            router.swapTokensForExactETH(ogsRequired, collateralToBuyBack, path, address(ouroContract), block.timestamp.add(MAX_SWAP_LATENCY));

        } else {
            // swap out tokens out to OURO contract
            router.swapTokensForExactTokens(ogsRequired, collateralToBuyBack, path, address(ouroContract), block.timestamp.add(MAX_SWAP_LATENCY));
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