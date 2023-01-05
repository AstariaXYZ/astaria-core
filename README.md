# Contracts

All contracts in `src/` have accompanying interfaces in the `interfaces` folder.

| Contract Name                     | SLOC | Purpose                                                                                                                                                                                               |
| --------------------------------- | ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| src/AstariaRouter.sol             | 556  | A router contract for handling universal protocol behavior and endpoints into other core contracts.                                                                                                   |
| src/AstariaVaultBase.sol          | 33   | Contract with pointers to vault constants and contract implementations.                                                                                                                               |
| src/VaultImplementation.sol       | 243  | Base vault contract with behavior for validating and issuing loan terms.                                                                                                                              |
| src/Vault.sol                     | 37   | PrivateVault contract, where only permissioned lenders can deposit funds.                                                                                                                             |
| src/PublicVault.sol               | 442  | Contract for permissionless-lending Vaults, handling liquidations and withdrawals according to the epoch system.                                                                                      |
| src/LienToken].sol                | 594  | LienTokens are non-fungible tokenized debt owned by Vaults. This contract handles the accounting and liquidation of loans throughout their lifecycle.                                                 |
| src/CollateralToken.sol           | 428  | CollateralTokens are ERC721 certificates of deposit for NFTs being borrowed against on Astaria, giving the owner the right to the underlying asset when all debt is paid off.                         |
| src/WithdrawVaultBase.sol         | 23   | Base contract for WithdrawProxy.                                                                                                                                                                      |
| src/WithdrawProxy.sol             | 166  | A new WithdrawProxy is deployed for each PublicVault when at least one LP wants to withdraw by the end of the next epoch. It handles funds from loan repayments and auction funds.                    |
| src/ClearingHouse.sol             | 134  | ClearingHouses are deployed for each new loan and settle payments between Seaport auctions and Astaria Vaults if a liquidation occurs. It also stores NFTs that borrowers deposit to take out a loan. |
| src/BeaconProxy.sol               | 33   | Beacon contract for upgradeability.                                                                                                                                                                   |
| src/TransferProxy.sol             | 12   | The TransferProxy handles payments to loans (LienTokens).                                                                                                                                             |
| lib/gpl/src/ERC20-Cloned.sol      | 126  | Custom base ERC20 implementation.                                                                                                                                                                     |
| lib/gpl/src/ERC721.sol            | 155  | Slightly modified base ERC721 implementation.                                                                                                                                                         |
| lib/gpl/src/ERC4626-Cloned.sol    | 93   | Custom base ERC4626 implementation.                                                                                                                                                                   |
| lib/gpl/src/ERC4626RouterBase.sol | 33   | ERC4626 base router contract.                                                                                                                                                                         |
| lib/gpl/src/ERC4626Router.sol     | 27   | ERC4626 router contract.                                                                                                                                                                              |
| lib/gpl/src/Multicall.sol         | 18   | Multicall contract.                                                                                                                                                                                   |
| **Total**                         | 3153 |


```ml
 src
 ├─ AstariaRouter.sol
 ├─ AstariaVaultBase.sol
 ├─ BeaconProxy.sol
 ├─ ClearingHouse.sol
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

For more details on the Astaria protocol and its contracts, please see the [docs](https://docs.astaria.xyz/docs/intro).

# Astaria Contracts Setup

Astaria runs on [Foundry](https://github.com/foundry-rs/foundry). If you don't have it installed, follow the installation instructions [here](https://book.getfoundry.sh/getting-started/installation).

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

When fork testing testClaimFeesAgainstV3Liquidity use the following to ensure the state data is accurate  
```sh
forge test --ffi --match-test testClaimFeesAgainstV3Liquidity --fork-url <YOUR_RPC_HERE> --fork-block-number 15934974
```


Edge cases around withdrawing and other complex protocol usage are found in the WithdrawTest and IntegrationTest contracts.

To view a gas report, run:
```sh
forge snapshot --gas-report --ffi
```
