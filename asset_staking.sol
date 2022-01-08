// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "./library.sol";

/**
 * Users can stake CAKE, BNB, BUSD, BTCB to earn free OURO. Assets deposited will be transferred to our yield farming contract, 
 * which utilizes PancakeSwap and Venus. Yield from these pools will be transferred to the reserve pool when the user 
 * claims it, and OURO of equivalent value will be minted thereafter to the user. Users can withdraw any 
 * asset staked with no cost other than incurred BSC transaction fees. 
 */
contract AssetStaking is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using SafeMath for uint;
    using Address for address payable;

    
    uint256 internal constant SHARE_MULTIPLIER = 1e18; // share multiplier to avert division underflow
    
    address public immutable assetContract; // the asset to stake
    address public immutable vTokenAddress; // venus vToken Address
    
    address public constant ouroContract = 0x0a4FC79921f960A4264717FeFEE518E088173a79;
    address public constant ogsContract = 0x416947e6Fc78F158fd9B775fA846B72d768879c2;
    address public constant unitroller = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address public constant ouroReserveAddress = 0x8739aBC0be4f271A5f4faC825BebA798Ee03f0CA;
    address public constant xvsAddress = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;

    // pancake router
    IPancakeRouter02 public constant router = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    uint256 constant internal MAX_UINT256 = uint256(-1);
    
    address[] venusMarkets; // venus market, set at constructor
    mapping (address => uint256) private _balances; // tracking staker's value
    uint256 private _totalStaked; // track total staked value
    
    /// @dev initial block reward set to 0
    uint256 public BlockReward = 0;
    
    /// @dev shares of user
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
    
    // 2 types of reward
    // @dev ogs reward balance, settle but not claimed
    mapping (address => uint256) internal _ogsRewardBalance;
    // @dev ouro reward balance, settle but not claimed
    mapping (address => uint256) internal _ouroRewardBalance;

    /**
     * ======================================================================================
     * 
     * SYSTEM FUNCTIONS
     *
     * ======================================================================================
     */
    receive() external payable {}
    
    constructor(address assetContract_, address vTokenAddress_) public {
        require(assetContract_ != address(0), "constructor: assetContract_ is zero address");        
        if (assetContract_ == router.WETH()) {
            isNativeToken = true;
        }
        
        // set addresses
        assetContract = assetContract_; 
        vTokenAddress = vTokenAddress_;
        
        venusMarkets.push(vTokenAddress_);
        IVenusDistribution(unitroller).enterMarkets(venusMarkets);

        if (!isNativeToken) {
            // check underlying asset for non native token
            require(assetContract_ == IVToken(vTokenAddress_).underlying(), "underlying asset does not match assetContract");

            // approve asset to OURO reserve
            IERC20(assetContract_).safeApprove(ouroReserveAddress, MAX_UINT256); 

            // approve asset to vToken
            IERC20(assetContract_).safeApprove(vTokenAddress_, MAX_UINT256);
        }
        
        // approve XVS to router
        IERC20(xvsAddress).safeApprove(address(router), MAX_UINT256); 
    }
    
    /** 
     * @dev reset allowances
     */
    function resetAllowances() external onlyOwner {
        if (!isNativeToken) {
            // re-approve asset to OURO reserve
            IERC20(assetContract).safeApprove(ouroReserveAddress, 0); 
            IERC20(assetContract).safeIncreaseAllowance(ouroReserveAddress, MAX_UINT256);
            
            // re-approve asset to vToken
            IERC20(assetContract).safeApprove(vTokenAddress, 0);
            IERC20(assetContract).safeIncreaseAllowance(vTokenAddress, MAX_UINT256);
        }
            
        // re-approve XVS to router
        IERC20(xvsAddress).safeApprove(address(router), 0); 
        IERC20(xvsAddress).safeApprove(address(router), MAX_UINT256);
        
        // log
        emit AllowanceReset();
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
     * @dev called by the owner to pause, triggers stopped state
     **/
    function pause() onlyOwner external { _pause(); }

    /**
    * @dev called by the owner to unpause, returns to normal state
    */
    function unpause() onlyOwner external { _unpause(); }

    /**
     * ======================================================================================
     * 
     * STAKING FUNCTIONS
     *
     * ======================================================================================
     */
     
    /**
     * @dev deposit assets
     */
    function deposit(uint256 amount) external payable nonReentrant whenNotPaused {
        // only from EOA
        require(!msg.sender.isContract() && msg.sender == tx.origin);

        if (isNativeToken) {
            amount = msg.value;
        }
        require(amount > 0, "zero deposit");
        
        // settle previous rewards
        settleStaker(msg.sender);
        
        // modify balance
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        _totalStaked = _totalStaked.add(amount);
        
        // transfer asset from AssetContract
        if (!isNativeToken) {
            IERC20(assetContract).safeTransferFrom(msg.sender, address(this), amount);
        }

        // supply the asset to venus
        _supply(amount);
        
        // log
        emit Deposit(msg.sender, amount);
    }
    
    /**
     * @dev claim OGS rewards only
     */
    function claimOGSRewards() external nonReentrant whenNotPaused {
        // settle previous rewards
        settleStaker(msg.sender);
        
        // reward balance modification
        uint amountReward = _ogsRewardBalance[msg.sender];
        delete _ogsRewardBalance[msg.sender]; // zero reward balance
        require(amountReward > 0, "0 reward");

        // mint OGS reward to sender
        IOGSToken(ogsContract).mint(msg.sender, amountReward);
        
        // log
        emit OGSClaimed(msg.sender, amountReward);
    }
    
    /**
     * @dev claim OURO rewards only
     */
    function claimOURORewards() external nonReentrant whenNotPaused {
        // settle previous rewards
        settleStaker(msg.sender);
        
        // reward balance modification
        uint amountReward = _ouroRewardBalance[msg.sender];
        delete _ouroRewardBalance[msg.sender]; // zero reward balance
        require(amountReward > 0, "0 reward");

        // transfer OURO to sender
        IERC20(ouroContract).safeTransfer(msg.sender, amountReward);
        
        // log
        emit OUROClaimed(msg.sender, amountReward);
    }

    /**
     * @dev withdraw assets
     */
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0 && amount <= _balances[msg.sender], "balance exceeded");

        // settle previous rewards
        settleStaker(msg.sender);

        // modifiy
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        _totalStaked = _totalStaked.sub(amount);
        
        // balance - before
        uint256 numRedeemed;
        if (isNativeToken) {
            numRedeemed = address(this).balance;
        } else {
            numRedeemed = IERC20(assetContract).balanceOf(address(this));
        }

        // redeem supply from venus
        // NOTE:
        //  venus may return less than amount
        _removeSupply(amount);

        if (isNativeToken) {    
            // balance - after
            numRedeemed = address(this).balance.sub(numRedeemed);
            // transfer assets back
            msg.sender.sendValue(numRedeemed);
        } else { // ERC20
            numRedeemed = IERC20(assetContract).balanceOf(address(this)).sub(numRedeemed);
            IERC20(assetContract).safeTransfer(msg.sender, numRedeemed);
        }

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
        
        // a) round ogs rewards
        uint roundOGSReward = _accShares[newSettledRound].ogsShare.sub(_accShares[lastSettledRound].ogsShare)
                                .mul(accountCollateral)
                                .div(SHARE_MULTIPLIER);  // remember to div by SHARE_MULTIPLIER    
        
        // update ogs reward balance
        _ogsRewardBalance[account] += roundOGSReward;

        // b) round ouro rewards
        uint roundOUROReward = _accShares[newSettledRound].ouroShare.sub(_accShares[lastSettledRound].ouroShare)
                                .mul(accountCollateral)
                                .div(SHARE_MULTIPLIER);  // remember to div by SHARE_MULTIPLIER            
        
        // update ouro reward balance
        _ouroRewardBalance[account] += roundOUROReward;
        
        // mark this account has settled to newSettledRound
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
    
    /**
     * @dev update ouro reward for current stakers(snapshot)
     * this function should be implemented as idempotent way
     */
    function _updateOuroReward() internal {
        // step 0. record current asset balance(which users deposit)
        uint256 assetBalance;
        if (isNativeToken) {
            assetBalance = address(this).balance;
        } else {
            assetBalance = IERC20(assetContract).balanceOf(address(this));
        }
        
        // setp 1. settle venus XVS reward
        uint256 xvsAmount = IERC20(xvsAddress).balanceOf(address(this));
        IVenusDistribution(unitroller).claimVenus(address(this), venusMarkets);
        xvsAmount = IERC20(xvsAddress).balanceOf(address(this)).sub(xvsAmount);

        if (xvsAmount > 0 ) { 
            // swap all XVS to staking asset
            address[] memory path;
            if (isNativeToken) { // XVS -> WBNB
                path = new address[](2);
                path[0] = xvsAddress;
                path[1] = assetContract;
            } else { // XVS-> WBNB -> asset
                path = new address[](3);
                path[0] = xvsAddress;
                path[1] = router.WETH(); // use WBNB to bridge
                path[2] = assetContract;
            }
            if (isNativeToken) {
                router.swapExactTokensForETH(
                    xvsAmount, 
                    0, 
                    path, 
                    address(this), 
                    block.timestamp.add(600)
                );
            } else {
                router.swapExactTokensForTokens(
                    xvsAmount, 
                    0, 
                    path, 
                    address(this), 
                    block.timestamp.add(600)
                );
            }
        }

        // step 2.check if farming has assets revenue        
        uint256 underlyingBalance = IVToken(vTokenAddress).balanceOfUnderlying(address(this));
        if (underlyingBalance > _totalStaked) { 
            // the diff is the assets revenue
            uint256 asssetsRevenue = underlyingBalance.sub(_totalStaked);
            // proceed redeeming
            // NOTE: 
            //  just use redeemUnderlying w/o return value check,
            //  even if venus has insufficent liquidity, this process cannot be stopped.
            if (asssetsRevenue > 0) {
                IVToken(vTokenAddress).redeemUnderlying(asssetsRevenue);
            }
        }
        
        // step 3. exchange above 2 types of revenue to OURO
        uint256 currentOUROBalance = IERC20(ouroContract).balanceOf(address(this));
        uint256 currentAsset;
        if (isNativeToken) {
            currentAsset = address(this).balance;
        } else {
            currentAsset = IERC20(assetContract).balanceOf(address(this));
        }
        
        // === THE DIFF IS THE FARMING REVENUE TO SWAP TO OURO ===
        if (currentAsset > assetBalance) {
            uint256 diff = currentAsset.sub(assetBalance);
            if (isNativeToken) {
                IOUROReserve(ouroReserveAddress).deposit{value:diff}(assetContract, 0, 0);
            } else {
                IOUROReserve(ouroReserveAddress).deposit(assetContract, diff, 0);
            }
        }
        // === END THE DIFF IS THE FARMING REVENUE TO SWAP TO OURO ===
        
        // step 4. compute diff for new ouro and set share based on current stakers pro-rata
        uint256 newMintedOuro = IERC20(ouroContract).balanceOf(address(this))
                                            .sub(currentOUROBalance);
                
        uint roundShareOURO = newMintedOuro.mul(SHARE_MULTIPLIER) // avert underflow
                                            .div(_totalStaked);
                                        
        _accShares[_currentRound].ouroShare = roundShareOURO.add(_accShares[_currentRound-1].ouroShare); 
    }
    
    /**
     * @dev update OGS token reward for current stakers(snapshot)
     * this function should be implemented as idempotent way
     */
    function _updateOGSReward() internal {
        // settle reward share for (_lastRewardBlock, block.number]
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
     * @notice sum unclaimed OURO reward;
     */
    function checkOUROReward(address account) external view returns(uint256 rewards) { return _ouroRewardBalance[account]; }
    
    /**
     * @notice sum unclaimed OGS reward;
     */
    function checkOGSReward(address account) external view returns(uint256 rewards) {
        uint accountCollateral = _balances[account];
        uint lastSettledRound = _settledRounds[account];
        
        // reward = settled rewards + unsettled rewards + newMined rewards
        uint unsettledShare = _accShares[_currentRound-1].ogsShare.sub(_accShares[lastSettledRound].ogsShare);
        
        uint newMinedShare;
        if (_totalStaked > 0) {
            uint blocksToReward = block.number
                                            .sub(_lastRewardBlock);
                                            
            uint mintedReward = BlockReward
                                            .mul(blocksToReward);
    
            // reward share
            newMinedShare = mintedReward
                                            .mul(SHARE_MULTIPLIER)
                                            .div(_totalStaked);
        }
        
        return _ogsRewardBalance[account] + (unsettledShare + newMinedShare).mul(accountCollateral)
                                            .div(SHARE_MULTIPLIER);  // remember to div by SHARE_MULTIPLIER;
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
    bool public isNativeToken;
    
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
     * @dev remove supply by redeeming vToken
     */
    function _removeSupply(uint256 amount) internal {
        require(IVToken(vTokenAddress).redeemUnderlying(amount) == 0, "cannot redeem from venus");
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
     event OUROClaimed(address account, uint256 amount);
     event OGSClaimed(address account, uint256 amount);
     event BlockRewardSet(uint256 reward);
     event AllowanceReset();
}

contract AssetStakingTest is AssetStaking {
      constructor(address assetContract_, address vTokenAddress_) 
      AssetStaking(assetContract_, vTokenAddress_)
      public {
      }
      
      function updateOGSReward() public {
          _updateOGSReward();   
      }
    
        function updateOuroReward() public {
          _updateOuroReward();   
      }
      
}