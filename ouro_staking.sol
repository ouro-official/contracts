// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./library.sol";

/**
 * @dev OURO Staking contract
 */
contract OUROStaking is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint;
    
    uint256 internal constant SHARE_MULTIPLIER = 1e12; // share multiplier to avert division underflow
    
    address public constant ouroContract = 0x19D11637a7aaD4bB5D1dA500ec4A31087Ff17628; 
    address public constant ogsContract = 0x19F521235CaBAb5347B137f9D85e03D023Ccc76E;
    address public constant ogsPaymentAccount = 0xffA2320b690E0456862f543eC10f6c51fC0Aac99;
    address public immutable vestingContract;

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
    constructor() public {
        vestingContract = address(new OUROVesting());
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
     * @dev stake OURO
     */
    function deposit(uint256 amount) external {
        // settle previous rewards
        settleStaker(msg.sender);
        
        // transfer asset from AssetContract
        IERC20(ouroContract).safeTransferFrom(msg.sender, address(this), amount);
        _balances[msg.sender] += amount;
        _totalStaked += amount;
        
        // log
        emit Deposit(msg.sender, amount);
    }
    
    /**
     * @dev vest rewards
     */
    function vestReward() external {
        // settle previous rewards
        settleStaker(msg.sender);
        
        // reward balance modification
        uint amountReward = _rewardBalance[msg.sender];
        delete _rewardBalance[msg.sender]; // zero reward balance

        // vest reward to sender
        IOUROVesting(vestingContract).vest(msg.sender, amountReward);

        // log
        emit RewardVested(msg.sender, amountReward);
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
        IERC20(ouroContract).safeTransfer(msg.sender, amount);
        
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
        uint penalty = IERC20(ogsContract).balanceOf(address(this));

        // reward share
        uint roundShare = penalty.add(mintedReward)
                                    .mul(SHARE_MULTIPLIER)
                                    .div(_totalStaked);
                                
        // mark block rewarded;
        _lastRewardBlock = block.number;
            
        // accumulate reward share
        _accShares[_currentRound] = roundShare.add(_accShares[_currentRound-1]); 
        
        // IMPORTANT:
        // transfer penalty to ogsPaymentAccount after setting reward share
        IERC20(ogsContract).safeTransfer(ogsPaymentAccount, penalty);
       
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
        uint penalty = IERC20(ogsContract).balanceOf(address(this));
        uint accountCollateral = _balances[account];
        uint lastSettledRound = _settledRounds[account];
        
        // reward = settled rewards + unsettled rewards + newMined rewards
        uint unsettledShare = _accShares[_currentRound-1].sub(_accShares[lastSettledRound]);
        
        uint newMinedShare;
        if (_totalStaked > 0) {
            uint blocksToReward = block.number.sub(_lastRewardBlock);
            uint mintedReward = BlockReward.mul(blocksToReward);
    
            // reward share
            newMinedShare = penalty.add(mintedReward)
                                    .mul(SHARE_MULTIPLIER)
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
     event RewardVested(address account, uint256 amount);
     event BlockRewardSet(uint256 reward);
}


/**
 * @dev OURO Vesting contract
 */
contract OUROVesting is Ownable, IOUROVesting {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    uint256 internal constant DAY = 1 days;
    uint256 internal constant VestingPeriod = DAY * 90;
    
    address public constant ogsContract = 0x19F521235CaBAb5347B137f9D85e03D023Ccc76E;
    address public constant ogsPaymentAccount = 0xffA2320b690E0456862f543eC10f6c51fC0Aac99;
    
    // @dev vesting assets are grouped by day
    struct Round {
        mapping (address => uint256) balances;
        uint startDate;
    }
    
    /// @dev round index mapping
    mapping (int256 => Round) public rounds;
    /// @dev a monotonic increasing index
    int256 public currentRound = 0;

    /// @dev current vested rewards    
    mapping (address => uint256) private balances;
    
    /**
    * ======================================================================================
    * 
    * SYSTEM FUNCTIONS
    * 
    * ======================================================================================
    */
    constructor() public {
        rounds[0].startDate = block.timestamp;
    }

    /**
     * @dev round update operation
     */
    function _update() internal {
        uint numDays = block.timestamp.sub(rounds[currentRound].startDate).div(DAY);
        if (numDays > 0) {
            currentRound++;
            rounds[currentRound].startDate = rounds[currentRound-1].startDate + numDays * DAY;
        }
    }
    
    /**
     * ======================================================================================
     * 
     * VESTING FUNCTIONS
     *
     * ======================================================================================
     */
     
    /**
     * @dev vest some OGS tokens for an account
     */
    function vest(address account, uint256 amount) external override onlyOwner {
        _update();

        rounds[currentRound].balances[account] += amount;
        balances[account] += amount;
        
        // emit amount vested
        emit Vested(account, amount);
    }
    
 
    /**
     * @dev claim unlocked rewards without penalty
     */
    function claimUnlocked() external {
        _update();
        
        uint256 unlockedAmount = checkUnlocked(msg.sender);
        balances[msg.sender] -= unlockedAmount;
        IERC20(ogsContract).safeTransferFrom(ogsPaymentAccount, msg.sender, unlockedAmount);
        
        emit Claimed(msg.sender, unlockedAmount);
    }

    /**
     * @dev claim all rewards with penalty(50%)
     */
    function claimAllWithPenalty() external {
        _update();
        
        uint256 lockedAmount = checkLocked(msg.sender);
        uint256 penalty = lockedAmount/2;
        uint256 rewardsToClaim = balances[msg.sender].sub(penalty);

        // reset balances which still locked to 0
        uint256 earliestVestedDate = block.timestamp - VestingPeriod;
        for (int256 i= currentRound; i>=0; i--) {
            if (rounds[i].startDate < earliestVestedDate) {
                break;
            } else {
                delete rounds[i].balances[msg.sender];
            }
        }
        
        // reset user's total balance to 0
        delete balances[msg.sender];
        
        // transfer rewards to msg.sender        
        if (rewardsToClaim > 0) {
            IERC20(ogsContract).safeTransferFrom(ogsPaymentAccount, msg.sender, rewardsToClaim);
            emit Claimed(msg.sender, rewardsToClaim);
        }
        
        // 50% penalty token goes to OURO staking contract(which is owner)
        if (penalty > 0) {
            IERC20(ogsContract).safeTransferFrom(ogsPaymentAccount, owner(), penalty);
            emit Penalty(msg.sender, penalty);
        }
    }

    /**
     * ======================================================================================
     * 
     * VIEW FUNCTIONS
     *
     * ======================================================================================
     */
    
    /**
     * @dev check total vested token
     */
    function checkVested(address account) public view returns(uint256) { return balances[account]; }
    
    /**
     * @dev check current locked token
     */
    function checkLocked(address account) public view returns(uint256) {
        uint256 earliestVestedDate = block.timestamp - VestingPeriod;
        uint256 lockedAmount;
        for (int256 i= currentRound; i>=0; i--) {
            if (rounds[i].startDate < earliestVestedDate) {
                break;
            } else {
                lockedAmount += rounds[i].balances[account];
            }
        }
        
        return lockedAmount;
    }

    /**
     * @dev check current claimable rewards without penalty
     */
    function checkUnlocked(address account) public view returns(uint256) {
        uint256 lockedAmount = checkLocked(account);
        return balances[account].sub(lockedAmount);
    }
    
    /**
     * @dev Events
     * ----------------------------------------------------------------------------------
     */
    event Vestable(address account);
    event Unvestable(address account);
    event Penalty(address account, uint256 amount);
    event Vested(address account, uint256 amount);
    event Claimed(address account, uint256 amount);
}