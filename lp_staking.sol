
// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "./library.sol";

/**
 * @dev LP staking related to OURO/xxx pair
 */
contract LPStaking is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint;
    
    uint256 internal constant SHARE_MULTIPLIER = 1e12; // share multiplier to avert division underflow
    
    address public assetContract; // the asset to stake
    address public constant ogsContract = 0x19F521235CaBAb5347B137f9D85e03D023Ccc76E;

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
    
    /**
     * ======================================================================================
     * 
     * SYSTEM FUNCTIONS
     *
     * ======================================================================================
     */
    constructor(address assetContract_) public {
        require(assetContract_ != address(0), "constructor： assetContract_ is zero address");

        assetContract = assetContract_; 
    }
        
    /**
     * @dev set block reward
     */
    function setBlockReward(uint256 reward) external onlyOwner {
        // settle previous rewards
        updateReward();
        // set new block reward
        BlockReward = reward;
            
        // log
        emit BlockRewardSet(reward);
    }
    
    /**
     * ======================================================================================
     * 
     * STAKING FUNCTIONS
     *
     * ======================================================================================
     */
     
    /**
     * @dev stake assets
     */
    function deposit(uint256 amount) external {
        // settle previous rewards
        settleStaker(msg.sender);
        
        // modifiy
        _balances[msg.sender] += amount;
        _totalStaked += amount;
        
        // transfer asset from AssetContract
        IERC20(assetContract).safeTransferFrom(msg.sender, address(this), amount);
        
        // log
        emit Deposit(msg.sender, amount);
    }
    
    /**
     * @dev claim rewards
     */
    function claimRewards() external {
        // settle previous rewards
        settleStaker(msg.sender);
        
        // reward balance modification
        uint amountReward = _rewardBalance[msg.sender];
        delete _rewardBalance[msg.sender]; // zero reward balance

        // mint reward to sender
        IOGSToken(ogsContract).mint(msg.sender, amountReward);
        
        // log
        emit OGSClaimed(msg.sender, amountReward);
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
        IERC20(assetContract).safeTransfer(msg.sender, amount);
        
        // log
        emit Withdraw(msg.sender, amount);
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
     * VIEW FUNCTIONS
     *
     * ======================================================================================
     */
        
    /**
     * @dev return value staked for an account
     */
    function numStaked(address account) external view returns (uint256) { return _balances[account]; }

    /**
     * @dev return total staked value
     */
    function totalStaked() external view returns (uint256) { return _totalStaked; }
     
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
     * ======================================================================================
     * 
     * STAKING EVENTS
     *
     * ======================================================================================
     */
     event Deposit(address account, uint256 amount);
     event Withdraw(address account, uint256 amount);
     event OGSClaimed(address account, uint256 amount);
     event BlockRewardSet(uint256 reward);
}