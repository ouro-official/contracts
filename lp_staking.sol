
// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "library.sol";

/**
 * @dev LP staking to earn free OGS
 * LP rewards for different pair
 * OURO/BNB
 * OURO/CAKE
 * OURO/BUSD
 * OGS/BNB
 * OGS/CAKE
 * OGS/BTCB
 * OGS/BUSD
 * ....
 */
contract LPStaking is Ownable {
    using SafeERC20 for IERC20;
    using SafeERC20 for IOGSToken;
    using SafeMath for uint;
    
    uint256 internal constant SHARE_MULTIPLIER = 1e18; // share multiplier to avert division underflow
    
    IERC20 public AssetContract; // the asset to stake
    IOGSToken public OGSContract; // the OGS token contract

    mapping (address => uint256) private _balances; // tracking staker's value
    mapping (address => uint256) internal _rewardBalance; // tracking staker's claimable reward tokens
    uint256 private _totalStaked; // track total staked value
    
    /// @dev initial block reward
    uint256 public BlockReward = 0;
    
    /// @dev round index mapping to accumulate share.
    mapping (uint => uint) private _accShares;
    /// @dev mark staker's highest settled round.
    mapping (address => uint) private _settledRounds;
    /// @dev a monotonic increasing round index, STARTS FROM 1
    uint256 private _currentRound = 1;
    // @dev last rewarded block
    uint256 private _lastRewardBlock = block.number;
    
    constructor(IOGSToken ogsContract, IERC20 assetContract) public {
        AssetContract = assetContract; 
        OGSContract = ogsContract;
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
}