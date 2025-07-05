# Steps to deploy after trying out mock deployment

1. run deploy tokens script and get both token 0, token 1
```
source .env && forge script script/00_Deploy_Tokens.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY  --etherscan-api-key $ETHERSCAN_API_KEY --verify --broadcast
```

World coin mainnet uniswap addresses:
(not on testnet sadge)

```
PoolManager: 0xb1860d529182ac3bc1f51fa2abd56662b7d13f33
PositionDescriptor: 0x7da419153bd420b689f312363756d76836aeace4
PositionManager: 0xc585e0f504613b5fbf874f21af14c65260fb41fa
Quoter: 0x55d235b3ff2daf7c3ede0defc9521f1d6fe6c5c0
StateView: 0x51d394718bc09297262e368c1a481217fdeb71eb
Universal Router: 0x8ac7bee993bb44dab564ea4bc9ea67bf9eb5e743
Permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3
```



2. deploy the hook 
```
source .env && forge script script/01_Deploy_Hook.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY  --etherscan-api-key $ETHERSCAN_API_KEY --verify --broadcast
```

3. get the token 0 and token 1 addresses and modify it in Basescript.sol

4. make sure to also add the deployed hook address in Basescript.sol

5. create pool and add liquidity
```
source .env && forge script script/02_CreatePoolAndAddLiquidity.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY  --etherscan-api-key $ETHERSCAN_API_KEY --verify --broadcast
```

6. check if pool was initialised by running
```
source .env && forge script script/03_GetPoolId.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY  --etherscan-api-key $ETHERSCAN_API_KEY --verify --broadcast
```


7. need to figure out how to do swaps using universal router

Mock deployments:

token 0: 0xA815F0F2853Cb3b189FE94172F824F03F24989bD
token 1: 0x92C79A67FA30D1e42cBB3CA9401AF2952369b973
hook: 0xe550A677bB302D43dCc9bd30Dc634cfe8369cAc0

Mainnet deployments:

token 0: 0x76f14c98d2B3d4D7e09486Ca09e5BE1B4E19182a
token 1: 0xbF784Ac432D1CA21135B3ee603E11ED990D77EA4
hook: 0x235877899ECd2287B073d312C02D21e7F8d09040
mock oracle: 0x31B50a53a7f3669B1A3db7681Fd2EEefC972b8cA