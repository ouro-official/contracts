OURO 
===
Ouro aims to create an inflation-proof store of value system on BSC, featuring Peer-to-Pool asset swaps. In essence, the project derives fiat inflations manifested in the growth of the value of crypto assets and migrates them onto OURO, making it inflation-proof against the USD.

Binance Smart Chain Mainnet Deployment:

* OURO BEP20 Token: https://bscscan.com/token/0x0a4fc79921f960a4264717fefee518e088173a79
* OGS BEP20 Token: https://bscscan.com/token/0x416947e6Fc78F158fd9B775fA846B72d768879c2
* OURO Reserve: https://bscscan.com/address/0x8739aBC0be4f271A5f4faC825BebA798Ee03f0CA#code

OURO RESERVE API
===
You can build your own smart contracts to interact with *OURO Reserve* with your own strategy.

APIs for external contracts are listed as followings:

### Get collateral info which OURO reserve support

```solidity
function getCollateral(address token) external view returns (
        address vTokenAddress,
        uint256 assetUnit,
        uint256 lastPrice,
        AggregatorV3Interface priceFeed
);
```
Returns the detailed collateral info which *OURO Reserve* supports, including:
1. `vTokenAddress`: Venus VToken address for lending.
2. `assetUnit`: The amount for one unit of asset, eg: 1ETH = 1e18.
3. `lastPrice`: Records the latest price during last `rebase()` operation.
4. `priceFeed`: The Chainlink price oracle for this asset.

### Get collateral balance in OURO reserve

```solidity
function getAssetBalance(address token) external view returns(uint256);
```
Returns the amount of assets in *OURO Reserve*

### Get OURO price in BUSD
```solidity
function getPrice() public view returns(uint256);
```
getPrice returns current *OURO* price in BUSD, *OURO Reserve* always keeps the price 1:1 pegged.

### Get the amount of assets required to mint given amount of OURO
```solidity
function getAssetsIn(uint256 amountOURO, address token) external view returns(uint256);
```
1. `amountOURO`: amount of OURO expected to mint.
2. `token`: BEP20 token to swap in, for BNB, use [WBNB](https://bscscan.com/token/0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c) address instead.

Returns: amount of assets required.

### Get the amount of OURO required to swap given amount of assets out
```solidity
function getOuroIn(uint256 amount, address token) external view returns(uint256);
```
1. `amount`: amount of assets expected to swap out.
2. `token`: BEP20 token to receive, for BNB, use [WBNB](https://bscscan.com/token/0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c) address instead.

Returns: *OURO* amount required to burn.

### Mint OURO
```solidity
function deposit(address token, uint256 amountAsset, uint256 minAmountOuro) external payable returns (uint256 OUROMinted);
```
*OURO*s are minted via this function only, users deposit assets to mint equivalent *OURO* based on asset's **realtime price** from Chainlink oracle;

In order to mint new *OURO*, you need to `approve()` your asset token to *OURO Reserve* contract first.

Prices may change between the time of query and the time of transaction confirmation, 
`minAmountOuro` is to limit the minimum amount of *OURO* willing to receiving in `deposit()` transaction.

If you want to mint *OURO* at realtime price of the asset, simply set 0 to `minAmountOuro`.

Parameters:

1. `token`: BEP20 token to swap into reserve, for BNB, use [WBNB](https://bscscan.com/token/0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c) address instead.
2. `amountAsset`: amount of assets to swap in(this parameter is omitted for BNB deposit).
3. `minAmountOuro`: minimum amount of *OURO* willing to receive.

Returns the amount of *OURO* minted.

### Withdraw assets
```solidity
function withdraw(address token, uint256 amountAsset, uint256 maxAmountOuro) external returns(uint256 OUROTaken);
```
Withdrawing assets is accompanied by burning equivalent value of *OURO* token.

In order to swap back your *OURO* for *OURO Reserve* to burn, you need to `approve()` your *OURO* token to *OURO Reserve* contract first, 
the *OURO Reserve* contract will be able to transfer *OURO* token from your account and returns equivalent(realtime price) assets back to you.

Prices may change between the time of query and the time of transaction confirmation, 
`maxAmountOuro` is to limit the maximum amount of *OURO* willing to burn in `withdraw()` transaction.

If you want to get back assets at realtime price, simply set *MAX_UINT256* to `maxAmountOuro`.

Parameters:

1. `token`: BEP20 token to swap out, for BNB, use [WBNB](https://bscscan.com/token/0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c) address instead.
2. `amountAsset`: amount of assets to swap in (this parameter is omitted for BNB deposit).
3. `minAmountOuro`: minimum amount of *OURO* willing to receive.

Returns the amount of *OURO* transfered out from your account.

PS. `uint256 MAX_UINT256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff`



