// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./library.sol";

/**
 * @dev OURO Vesting contract
 */
contract OUROVesting is Ownable, IOUROVesting {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    uint256 internal constant DAY = 1 days;
    uint256 internal constant VestingPeriod = DAY * 90;
    
    address public ouroStakingContract;
    address public constant ogsContract = 0x19F521235CaBAb5347B137f9D85e03D023Ccc76E;
    address public constant ogsPaymentAccount = 0xffA2320b690E0456862f543eC10f6c51fC0Aac99;
    
    // @dev vestable group
    mapping(address => bool) public vestableGroup;
    
    modifier onlyVestableGroup() {
        require(vestableGroup[msg.sender], "not in vestable group");
        _;
    }
    
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
     * @dev set or remove address to vestable group
     */
    function setVestable(address account, bool allow) external onlyOwner {
        vestableGroup[account] = allow;
        if (allow) {
            emit Vestable(account);
        }  else {
            emit Unvestable(account);
        }
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
    function vest(address account, uint256 amount) external override onlyVestableGroup {
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
        
        // 50% penalty token goes to OURO staking contract
        if (penalty > 0) {
            IERC20(ogsContract).safeTransferFrom(ogsPaymentAccount, ouroStakingContract, penalty);
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