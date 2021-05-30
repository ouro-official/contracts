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
    using SafeMath for uint;
    
    uint256 internal constant SHARE_MULTIPLIER = 1e12; // share multiplier to avert division underflow
    
    address public AssetContract; // the asset to stake
    
    address public OUROContract; // the OURO token contract
    address public OGSContract; // the OGS token contract
    address public immutable vTokenAddress; // venus vToken Address
    
    address public constant wbnbAddress = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant unitroller = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address public constant ouroReserveAddress = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address public constant xvsAddress = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
    address public usdtContract = 0x55d398326f99059fF775485246999027B3197955;

    // pancake router
    IPancakeRouter02 public router = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
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

    constructor(address ogsContract, address assetContract, address vTokenAddress_) public {
        if (address(assetContract) == router.WETH()) {
            isNativeToken = true;
        }
        
        // set addresses
        AssetContract = assetContract; 
        OGSContract = ogsContract;
        vTokenAddress = vTokenAddress_;
        
        venusMarkets.push(vTokenAddress_);
        IVenusDistribution(unitroller).enterMarkets(venusMarkets);
        
        // approve OGS to router
        IERC20(OGSContract).safeApprove(address(router), MAX_UINT256); 

        // approve asset to OURO reserve
        IERC20(AssetContract).safeApprove(ouroReserveAddress, MAX_UINT256); 

        // approve asset to vToken
        IERC20(AssetContract).safeApprove(vTokenAddress_, MAX_UINT256);
        
        // approve XVS to router
        IERC20(xvsAddress).safeApprove(address(router), MAX_UINT256); 
    }
    
    /** 
     * @dev reset allowances
     */
    function resetAllowances() external onlyOwner {
        // re-approve OGS to router
        IERC20(OGSContract).safeApprove(address(router), 0); 
        IERC20(OGSContract).safeIncreaseAllowance(address(router), MAX_UINT256);
        
        // re-approve asset to OURO reserve
        IERC20(AssetContract).safeApprove(ouroReserveAddress, 0); 
        IERC20(AssetContract).safeIncreaseAllowance(ouroReserveAddress, MAX_UINT256);
        
        // re-approve asset to vToken
        IERC20(AssetContract).safeApprove(vTokenAddress, 0);
        IERC20(AssetContract).safeIncreaseAllowance(vTokenAddress, MAX_UINT256);
        
        // re-approve XVS to router
        IERC20(xvsAddress).safeApprove(address(router), 0); 
        IERC20(xvsAddress).safeApprove(address(router), MAX_UINT256);
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
     * ======================================================================================
     * 
     * STAKING FUNCTIONS
     *
     * ======================================================================================
     */
     
    /**
     * @dev deposit assets
     */
    function deposit(uint256 amount) external {
        // settle previous rewards
        settleStaker(msg.sender);
        
        // transfer asset from AssetContract
        IERC20(AssetContract).safeTransferFrom(msg.sender, address(this), amount);
        _balances[msg.sender] += amount;
        _totalStaked += amount;
        
        // supply the asset to venus
        _supply(amount);
    }
    
    /**
     * @dev claim OGS rewards only
     */
    function claimOGSRewards() external {
        // settle previous rewards
        settleStaker(msg.sender);
        
        // reward balance modification
        uint amountReward = _ogsRewardBalance[msg.sender];
        delete _ogsRewardBalance[msg.sender]; // zero reward balance

        // mint OGS reward to sender
        IOGSToken(OGSContract).mint(msg.sender, amountReward);
    }
    
    /**
     * @dev claim OURO rewards only
     */
    function claimOURORewards() external {
        // settle previous rewards
        settleStaker(msg.sender);
        
        // reward balance modification
        uint amountReward = _ouroRewardBalance[msg.sender];
        delete _ouroRewardBalance[msg.sender]; // zero reward balance

        // mint OGS reward to sender
        IERC20(OUROContract).safeTransfer(msg.sender, amountReward);
    }

    /**
     * @dev withdraw assets
     */
    function withdraw(uint256 amount) external {
        require(amount <= _balances[msg.sender], "balance exceeded");

        // settle previous rewards
        settleStaker(msg.sender);

        // modifiy
        _balances[msg.sender] -= amount;
        _totalStaked -= amount;
        
        // transfer assets back
        IERC20(AssetContract).safeTransfer(msg.sender, amount);
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
        // setp 1. settle venus XVS reward
        IVenusDistribution(unitroller).claimVenus(address(this), venusMarkets);
        
        // swap all XVS to staking asset
        address[] memory path;
        if (address(AssetContract) == usdtContract) {
            path = new address[](2);
            path[0] = xvsAddress;
            path[1] = address(AssetContract);
        } else {
            path = new address[](3);
            path[0] = xvsAddress;
            path[1] = usdtContract; // use USDT to bridge
            path[2] = address(AssetContract);
        }

        uint256 xvsAmount = IERC20(xvsAddress).balanceOf(address(this));
        uint256 [] memory amounts;
        if (isNativeToken) {
            amounts = router.swapExactTokensForETH(
                xvsAmount, 
                0, 
                path, 
                address(this), 
                block.timestamp.add(600)
            );
        } else {
            amounts = router.swapExactTokensForTokens(
                xvsAmount, 
                0, 
                path, 
                address(this), 
                block.timestamp.add(600)
            );
        }

        // step 2.check if farming has assets revenue        
        uint256 underlyingBalance;
         if (isNativeToken) {
            underlyingBalance = IVBNB(vTokenAddress).balanceOfUnderlying(address(this));
        } else {
            underlyingBalance = IVToken(vTokenAddress).balanceOfUnderlying(address(this));
        }
        
        uint256 asssetsRevenue;
        if (underlyingBalance > _totalStaked) { 
            // the diff is the assets revenue
            asssetsRevenue = underlyingBalance.sub(_totalStaked);
            if (isNativeToken) {
                IVBNB(vTokenAddress).redeemUnderlying(asssetsRevenue);
            } else {
                IVToken(vTokenAddress).redeemUnderlying(asssetsRevenue);
            }
        }
        
        // step 3. exchange above 2 types of revenue to OURO
        uint256 totalRevenue = asssetsRevenue + amounts[amounts.length-1];
        uint256 currentOUROBalance = IERC20(OUROContract).balanceOf(address(this));
        if (isNativeToken) {
            IOUROReserve(ouroReserveAddress).deposit{value:totalRevenue}(address(AssetContract), 0);
        } else {
            IOUROReserve(ouroReserveAddress).deposit(address(AssetContract), totalRevenue);
        }
        
        // step 4. compute diff for new ouro and set share based on current stakers pro-rata
        uint256 newMintedOuro = IERC20(OUROContract).balanceOf(address(this)).sub(currentOUROBalance);
                
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
     * @notice sum unclaimed OGS reward;
     */
    function checkOUROReward(address account) external view returns(uint256 rewards) { return _ouroRewardBalance[account]; }
    
    /**
     * @notice sum unclaimed OURO reward;
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