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
    IOGSToken public OGSContract; // the OGS token contract
    address public vTokenAddress; // venus vToken Address
    
    address public constant wbnbAddress = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant Unitroller = 0xfD36E2c2a6789Db23113685031d7F16329158384;

    mapping (address => uint256) private _balances; // tracking staker's value
    mapping (address => uint256) internal _rewardBalance; // tracking staker's claimable reward tokens
    uint256 private _totalStaked; // track total staked value
    
    /// @dev initial block reward set to 0
    uint256 public BlockReward = 0;
    
    /// @dev round index mapping to accumulate share.
    mapping (uint => uint) private _accShares;
    /// @dev mark staker's highest settled round.
    mapping (address => uint) private _settledRounds;
    /// @dev a monotonic increasing round index, STARTS FROM 1
    uint256 private _currentRound = 1;
    // @dev last rewarded block
    uint256 private _lastRewardBlock = block.number;
    
    constructor(IOGSToken ogsContract, IERC20 assetContract, address vTokenAddress_) public {
        if (address(assetContract) == wbnbAddress) {
            isNativeToken = true;
        }
        
        AssetContract = assetContract; 
        OGSContract = ogsContract;
        vTokenAddress = vTokenAddress_;
        
        // enter venus market
        address[] memory venusMarkets;
        venusMarkets[0]= vTokenAddress_;
        IVenusDistribution(Unitroller).enterMarkets(venusMarkets);
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
    function checkReward(address account) external view returns(uint256 rewards) {
        uint accountCollateral = _balances[account];
        uint lastSettledRound = _settledRounds[account];
        
        // reward = settled rewards + unsettled rewards + newMined rewards
        uint unsettledShare = _accShares[_currentRound-1].sub(_accShares[lastSettledRound]);
        
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
        uint roundReward = _accShares[newSettledRound].sub(_accShares[lastSettledRound])
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

        // settle reward share for [_lastRewardBlock, block.number]
        uint blocksToReward = block.number.sub(_lastRewardBlock);
        uint mintedReward = BlockReward.mul(blocksToReward);

        // reward share
        uint roundShare = mintedReward.mul(SHARE_MULTIPLIER)
                                        .div(_totalStaked);
                                
        // mark block rewarded;
        _lastRewardBlock = block.number;
            
        // accumulate reward share
        _accShares[_currentRound] = roundShare.add(_accShares[_currentRound-1]); 
       
        // next round setting                                 
        _currentRound++;
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