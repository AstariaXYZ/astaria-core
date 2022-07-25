const { MerkleTree } = require("merkletreejs");
// const keccak256 = require("keccak256");
const { utils, BigNumber } = require("ethers");
const {
  getAddress,
  solidityKeccak256,
  defaultAbiCoder,
  parseEther,
  solidityPack,
  hexZeroPad,
} = utils;
const args = process.argv.slice(2);
const keccak256 = solidityKeccak256;
// console.log(args);
// List of 7 public Ethereum addresses

// console.log(incomingAddress);
// const addresses = [incomingAddress];
// Hash addresses to get the leaves

// get list of
// address, tokenId, maxAmount, maxDebt, interest, maxInterest, duration, schedule
const leaves = [];

const tokenAddress = args[0];
const tokenId = BigNumber.from(args[1]).toString();
const collateral = keccak256(["address", "uint256"], [tokenAddress, tokenId]);

const strategyDetails = keccak256(
  [
    "uint8",
    "uint8",
    "address",
    "address",
    "bool",
    "uint256",
    "uint256",
    "address",
  ],
  [
    BigNumber.from(0), // type
    BigNumber.from(0), // version
    getAddress(args[2]), // strategist
    getAddress(args[3]), // delegate
    BigNumber.from(args[4]), // public
    BigNumber.from(args[5]), // expiration
    BigNumber.from(args[6]), // nonce
    getAddress(args[7]), // vault
  ]
);

const detailsType = args[8];
let details;
if (detailsType === 1) {
  details = keccak256(
    ["uint8", "address", "uint256", "address", "bytes"],
    [
      BigNumber.from(1), // type
      getAddress(args[9]), // token
      BigNumber.from(args[10]), // tokenId
      getAddress(args[11]), // borrower
      solidityPack(["bytes"], [args[12]]), // lien
    ]
  );
} else if (detailsType === 2) {
  details = keccak256(
    ["uint8", "address", "address", "bytes"],
    [
      BigNumber.from(2), // type
      getAddress(args[9]), // token
      getAddress(args[10]), // borrower
      solidityPack(["bytes"], [args[11]]), // lien
    ]
  );
}

// struct Terms {
//     strategyType: uint8;
//     strategyVersion: uint8;
//     expiration: uint256;
//     nonce: uint256;
//     vault: address;
//     strategy: address;
//
//     loanType: uint8;
//     loanData: bytes;
// }

leaves.push(strategyDetails);

leaves.push(keccak256([collateral, details]));
// Create tree
const merkleTree = new MerkleTree(leaves, keccak256, { sort: true });
// Get root
const rootHash = merkleTree.getRoot();
// Pretty-print tree
const proof = merkleTree.getHexProof(merkleTree.getLeaves()[0]);
console.log(
  defaultAbiCoder.encode(["bytes32", "bytes32[]"], [rootHash, proof])
);
