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

// const loan = keccak256(
//   ["uint256", "uint256", "uint256", "uint256", "uint256"],
//   [
//     BigNumber.from(args[2]),
//     BigNumber.from(args[3]),
//     BigNumber.from(args[4]),
//     BigNumber.from(args[5]),
//     BigNumber.from(args[6]),
//   ]
// );
const tokenAddress = args[0];
const tokenId = BigNumber.from(args[1]).toString();
const collateral = keccak256(["address", "uint256"], [tokenAddress, tokenId]);
const loan = [
  BigNumber.from(args[2]), // maxAmount
  BigNumber.from(args[3]), // maxDebt
  BigNumber.from(args[4]), // rate
  BigNumber.from(args[5]), // maxRate
  BigNumber.from(args[6]), // duration
  BigNumber.from(args[7]), // schedule
];
leaves.push(
  keccak256(
    [
      "bytes32", // bytes32 casting of uint256
      "uint256", // maxAmount
      "uint256", // maxDebt
      "uint256", // rate
      "uint256", // maxRate
      "uint256", // duration
      "uint256", // schedule
    ],
    [collateral, ...loan]
  )
);
// Create tree
const merkleTree = new MerkleTree(leaves, keccak256, { sort: true });
// Get root
const rootHash = merkleTree.getRoot();
// Pretty-print tree
const proof = merkleTree.getHexProof(merkleTree.getLeaves()[0]);
console.log(
  defaultAbiCoder.encode(["bytes32", "bytes32[]"], [rootHash, proof])
);
