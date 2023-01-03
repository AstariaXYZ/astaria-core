#!/usr/bin/env zsh

# This script is used to generate typechain types for the contracts in the myArray+=(item)

# define array and add all contracts from optimized-out.sol that are in typechainabi

accepted_file_names=("CollateralToken.sol" "LienToken.sol" "MultiRolesAuthority.sol" "PublicVault.sol" "Vault.sol" "WithdrawProxy.sol"  "AstariaRouter.sol" "VaultImplementation.sol")

forge build
# loop through the array and generate types for each contract
rm -rf abi && mkdir -p abi
for i in ./out/*;
do
  file=$(basename "${i}")
  if [[ ${accepted_file_names[(ie)$file]} -le ${#accepted_file_names} ]]; then
    cp -r "$i"/*.json "abi/"
  fi
done

