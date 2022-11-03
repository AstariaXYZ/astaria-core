# Astaria SDK :sparkles:

Use this library to handle functions that are core to the architecture as well as ancillary requests.

## Strategy Merkle Specification

### Merkle Tree

The merkle tree design will be an `n` order binary merkle tree. All nodes above the leaves will be hashed in `keccack256`. The root of the merkle tree be the key for mapping to the `Vault`.

### Leaf Formats

Leaves will support multiple formats with a versioning system to allow future upgrades. The following document describes format v0.

#### Strategy Details

Each strategy will have a `StrategyDetails` leaf in index 0 to provide configuration data. Any format with `StrategyDetails` outside index 0 will be considered invalid and can result in undesired behavior although the schema is uneforceable.

`type` - type of leaf format (`StrategyDetails = 0`)
`version` - version of strategy format (`0`)
`strategist` - EOA of the strategist opening the vault, cannot be reassigned
`delegate` - EOA that can sign new strategy roots after `Vault` is initiated. Role cannot be reassigned without a new transaction. New strategies can be signed without needing a transaction.
`public` - a boolean value that indicates if a vault is public. Cannot be modified after vault opening.
`nonce` - a value tracked on chain starting from `0` at the `Vault` opening. Incrementing the `nonce` on chain invalidates all lower strategies
`vault` - contract address of the vault, if the vault address is `0x0000000000000000000000000000000000000000` then this is the first merkle tree opening the vault

```json
{
  "uint8": "type",
  "uint8": "version",
  "address": "strategist",
  "address": "delegate",
  "boolean": "public",
  "uint256": "expiration",
  "uint256": "nonce",
  "address": "vault"
}
```

Example of a `StrategyDetails` leaf:

```json
{
  "type": 0,
  "version": 0,
  "strategist": "0x8f99B0b48b23908Da9f727B5083052d5099e6aea",
  "delegate": "0xf942dba4159cb61f8ad88ca4a83f5204e8f4a6bd",
  "public": true,
  "expiration": 1665780795,
  "nonce": 0,
  "vault": "0x0000000000000000000000000000000000000000"
}
```

The leaf hash for `StrategyDetails` will be in the following format:

```js
solidityKeccak256(
  [
    'uint8',
    'uint8',
    'address',
    'address',
    'boolean',
    'uint256',
    'uint256',
    'address',
  ],
  [
    StrategyDetails.type,
    StrategyDetails.version,
    StrategyDetails.strategist,
    StrategyDetails.delegate,
    StrategyDetails.public,
    StrategyDetails.expiration,
    StrategyDetails.nonce,
    StrategyDetails.vault,
  ]
)
```

#### Lien Details

`Lien` is a subtype, so the value will not be preceded with a `type` value as it can only be nested in `Collateral` or `Collection` leaves.

`amount` - is the amount of `$WETH` in `10**18` that the borrower can borrow
`rate` - is the rate of interest accrual for the lien expressed as interest per second `10**18`
`duration` - the maximum life of the lien without refinancing in epoch seconds `10**18`
`maxSeniorLiens` - a maximum total value of all liens higher in the lien queue. Exceeding this value at any time during the lien will start a liquidation flow. Value is `$WETH` expressed as `10**18`. A zero value indicates that the lien is in the most senior position
`schedule` - max accruable interest during the life of the lien expressed as an annual rate proportion `10**18`. For example the value `100000000000000000` (0.10 or 10%) on a lien amount of `1000000000000000000` (1 `$WETH`) would enter into liquidation at `1100000000000000000` (1.1 `$WETH`). Value can be `0` indicating no schedule

```json
{
  "uint256": "amount",
  "uint256": "rate",
  "uint256": "duration",
  "uint256": "maxSeniorLiens",
  "uint256": "schedule"
}
```

#### Collateral Details

`type` - type of leaf format (`Collateral = 1`)
`token` - address of ERC721 collection
`tokenId` - token id of ERC721 inside the collection
`borrower` - address of the borrower that can commit to the lien, If the value is `address(0)` then any borrower can commit to the lien

```json
{
  "uint8": "type",
  "address": "token",
  "uint256": "tokenId",
  "address": "borrower",
  "LienDetails": "lien"
}
```

Example of a `CollateralDetails` leaf:

```json
{
  "type": 1,
  "token": "0xef1a89cbfabe59397ffda11fc5df293e9bc5db90",
  "tokenId": 4524,
  "borrower": "0x8f99B0b48b23908Da9f727B5083052d5099e6aea",
  "lien": {
    "amount": 69420000000000000000,
    "rate": 0,
    "duration": 1663545600,
    "maxSeniorLiens": 0,
    "schedule": 0
  }
}
```

The leaf hash for `CollateralDetails` will be in the following format:

```js
solidityKeccak256(
  [
    'uint8',
    'address',
    'uint256',
    'address',
    'uint256',
    'uint256',
    'uint256',
    'uint256',
    'uint256',
  ],
  [
    CollateralDetails.type,
    CollateralDetails.token,
    CollateralDetails.tokenId,
    CollateralDetails.borrower,
    CollateralDetails.amount,
    CollateralDetails.rate,
    CollateralDetails.duration,
    CollateralDetails.maxSeniorLiens,
    CollateralDetails.schedule,
  ]
)
```

#### Collection

`type` - type of leaf format (`Collection = 2`)
`token` - address of ERC721 collection
`borrower` - address of the borrower that can commit to the lien, If the value is `address(0)` then any borrower can commit to the lien

```json
{
  "uint8": "type",
  "address": "token",
  "address": "borrower",
  "LienDetails": "lien"
}
```

Example of a `CollectionDetails` leaf:

```json
{
  "type": 2,
  "token": "0xef1a89cbfabe59397ffda11fc5df293e9bc5db90",
  "borrower": "0x8f99B0b48b23908Da9f727B5083052d5099e6aea",
  "lien": {
    "amount": 69420000000000000000,
    "rate": 0,
    "duration": 1663545600,
    "maxSeniorLiens": 0,
    "schedule": 0
  }
}
```

The leaf hash for `CollectionDetails` will be in the following format:

```js
solidityKeccak256(
  [
    'uint8',
    'address',
    'address',
    'uint256',
    'uint256',
    'uint256',
    'uint256',
    'uint256',
  ],
  [
    CollectionDetails.type,
    CollectionDetails.token,
    CollectionDetails.borrower,
    CollectionDetails.amount,
    CollectionDetails.rate,
    CollectionDetails.duration,
    CollectionDetails.maxSeniorLiens,
    CollectionDetails.schedule,
  ]
)
```
