docker-compose up -d
# consider the hardhat template for the deployment
forge create src/AstariaDeploy.sol:AstariaDeploy --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --rpc-url http://localhost:8545 --revert-strings debug

# we're on a fork so get some weth

cast 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 --method "deposit" --params "[]" --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --rpc-url http://localhost:8545 --revert-strings debug

# create some vaults

# create some