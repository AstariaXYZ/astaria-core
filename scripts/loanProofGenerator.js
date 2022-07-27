const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");
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
// const keccak256 = solidityKeccak256;
// console.log(args);
// List of 7 public Ethereum addresses

// console.log(incomingAddress);
// const addresses = [incomingAddress];
// Hash addresses to get the leaves

// get list of
// address, tokenId, maxAmount, maxDebt, interest, maxInterest, duration, schedule
const leaves = [];
const tokenAddress = args.shift();
const tokenId = BigNumber.from(args.shift()).toString();
const strategyData = [
  BigNumber.from(0).toString(), // type
  BigNumber.from(0).toString(), // version
  getAddress(args.shift()), // strategist
  getAddress(args.shift()), // delegate
  BigNumber.from(args.shift()).toString(), // public
  BigNumber.from(0).toString(), // nonce
  getAddress(args.shift()), // vault
];

//TODO why cant we generate a merkle tree with more than one leaf

const strategyDetails = keccak256(
  // ["uint8", "uint8", "address", "address", "bool", "uint256", "address"],
  strategyData
);
const detailsType = parseInt(BigNumber.from(args.shift()).toString());
let details;
if (detailsType === 0) {
  details = keccak256(
    // ["uint8", "address", "uint256", "address", "bytes"],
    [
      BigNumber.from(1).toString(), // type
      getAddress(tokenAddress), // token
      BigNumber.from(tokenId).toString(), // tokenId
      getAddress(args.shift()), // borrower
      solidityPack(["bytes"], [args.shift()]), // lien
    ]
  );
} else if (detailsType === 1) {
  details = keccak256(
    // ["uint8", "address", "address", "bytes"],
    [
      BigNumber.from(2).toString(), // type
      getAddress(args.shift()), // token
      getAddress(args.shift()), // borrower
      solidityPack(["bytes"], [args.shift()]), // lien
    ]
  );
}
// console.log(details);
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
// console.log(strategyDetails);
leaves.push(strategyDetails);
// leaves.push(strategyDetails2);
leaves.push(details);
// leaves.push(details);
// leaves.push(details);
// Create tree

const merkleTree = new MerkleTree(leaves, keccak256);
// Get root
const rootHash = merkleTree.getRoot();
// Pretty-print tree
const proof = merkleTree.getHexProof(merkleTree.getLeaves()[0]);
console.log(
  defaultAbiCoder.encode(["bytes32", "bytes32[]"], [rootHash, proof])
);
