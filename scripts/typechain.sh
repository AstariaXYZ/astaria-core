#!/usr/bin/env zsh

# This script is used to generate typechain types for the contracts in the myArray+=(item)

# define array and add all contracts from out.sol that are in typechainabi

accepted_file_names=("AuctionHouse.sol" "CollateralToken.sol" "LienToken.sol" "MultiRolesAuthority.sol" "PublicVault.sol" "Vault.sol" "WithdrawProxy.sol"  "AstariaRouter.sol" "VaultImplementation.sol")

forge build
# loop through the array and generate types for each contract
rm -rf typechainabi && mkdir -p typechainabi
for i in ./out/*;
do
  file=$(basename "${i}")
  if [[ ${accepted_file_names[(ie)$file]} -le ${#accepted_file_names} ]]; then
    cp -r "$i"/*.json "typechainabi/"
  fi
done
typechain --target=ethers-v5 typechainabi/**/**.json --out-dir=typechain --show-stack-traces
