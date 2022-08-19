# NFT v2 Concept

## Installation

Install Foundry (https://getfoundry.sh)
- run install.sh


## Overview
1. Appraiser assembles a merkle tree of their offers for all NFTs on the network
2. Appraiser signs the root, and creates a `BondVault` with an expiration
3. Any lender can contribute ETH to the `BondVault`
4. In return any lender receives interest bearing ERC1155 tokens proportional to their contribution (weth -> token)
5. Users who borrow against their NFT using the appraiser's parameters depletes the `BondVault`
7. Borrowers pay interest on a `schedule`, the `schedule` variable will be a maximum percentage of interest to accrue before a liquidation starts
8. If the borrow fails to meet the schedule the NFT is sent to liquidation in the `ERC721Wrapper`. Lenders are paid back in order of lien holder lowest to highest until auction funds are depleted. If there is an amount remaining, a liquidation penalty is sent to the liquidator and the remaining amount is returned to the borrower.
9. One the `BondVault` reaches `maturity` any loan remaining is liquidated. Once liquidations are complete each borrower can redeem burn their ERC155 token for a proportional amount of the `BondVault.balance`

### AstariaRouter
In the `AstariaRouter` new loans are initiated against specific `BondVault`s. The borrower provides their `tokenId` from the `ERC721Wrapper` and loan parameters. Those parameters are validated against the merkle root of the `BondVault`. The ERC721 token is transferred to the `AstariaRouter` address until repayment or liquidation occurs.

```js
  struct BondVault {
      // bytes32 root; // root for the appraisal merkle tree provided by the appraiser
      address appraiser; // address of the appraiser for the BondVault
      uint256 totalSupply; // total amount contributed
      uint256 balance; // WETH balance of vault
      mapping(address => uint256[]) loans; // all open borrows in vault
      uint256 loanCount;
      uint256 expiration; // expiration for lenders to add assets and expiration when borrowers cannot create new borrows
      uint256 maturity; // epoch when the loan becomes due
  }
```

### Design Advantages
The properties of this design have distinct advantages.

1. Borrowers can access loans synchronously
    a. In other designs borrowers need to set terms or lenders need to present offers
2. Concerns of lenders and appraisers are separated
    a. Appraisers are valued for their insights on NFT values without needing to provide capital
    b. Lenders can provide capital to an appraiser on the basis of their reputation (previous success or failure)
3. Low interactivity
    a. Appraisers send out appraisals passively
    b. Lenders invest in vaults based on their preferences
    c. Borrowers don't need to send request for bids and can borrow instantly
4. Vault tokens are high value yield bearing asset

### Merkle Tree
The merkle tree design will be an order 32 binary merkle tree with `2**32` leaves. All nodes above the leaves will be hashed in `keccack256`. The root of the merkle tree be the key for mapping to the `BondVault` details.

### Leaf
Each leaf will be a a composite hash of a `loan` hash `'loan` and a `collateral` hash `'collateral`.

```
keccack256('loan, 'collateral)
```

### Loan Type

```js
  struct Loan {
    uint256 collateralToken; // ERC721, 1155 will be wrapped to create a singular tokenId
    uint256 amount; // loans are only in wETH
    uint32 interestRate; // rate of interest accruing on the borrow (should be in seconds to make calculations easy)
    uint32 start; // epoch time of last interest accrual
    uint32 end; // epoch time at which the loan must be repaid
    uint8 lienPosition; // position of repayment, borrower can take out multiple loans on the same NFT, if the NFT becomes liquidated the lowest lien psoition is repaid first
    uint32 schedule; // percentage margin before the borrower needs to repay 
  }
```


### Collateral Types
Collateral types will be used as a hash component to generate a unique ERC721 `tokenId`. The `tokenId` will be utilized in the `AstariaRouter` to separate the concerns of collateral lock up, liquidation, and lien position management.

#### ERC721
```json
{
    "address": "address",
    "uint256": "tokenId"
}
```

#### ERC1155
```json
{
    "address": "address",
    "uint256": "tokenId",
}
```

#### ERC20
```json
{
    "address": "address",
    "uint256": "ratio"
}
```
`ratio` is a `2*10**18` ratio of token/eth amounts. The reasoning for this design is to allow the ERC-721 wrapper to accommodate `lienPosition`.

#### Nonce
`nonce` will be hashed together with the `amount` and fungible collateral types (ERC1155, ERC20) to ensure a unique `tokenId` is generated. ERC721 contract nonce will be incremented.

The only drawback to this design is the user will need to provide their amount and nonce as a component of the verifying hash in the `AstariaRouter`. The benefits are that the appraiser can provide lending appraisals on fungible token type.

```json
{
    "uint256": "amount",
    "uint256": "nonce"
}
```
```
keccack256(collateral, amount, nonce)
```

### ERC721CollateralWrapper
The `ERC721CollateralWrapper` should have 3 distinct methods for wrapping each token type. All wrapped collateral should result in a unique `tokenId` that is a hash of the parameters.

#### Lien Positions
Each ERC721 in an `ERC721CollateralWrapper` will have an array of `liens`. Each new loan specifies a lien position. A lien position is the order of repayment. If one of the loans goes to liquidation lien position index `0` will be repaid until the liquidation funds are exhausted. Stored in the `liens` mapping is an array of `BondVault` roots ordered by lien position.
```
mapping(tokenId => bytes32[]) liens;
```

Borrowers can refinance their loan using the new loan to repays their first loan. Refinancing must pay off their last loan in the series, replacing the loans in a lifo (last in first out) pattern. 

For example if the end user had 6 loans (0 - 5). The user could refinance `tokenId[5]` or refinance `tokenId[4]` and `tokenId[5]` reducing the loan count to 5. But the same user could not refinance `tokenId[3]`.

## Design Considerations

### WETH Only

**Gas cost of calculations** - WETH was selected as the only lending asset to simplify the implementation. Calculation and ERC1155 token minting becomes simpler. In later versions the appraiser could specify a specific asset to price in, however this is too much burden for v0.

**ETH is the reserve currency of NFTs** - Most NFT borrowers want to borrow ETH with the desire that their assets out perform ETH. NFTs are predominately priced in ETH.

**Dangers of unwrapped ETH** - WETH was utilized as it mitigated the errors that occurs when handling ETH. In the past these errors have led to catastrophic loss of funds. The trade off is gas costs for an ERC20 transfer.

### Fixed rate
Fixed rates allow the contracts to operate without the need to accrue interest. The only time interest accrual is required is during a repayment or liquidation. If the rate was variable or reflexive the interest would need to be updated periodically to assess whether liquidations were necessary.

### Fixed term
Fixed term is a design side effect of the gas costs of tracking redemption. If the lender redeems their ERC1155 for a proportional amount of the underlying balance that needs to be recorded. As an alternative by adding a maturity date there is a date of completion and the lender only needs to burn their tokens to redeem their portion of the `BondVault` balance.

## Mechanism Design

### Appraiser rewards
The appraiser is being paid for their expertise, so an origination fee should be assessed. The appraiser can optionally add a percentage of the profit of the `BondVault` a design similar to the 2/20 model of Yearn.

### Protocol rewards
The protocol should have the capability to implement a percentage fee to each `BondVault`. Disabled by default using a fee switch model similar to Uniswap.

### Lender over payment
Initially there was a problem considered that lenders could overpay if they were the last to lend and there were no additional borrows. However, if we consider the ETH being lent is lent proportionally to the `BondVault` the individual lender does not need a refund but the ETH should be apportioned throughout vault. This design has bad capital efficiency design in this edge case. This edge case could be mitigated in later versions by depositing the remaining ETH into a yield bearing strategy. However, this create more design complexity. 

### Prepayment penalty
There is also the possibility of a prepayment penalty as the holders of the `BondVault` tokens have some expectation of interest from the loan.

## Use Cases

#### Borrow and buy
A loan offered by an appraiser at the time off purchase could allow the user to buy the NFT and take a loan simultaneously. This allows the user to use less funds at the time of purchase.

#### Bridge token loans
As users bridge from one bridge to the next their tokens become less fungible assets going from chain a->b->c become non-fungible as they are not assets arriving on a native bridge.

#### Lending on long tail assets
New tokens require protocol approvals on Compound and AAVE due to liquidation risks. With Astaria appraisers can establish a lending rate and lend to users on these new assets.

#### Cross chain lending
Assets being locked in a `ERC721Wrapper` with a specific `tokenId` Astaria could lend on assets across chain so long as the `tokenId` could be resolved to a block header or bridge root.

---

# Advanced Sample Hardhat Project

This project demonstrates an advanced Hardhat use case, integrating other tools commonly used alongside Hardhat in the ecosystem.

The project comes with a sample contract, a test for that contract, a sample script that deploys that contract, and an example of a task implementation, which simply lists the available accounts. It also comes with a variety of other tools, preconfigured to work with the project code.

Try running some of the following tasks:

```shell
npx hardhat accounts
npx hardhat compile
npx hardhat clean
npx hardhat test
npx hardhat node
npx hardhat help
REPORT_GAS=true npx hardhat test
npx hardhat coverage
npx hardhat run scripts/deploy.ts
TS_NODE_FILES=true npx ts-node scripts/deploy.ts
npx eslint '**/*.{js,ts}'
npx eslint '**/*.{js,ts}' --fix
npx prettier '**/*.{json,sol,md}' --check
npx prettier '**/*.{json,sol,md}' --write
npx solhint 'contracts/**/*.sol'
npx solhint 'contracts/**/*.sol' --fix
```

# Etherscan verification

To try out Etherscan verification, you first need to deploy a contract to an Ethereum network that's supported by Etherscan, such as Ropsten.

In this project, copy the .env.example file to a file named .env, and then edit it to fill in the details. Enter your Etherscan API key, your Ropsten node URL (eg from Alchemy), and the private key of the account which will send the deployment transaction. With a valid .env file in place, first deploy your contract:

```shell
hardhat run --network ropsten scripts/deploy.ts
```

Then, copy the deployment address and paste it in to replace `DEPLOYED_CONTRACT_ADDRESS` in this command:

```shell
npx hardhat verify --network ropsten DEPLOYED_CONTRACT_ADDRESS "Hello, Hardhat!"
```

# Performance optimizations

For faster runs of your tests and scripts, consider skipping ts-node's type checking by setting the environment variable `TS_NODE_TRANSPILE_ONLY` to `1` in hardhat's environment. For more details see [the documentation](https://hardhat.org/guides/typescript.html#performance-optimizations).
