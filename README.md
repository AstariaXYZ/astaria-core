# Astaria contest details

- 50,000 USDC main award pot
- Join [Sherlock Discord](https://discord.gg/MABEWyASkp)
- Submit findings using the issue page in your private contest repo (label issues as med or high)
- [Read for more details](https://docs.sherlock.xyz/audits/watsons)
- Starts October 20, 2022 15:00 UTC
- Ends November 03, 2022 15:00 UTC

# Resources

TBD

# Audit scope


[astaria-gpl](https://github.com/AstariaXYZ/astaria-gpl)

[astaria-core](https://github.com/sherlock-audit/2022-10-astaria)

All contracts in these repos are in scope unless specified below

Not in scope

```

libraries/Base64.sol
libraries/CollateralLookup.sol
scripts/deployments/strategies/*
utils
test
```

# Astaria Docs
```ml
 src
 ├─ AstariaRouter.sol
 ├─ AstariaVaultBase.sol
 ├─ BeaconProxy.sol
 ├─ CollateralToken.sol
 ├─ LienToken.sol  
 ├─ PublicVault.sol
 ├─ TransferProxy.sol
 ├─ Vault.sol
 ├─ VaultImplementation.sol
 ├─ WithdrawProxy.sol
 ├─ WithdrawVaultBase.sol
 └─ actions
    └─ UNIV3
       └─ClaimFees.sol
 └─ libraries
    └─ Base64.sol
    └─ CollateralLookup.sol
 └─ security
    └─ V3SecurityHook.sol
 └─ strategies
    └─ CollectionValidator.sol
       ├─ UNI_V3Validator.sol
       └─ UniqueValidator.sol
 └─ utils
    ├─ Math.sol 
    ├─ MerkleProofLib.sol
    └─ Pausable.sol 
	  
```
For more details on the Astaria protocol and its contracts, see the [docs](https://docs.astaria.xyz/docs/intro)

# Astaria Contracts Setup

Astaria runs on [Foundry](https://github.com/foundry-rs/foundry).
So make sure you get setup with Foundry first

To install contract dependencies, run:

```sh
forge install
yarn
```


To Deploy on a forked network, update your RPC in docker-compose.yml first and then run:

```
sh scripts/boot-system.sh
```




Tests are located in src/test. To run tests, run:

```sh
forge test --ffi
```

To target integration tests following common use paths, run:

```sh
forge test --ffi --match-contract AstariaTest
```

To target tests following disallowed behavior, run:

```sh
forge test --ffi --match-contract RevertTesting
```
