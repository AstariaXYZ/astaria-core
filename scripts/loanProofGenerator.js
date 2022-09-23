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
  parseInt(BigNumber.from(0).toString()), // nonce
  parseInt(BigNumber.from(args.shift()).toString()), // deadline
  getAddress(args.shift()), // vault
];

const strategyDetails = [
  ["uint8", "address", "uint256", "uint256", "address"],
  strategyData,
];
// console.error(strategyDetails);
const strategyDigest = solidityKeccak256(...strategyDetails);
leaves.push(strategyDigest);
const detailsType = parseInt(BigNumber.from(args.shift()).toString());
let details;
let digest;
if (detailsType === 0) {
  details = [
    [
      // "bytes32",
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
      // strategyDigest,
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
      "bytes32",
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
      strategyDigest,
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
} else if (detailsType === 2) {
  //UNIV3LiquidityDetails

  //uint8 version;
  //         address token;
  //         address[] assets;
  //         uint24 fee;
  //         int24 tickLower;
  //         int24 tickUpper;
  //         uint128 minLiquidity;
  //         address borrower;
  //         address resolver;

  details = [
    [
      "bytes32",
      "uint8",
      "address",
      "address[]",
      "uint24",
      "int24",
      "int24",
      "uint128",
      "address",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
    ],
    [
      strategyDigest,
      "2", // type
      getAddress(args.shift()), // token
      args.shift(), // assets
      args.shift(), // fee
      args.shift(), // tickLower
      args.shift(), // tickUpper
      args.shift(), // minLiquidity
      args.shift(), // borrower
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

console.error(leaves);
const merkleTree = new MerkleTree(
  leaves.map((x) => x),
  keccak256,
  {
    sortPairs: true,
  }
);
// Get root
const rootHash = merkleTree.getHexRoot();
// Pretty-print tree
const treeLeaves = merkleTree.getLeaves();
// const indicies = merkleTree.getProofIndices([0, 1]);
const proof = merkleTree.getHexMultiProof([0, 1]);
const proofFlags = merkleTree.getProofFlags(
  [Buffer.from(treeLeaves[0]), Buffer.from(treeLeaves[1])],
  proof
);
console.error(proof);
console.error(proofFlags);
// console.error(merkleTree.toString());
console.error(
  merkleTree.verifyMultiProofWithFlags(rootHash, treeLeaves, proof, proofFlags)
);
console.log(
  defaultAbiCoder.encode(
    ["bytes32", "bytes32[]", "bool[]"],
    [rootHash, proof, proofFlags]
  )
);
