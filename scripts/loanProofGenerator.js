const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");
const { utils, BigNumber } = require("ethers");
const { getAddress, solidityKeccak256, defaultAbiCoder } = utils;
const args = process.argv.slice(2);

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
leaves.push(solidityKeccak256(...strategyDetails));
const detailsType = parseInt(BigNumber.from(args.shift()).toString());
let details;
let digest;
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
      parseInt(BigNumber.from(1).toString()), // version
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
  digest = solidityKeccak256(...details);
  const clone = details.map((x) => x.map((y) => y));
  clone[1][8] = "1000";

  const digest2 = solidityKeccak256(...clone);

  leaves.push(digest);
  leaves.push(digest2);
} else if (detailsType === 1) {
  details = [
    [
      "uint8",
      "address",
      "address",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
    ],
    [
      "2", // type
      getAddress(args.shift()), // token
      getAddress(args.shift()), // borrower
      ...defaultAbiCoder
        .decode(
          ["uint256", "uint256", "uint256", "uint256", "uint256"],
          args.shift()
        )
        .map((x) => BigNumber.from(x).toString()),
    ],
  ];
  leaves.push(solidityKeccak256(...details));
}

// Create tree

const merkleTree = new MerkleTree(
  leaves.map((x) => x),
  keccak256,
  { sortPairs: true }
);
// Get root
const rootHash = merkleTree.getHexRoot();
// Pretty-print tree
const treeLeaves = merkleTree.getHexLeaves();
const proof = merkleTree.getHexProof(digest);
console.error(proof);
console.error(merkleTree.toString());
console.error(merkleTree.verify(proof, digest, rootHash));
console.log(
  defaultAbiCoder.encode(["bytes32", "bytes32[]"], [rootHash, proof])
);
