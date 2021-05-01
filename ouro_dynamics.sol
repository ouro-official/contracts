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

    AggregatorV3Interface public priceFeedBNB; // chainlink price feed

    uint constant internal MAX_SWAP_LATENCY = 60; // 1 minutes
    uint256 constant internal MAX_UINT256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    
    // 1. The system will only mint new OGS and sell them for collateral when the value of the 
    //    assets held in the pool is more than 3% less than the value of the issued OURO.
    // 2. The system will only use excess collateral in the pool to conduct OGS buy back and 
    //    burn when the value of the assets held in the pool is 3% higher than the value of the issued OURO
    uint public threshold = 3;
    
    /**
     * @dev update is the stability dynamic for ouro
     */
    function update() external {
        // get assets in OURO contract
        uint256 totalBNB = address(ouroContract).balance;
        uint256 totalOURO = ouroContract.totalSupply();
        
        // compute value priced in USDT
        uint256 ouroValue = getOUROPrice().mul(totalOURO);
        uint256 collateralValue = getBNBPrice().mul(totalBNB);

        // value adjustment        
        if (collateralValue >= ouroValue.mul(100+threshold).div(100)) {
            
            // collaterals has excessive value to OURO value, 
            // 70% of the extra collateral would be used to BUY BACK OGS on secondary markets 
            // and conduct a token burn
            uint256 bnbToBuyOGS = collateralValue.sub(ouroValue)
                                                    .mul(70).div(100)
                                                    .div(getBNBPrice());
            
            // transfer BNB from OURO contract to this contract temporarily.
            ouroContract.acquireBNB(bnbToBuyOGS);
            
            // the path to swap OGS out
            address[] memory path = new address[](2);
            path[0] = router.WETH();
            path[1] = address(ogsContract);
            
            // calc amount OGS that could be swapped out with given BNB
            uint [] memory amounts = router.getAmountsOut(bnbToBuyOGS, path);
            uint256 ogsAmountOut = amounts[1];

            // swap OGS out to this contract
            router.swapTokensForExactTokens(bnbToBuyOGS, ogsAmountOut, path, address(this), block.timestamp.add(MAX_SWAP_LATENCY));
            
            // burn OGS
            ogsContract.burn(ogsAmountOut);
    
        } else if (collateralValue <= ouroValue.mul(100-threshold).div(100)) {


            // collaterals has less value to OURO value, mint new OGS to buy assets
            uint256 bnbToBuyBack = ouroValue.sub(collateralValue)
                                                .div(getBNBPrice());
                                             
            // the path to swap BNB out
            address[] memory path = new address[](2);
            path[0] = address(ogsContract);
            path[1] = router.WETH();
            
            // calc amount OGS required to swap out given BNB amount
            uint [] memory amounts = router.getAmountsIn(bnbToBuyBack, path);
            uint256 ogsRequired = amounts[0];
                        
            // mint OGS to this contract to buy back BNB                             
            ogsContract.mint(address(this), ogsRequired);

            // swap out BNB with OGS to OURO contract
            router.swapTokensForExactTokens(ogsRequired, bnbToBuyBack, path, address(ouroContract), block.timestamp.add(MAX_SWAP_LATENCY));
        }
    }
    
    // get USDT price for 1 OURO (1e18)
    function getOUROPrice() public view returns(uint256) {
        return 1e18;
    }
    
    // get USDT price for 1 BNB (1e18)
    function getBNBPrice() public view returns(uint256) {
        (, int latestPrice, , , ) = priceFeedBNB.latestRoundData();

        if (latestPrice > 0) { // assume USDT & BNB decimal = 18
            return uint(latestPrice);
        }
        return 0;
    }
}