# Astaria Docs

### Contracts In Scope
All contracts have accompanying interfaces in the `interfaces` folder.
| Contract Name           | SLOC | Purpose                                                                                                                                                                                               |
| ----------------------- | ---- |-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| [AstariaRouter]()       |    | A router contract for handling universal protocol behavior and endpoints into other core contracts.                                                                                                   |
| [AstariaVaultBase]()    |    | Contract with pointers to vault constants and contract implementations.                                                                                                                               |
| [VaultImplementation]() |    | Base vault contract with behavior for validating and issuing loan terms.                                                                                                                              |
| [Vault]()               |    | PrivateVault contract, where only permissioned lenders can deposit funds.                                                                                                                             |
| [PublicVault]()         |     | Contract for permissionless-lending Vaults, handling liquidations and withdrawals according to the epoch system.                                                                                      |
| [LienToken]()           |   | LienTokens are non-fungible tokenized debt owned by Vaults. This contract handles the accounting and liquidation of loans throughout their lifecycle.                                                 |
| [CollateralToken]()     |    | CollateralTokens are ERC721 certificates of deposit for NFTs being borrowed against on Astaria, giving the owner the right to the underlying asset when all debt is paid off.                         |
| [WithdrawVaultBase]()   |    | Base contract for WithdrawProxy.                                                                                                                                                                      |
| [WithdrawProxy]()       |     | A new WithdrawProxy is deployed for each PublicVault when at least one LP wants to withdraw by the end of the next epoch. It handles funds from loan repayments and auction funds.                    |
| [ClearingHouse]()       |     | ClearingHouses are deployed for each new loan and settle payments between Seaport auctions and Astaria Vaults if a liquidation occurs. It also stores NFTs that borrowers deposit to take out a loan. |
| [BeaconProxy]()         |   | Beacon contract for upgradeability.                                                                                                                                                                   |
| [TransferProxy]()       |   | The TransferProxy handles payments to loans (LienTokens).                                                                                                                                             |
| **Total**               |  |

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

Edge cases around withdrawing and other complex protocol usage are found in the WithdrawTest and IntegrationTest contracts.
