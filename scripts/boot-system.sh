docker-compose up -d
# consider the hardhat template for the deployment
forge create src/AstariaDeploy.sol:AstariaDeploy --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --rpc-url http://localhost:8545 --revert-strings debug