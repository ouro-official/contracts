// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./library.sol";

/**
 * @notice OURO token contract (ERC20)
 */
contract OURToken is ERC20, Pausable, Ownable, IOUROToken {
    using SafeERC20 for IERC20;
    using SafeMath for uint;
    using Address for address payable;
    using SafeMath for uint256;

   /**
     * @dev Emitted when an account is set mintable
     */
    event Mintable(address account);
    /**
     * @dev Emitted when an account is set unmintable
     */
    event Unmintable(address account);
    
    // @dev mintable group
    mapping(address => bool) public mintableGroup;
    
    modifier onlyMintableGroup() {
        require(mintableGroup[msg.sender], "OURO: not in mintable group");
        _;
    }
        
    // @dev ouro dynamcis's address
    address public ouroDynamicAddress;

    mapping(address => TimeLock) private _timelock;

    event BlockTransfer(address indexed account);
    event AllowTransfer(address indexed account);

    struct TimeLock {
        uint256 releaseTime;
        uint256 amount;
    }

    /**
     * @dev Initialize the contract give all tokens to the deployer
     */
    constructor(string memory _name, string memory _symbol, uint8 _decimals, uint256 _initialSupply) public {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        setMintable(owner(), true);
        _mint(_msgSender(), _initialSupply * (10 ** uint256(_decimals)));
    }
    
    /**
     * @dev set or remove address to mintable group
     */
    function setMintable(address account, bool allow) public onlyOwner {
        mintableGroup[account] = allow;
        if (allow) {
            emit Mintable(account);
        }  else {
            emit Unmintable(account);
        }
    }
    
    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     */
    function mint(address account, uint256 amount) public override onlyMintableGroup {
        _mint(account, amount);
        
    }
    /**
     * @dev Destroys `amount` tokens from the user.
     *
     * See {ERC20-_burn}.
     */
    function burn(uint256 amount) public override onlyMintableGroup {
        _burn(_msgSender(), amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, deducting from the caller's
     * allowance.
     *
     * See {ERC20-_burn} and {ERC20-allowance}.
     *
     * Requirements:
     *
     * - the caller must have allowance for ``accounts``'s tokens of at least
     * `amount`.
     */
    function burnFrom(address account, uint256 amount) public {
        uint256 decreasedAllowance = allowance(account, _msgSender()).sub(amount, "OURO: burn amount exceeds allowance");

        _approve(account, _msgSender(), decreasedAllowance);
        _burn(account, amount);
    }

    /**
     * @dev View `account` locked information
     */
    function timelockOf(address account) public view returns(uint256 releaseTime, uint256 amount) {
        TimeLock memory timelock = _timelock[account];
        return (timelock.releaseTime, timelock.amount);
    }

    /**
     * @dev Release the specified `amount` of locked amount
     * @notice only Owner call
     */
    function release(address account, uint256 releaseAmount) public onlyOwner {
        require(account != address(0), "EHC: release zero address");

        TimeLock storage timelock = _timelock[account];
        timelock.amount = timelock.amount.sub(releaseAmount);
        if(timelock.amount == 0) {
            timelock.releaseTime = 0;
        }
    }

    /**
     * @dev Triggers stopped state.
     * @notice only Owner call
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @dev Returns to normal state.
     * @notice only Owner call
     */
    function unpause() public onlyOwner {
        _unpause();
    }
    
    /**
     * @dev transfer with lock 
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     * - releaseTime.
     */
    function transferWithLock(address recipient, uint256 amount, uint256 releaseTime) public onlyOwner returns (bool) {
        require(recipient != address(0), "OURO: lockup zero address");
        require(releaseTime > block.timestamp, "OURO: release time before lock time");
        require(_timelock[recipient].releaseTime == 0, "OURO: already locked");

        TimeLock memory timelock = TimeLock({
            releaseTime : releaseTime,
            amount      : amount
        });
        _timelock[recipient] = timelock;
        
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev Batch transfer amount to recipient
     * @notice that excessive gas consumption causes transaction revert
     */
    function batchTransfer(address[] memory recipients, uint256[] memory amounts) public {
        require(recipients.length > 0, "OURO: least one recipient address");
        require(recipients.length == amounts.length, "OURO: number of recipient addresses does not match the number of tokens");

        for(uint256 i = 0; i < recipients.length; ++i) {
            _transfer(_msgSender(), recipients[i], amounts[i]);
        }
    }

    /**
     * @dev See {ERC20-_beforeTokenTransfer}.
     *
     * Requirements:
     *
     * - the contract must not be paused.
     * - accounts must not trigger the locked `amount` during the locked period.
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        require(!paused(), "OURO: token transfer while paused");

        // Check whether the locked amount is triggered
        TimeLock storage timelock = _timelock[from];
        if(timelock.releaseTime != 0 && balanceOf(from).sub(amount) < timelock.amount) {
            require(block.timestamp >= timelock.releaseTime, "OURO: current time is before from account release time");

            // Update the locked `amount` if the current time reaches the release time
            timelock.amount = balanceOf(from).sub(amount);
            if(timelock.amount == 0) {
                timelock.releaseTime = 0;
            }
        }

        super._beforeTokenTransfer(from, to, amount);
    }
}
