// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "library.sol";

/**
 * Users can stake CAKE, BNB, BUSD, BTCB to earn free OURO. Assets deposited will be transferred to our yield farming contract, 
 * which utilizes PancakeSwap and Venus. Yield from these pools will be transferred to the reserve pool when the user 
 * claims it, and OURO of equivalent value will be minted thereafter to the user. Users can withdraw any 
 * asset staked with no cost other than incurred BSC transaction fees. 
 */
contract AssetStaking is Ownable {
    using SafeERC20 for IERC20;
    using SafeERC20 for IOGSToken;
    using SafeMath for uint;
    
    uint256 internal constant SHARE_MULTIPLIER = 1e12; // share multiplier to avert division underflow
    
    IERC20 public AssetContract; // the asset to stake
    
    IOUROToken public OUROContract; // the OURO token contract
    IOGSToken public OGSContract; // the OGS token contract
    address public immutable vTokenAddress; // venus vToken Address
    
    address public constant wbnbAddress = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant unitroller = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address public constant ouroDynamicsAddress = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address public constant xvsAddress = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;

    // pancake router
    IPancakeRouter02 public router = IPancakeRouter02(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    
    address[] venusMarkets; // venus market, set at constructor
    mapping (address => uint256) private _balances; // tracking staker's value
    mapping (address => uint256) internal _rewardBalance; // tracking staker's claimable reward tokens
    uint256 private _totalStaked; // track total staked value
    
    /// @dev initial block reward set to 0
    uint256 public BlockReward = 0;
    
    /// @dev shares user can claim
    struct Shares{
        uint256 ouroShare;
        uint256 ogsShare;
    }
    
    /// @dev round index mapping to accumulate share.
    mapping (uint => Shares) private _accShares;
    /// @dev mark staker's highest settled round.
    mapping (address => uint) private _settledRounds;
    /// @dev a monotonic increasing round index, STARTS FROM 1
    uint256 private _currentRound = 1;
    // @dev last rewarded block
    uint256 private _lastRewardBlock = block.number;
    
    constructor(IOGSToken ogsContract, IERC20 assetContract, address vTokenAddress_) public {
        if (address(assetContract) == router.WETH()) {
            isNativeToken = true;
        }
        
        AssetContract = assetContract; 
        OGSContract = ogsContract;
        vTokenAddress = vTokenAddress_;
        
        venusMarkets.push(vTokenAddress_);
        IVenusDistribution(unitroller).enterMarkets(venusMarkets);
    }

    /**
     * @dev stake some assets
     */
    function stake(uint256 amount) external {
        // settle previous rewards
        settleStaker(msg.sender);
        
        // transfer asset from AssetContract
        AssetContract.safeTransferFrom(msg.sender, address(this), amount);
        _balances[msg.sender] += amount;
        _totalStaked += amount;
    }
    
    /**
     * @dev claim rewards only
     */
    function claimRewards() external {
        // settle previous rewards
        settleStaker(msg.sender);
        
        // reward balance modification
        uint amountReward = _rewardBalance[msg.sender];
        delete _rewardBalance[msg.sender]; // zero reward balance

        // mint reward to sender
        OGSContract.mint(msg.sender, amountReward);
    }
    
    /**
     * @dev withdraw the staked assets
     */
    function withdraw(uint256 amount) external {
        require(amount <= _balances[msg.sender], "balance exceeded");

        // settle previous rewards
        settleStaker(msg.sender);

        // modifiy
        _balances[msg.sender] -= amount;
        _totalStaked -= amount;
        
        // transfer assets back
        AssetContract.safeTransfer(msg.sender, amount);
    }

    /**
     * @dev return value staked for an account
     */
    function numStaked(address account) external view returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev return total staked value
     */
    function totalStaked() external view returns (uint256) {
        return _totalStaked;
    }
    
    /**
     * @notice sum unclaimed reward;
     */
    function checkOGSReward(address account) external view returns(uint256 rewards) {
        uint accountCollateral = _balances[account];
        uint lastSettledRound = _settledRounds[account];
        
        // reward = settled rewards + unsettled rewards + newMined rewards
        uint unsettledShare = _accShares[_currentRound-1].ogsShare.sub(_accShares[lastSettledRound].ogsShare);
        
        uint newMinedShare;
        if (_totalStaked > 0) {
            uint blocksToReward = block.number.sub(_lastRewardBlock);
            uint mintedReward = BlockReward.mul(blocksToReward);
    
            // reward share
            newMinedShare = mintedReward.mul(SHARE_MULTIPLIER)
                                        .div(_totalStaked);
        }
        
        return _rewardBalance[account] + (unsettledShare + newMinedShare).mul(accountCollateral)
                                            .div(SHARE_MULTIPLIER);  // remember to div by SHARE_MULTIPLIER;
    }
    
    /**
     * @dev set block reward
     */
    function setBlockReward(uint256 reward) external onlyOwner {
        // settle previous rewards
        updateReward();
        // set new block reward
        BlockReward = reward;
    }
    
    /**
     * @dev settle a staker
     */
    function settleStaker(address account) internal {
        // update reward snapshot
        updateReward();
        
        // settle this account
        uint accountCollateral = _balances[account];
        uint lastSettledRound = _settledRounds[account];
        uint newSettledRound = _currentRound - 1;
        
        // round rewards
        uint roundReward = _accShares[newSettledRound].ogsShare.sub(_accShares[lastSettledRound].ogsShare)
                                .mul(accountCollateral)
                                .div(SHARE_MULTIPLIER);  // remember to div by SHARE_MULTIPLIER    
        
        // update reward balance
        _rewardBalance[account] += roundReward;
        
        // mark new settled reward round
        _settledRounds[account] = newSettledRound;
    }
     
     /**
     * @dev update accumulated block reward until current block
     */
    function updateReward() internal {
        // skip round changing in the same block
        if (_lastRewardBlock == block.number) {
            return;
        }
    
        // postpone rewarding if there is none staker
        if (_totalStaked == 0) {
            return;
        }
        
        // ogs reward
        _updateOGSReward();
       
        // ouro reward
        _updateOuroReward();
        
        // next round setting                                 
        _currentRound++;
    }
    
    function _updateOuroReward() internal {
        // setp 1. settle venus XVS reward
        IVenusDistribution(unitroller).claimVenus(address(this), venusMarkets);
        
        // exchange XVS to assets
        address[] memory path = new address[](2);
        path[0] = xvsAddress;
        path[1] = router.WETH(); // always use native assets to bridge
        path[2] = address(AssetContract);

        // swap all XVS to assets
        uint256 xvsAmount = IERC20(xvsAddress).balanceOf(address(this));
        uint [] memory amounts = router.getAmountsOut(xvsAmount, path);
        uint256 assetOut = amounts[1];
        
        if (isNativeToken) {
            // swap out native assets ETH, BNB with XVS
            router.swapTokensForExactETH(assetOut, xvsAmount, path, address(this), block.timestamp);

        } else {
            // swap out assets out
            router.swapTokensForExactTokens(assetOut, xvsAmount, path, address(this), block.timestamp);
        }

        // step 2.check if farming has assets revenue        
        uint256 underlyingBalance;
         if (isNativeToken) {
            underlyingBalance = IVBNB(vTokenAddress).balanceOfUnderlying(address(this));
        } else {
            underlyingBalance = IVToken(vTokenAddress).balanceOfUnderlying(address(this));
        }
        
        // the diff is the assets revenue
        uint256 asssetsRevenue;
        if (underlyingBalance > _totalStaked) {
            asssetsRevenue = underlyingBalance.sub(_totalStaked);
            if (isNativeToken) {
                IVBNB(vTokenAddress).redeemUnderlying(asssetsRevenue);
            } else {
                IVToken(vTokenAddress).redeemUnderlying(asssetsRevenue);
            }
        }
        
        // step 3. exchange above 2 types of revenue to OURO
        uint256 totalRevenue = asssetsRevenue + assetOut;
        uint256 ouroBalance = OUROContract.balanceOf(address(this));
        if (isNativeToken) {
            IOURODynamics(ouroDynamicsAddress).deposit{value:totalRevenue}(AssetContract, 0);
        } else {
            IOURODynamics(ouroDynamicsAddress).deposit(AssetContract, totalRevenue);
        }
        
        // step 4. compute diff for new ouro and set share based on current stakers pro-rata
        uint256 newMintedOuro = OUROContract.balanceOf(address(this)).sub(ouroBalance);
                
        // OURO share
        uint roundShareOURO = newMintedOuro.mul(SHARE_MULTIPLIER)
                                        .div(_totalStaked);
                                        
        // ouro revenue
        _accShares[_currentRound].ouroShare = roundShareOURO.add(_accShares[_currentRound-1].ouroShare); 
    }
    
    function _updateOGSReward() internal {
        // settle reward share for [_lastRewardBlock, block.number]
        uint blocksToReward = block.number.sub(_lastRewardBlock);
        uint mintedReward = BlockReward.mul(blocksToReward);

        // reward share
        uint roundShareOGS = mintedReward.mul(SHARE_MULTIPLIER)
                                        .div(_totalStaked);
                                        
        // mark block rewarded;
        _lastRewardBlock = block.number;
            
        // accumulate reward shares
        _accShares[_currentRound].ogsShare = roundShareOGS.add(_accShares[_currentRound-1].ogsShare); 
    }
    
    /**
     * ======================================================================================
     * 
     * @dev Venus farming
     * https://github.com/VenusProtocol/venus-config/blob/master/networks/testnet.json
     * https://github.com/VenusProtocol/venus-config/blob/master/networks/mainnet.json
     *
     * ======================================================================================
     */
    bool public isNativeToken = false;
    
    /**
     * @dev supply assets to venus and get vToken
     */
    function _supply(uint256 amount) internal {
        if (isNativeToken) {
            IVBNB(vTokenAddress).mint{value: amount}();
        } else {
            IVToken(vTokenAddress).mint(amount);
        }
    }
    
    /**
     * @dev remove supply buy redeeming vToken
     */
    function _removeSupply(uint256 amount) internal {
        IVToken(vTokenAddress).redeemUnderlying(amount);
    }
}