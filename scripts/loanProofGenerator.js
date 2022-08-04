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
// const loanDetails = defaultAbiCoder
//   .decode(["uint256", "uint256", "uint256", "uint256", "uint256"], args[8])
//   .map((x) => BigNumber.from(x).toString());
const leaves = [];
const tokenAddress = args.shift();
const tokenId = BigNumber.from(args.shift()).toString();
const strategyData = [
  // BigNumber.from(0).toString(), // type
  parseInt(BigNumber.from(0).toString()), // version
  getAddress(args.shift()), // strategist
  getAddress(args.shift()), // delegate
  parseInt(BigNumber.from(args.shift()).toString()), // public
  parseInt(BigNumber.from(0).toString()), // nonce
  getAddress(args.shift()), // vault
];

const strategyDetails = [
  ["uint8", "address", "address", "bool", "uint256", "address"],
  strategyData,
];
const detailsType = parseInt(BigNumber.from(args.shift()).toString());
let details;
if (detailsType === 0) {
  details = [
    [
      "uint8",
      "address",
      "uint256",
      "address",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
    ],
    [
      "1", // version
      getAddress(tokenAddress), // token
      tokenId, // tokenId
      getAddress(args.shift()), // borrower
      ...defaultAbiCoder
        .decode(
          ["uint256", "uint256", "uint256", "uint256", "uint256"],
          args.shift()
        )
        .map((x) => BigNumber.from(x).toString()),
    ],
  ];
} // else if (detailsType === 1) {
//   details = [
//     ["uint8", "address", "address", "bytes"],
//     [
//       BigNumber.from(2).toString(), // type
//       getAddress(args.shift()), // token
//       getAddress(args.shift()), // borrower
//       ...defaultAbiCoder
//         .decode(
//           ["uint256", "uint256", "uint256", "uint256", "uint256"],
//           args.shift()
//         )
//         .map((x) => BigNumber.from(x).toString()),
//     ],
//   ];
// }
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
leaves.push(strategyDetails);
// leaves.push(details);
// leaves.push(details);
leaves.push(details);
const clone = details.map((x) => x.map((y) => y));
clone[1][8] = "1000";
leaves.push(clone);
// Create tree
// console.error(details);
// console.error(clone);
// console.log(details);

const merkleTree = new MerkleTree(leaves.map((x) => keccak256(...x)));
// Get root
const rootHash = merkleTree.getHexRoot();
// Pretty-print tree
const treeLeaves = merkleTree.getHexLeaves();
// const proof = merkleTree.getHexProof(treeLeaves[1]);
console.error(treeLeaves);
const proof = merkleTree.getHexProof(treeLeaves[1]);
console.error(proof);
console.error(merkleTree.toString());
console.log(
  defaultAbiCoder.encode(["bytes32", "bytes32[]"], [rootHash, proof])
);
