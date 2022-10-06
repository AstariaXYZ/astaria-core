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
  BigNumber.from(0).toString(), // version
  getAddress(args.shift()), // strategist
  BigNumber.from(0).toString(), // nonce
  BigNumber.from(args.shift()).toString(), // deadline
  getAddress(args.shift()), // vault
];

//LogStrategy(: (0, 0x842789a128E6C9e58E09e65820C4cfa8b432ec3a, 0, 172801, 0x11Ceceeb33F4A2d5fe012b82be60e3DB105eae90))
// const strategyData = [
//   "0",
//   "0x842789a128E6C9e58E09e65820C4cfa8b432ec3a",
//   "0",
//   "172801",
//   "0x11Ceceeb33F4A2d5fe012b82be60e3DB105eae90",
// ];

const strategyDetails = [
  ["uint8", "address", "uint256", "uint256", "address"],
  strategyData,
];
// console.error(strategyDetails);
const strategyDigest = solidityKeccak256(...strategyDetails);
// leaves.push(defaultAbiCoder.encode(...strategyDetails));
const detailsType = parseInt(BigNumber.from(args.shift()).toString());
let details;
let digest;
if (detailsType === 0) {
  let termdata = [
    "1",
    getAddress(tokenAddress), // token
    tokenId, // tokenId
    getAddress(args.shift()), // borrower
    ...defaultAbiCoder
      .decode(["uint256", "uint256", "uint256", "uint256"], args.shift())
      .map((x) => BigNumber.from(x).toString()),
  ];

  ////     │   │   ├─ emit LogDetails(: (1, 0xB4FC799550cD4B5e20e31b348a613e18fA9dc932, 1, 0x0000000000000000000000000000000000000000, (11835616438356163200, 864001, 500000000000000000, 50000000000000000000)))
  // const termdata = [
  //   "1",
  //   "0xB4FC799550cD4B5e20e31b348a613e18fA9dc932",
  //   "1",
  //   "0x0000000000000000000000000000000000000000",
  //   "11835616438356163200",
  //   "864001",
  //   "500000000000000000",
  //   "50000000000000000000",
  // ];
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
    ],
    termdata,
  ];
  // digest = solidityKeccak256(...details);
  const clone = details.map((x) => x.map((y) => y));
  clone[1][7] = "1000";

  // const digest2 = solidityKeccak256(...clone);

  // leaves.push(digest);
  // leaves.push(digest2);
  leaves.push(defaultAbiCoder.encode(...details));
  leaves.push(defaultAbiCoder.encode(...clone));
  // leaves.push(digest2);
  // leaves.push(digest2);
  // leaves.push(digest2);
  // leaves.push(digest2);
} else if (detailsType === 1) {
  details = [
    ["uint8", "address", "address", "uint256", "uint256", "uint256", "uint256"],
    [
      "1", // version
      getAddress(args.shift()), // token
      getAddress(args.shift()), // borrower
      ...defaultAbiCoder
        .decode(["uint256", "uint256", "uint256", "uint256"], args.shift())
        .map((x) => BigNumber.from(x).toString()),
    ],
  ];
  leaves.push(solidityKeccak256(...details));
} else if (detailsType === 2) {
  details = [
    [
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
    ],
    [
      "1", // version
      getAddress(args.shift()), // token
      args.shift(), // assets
      args.shift(), // fee
      args.shift(), // tickLower
      args.shift(), // tickUpper
      args.shift(), // minLiquidity
      args.shift(), // borrower
      ...defaultAbiCoder
        .decode(["uint256", "uint256", "uint256", "uint256"], args.shift())
        .map((x) => BigNumber.from(x).toString()),
    ],
  ];
  leaves.push(solidityKeccak256(...details));
}
//
// const termdata = [
//   "1",
//   "0xB4FC799550cD4B5e20e31b348a613e18fA9dc932",
//   "1",
//   "0x0000000000000000000000000000000000000000",
//   "11835616438356163200",
//   "864001",
//   "500000000000000000",
//   "50000000000000000000",
// ];
// let details = [
//   [
//     "uint8",
//     "address",
//     "uint256",
//     "address",
//     "uint256",
//     "uint256",
//     "uint256",
//     "uint256",
//   ],
//   termdata,
// ];
// // digest = solidityKeccak256(...details);
// const clone = details.map((x) => x.map((y) => y));
// clone[1][7] = "1000";
//
// // const digest2 = solidityKeccak256(...clone);
//
// // leaves.push(digest);
// // leaves.push(digest2);
// leaves.push(defaultAbiCoder.encode(...details));
// leaves.push(defaultAbiCoder.encode(...clone));
// // leaves.push(digest2);

// Create tree

const merkleTree = new MerkleTree(
  leaves.map((x) => keccak256(x)).sort(Buffer.compare),
  keccak256,
  {
    sort: true,
  }
);

// Get root
// const rootHash = merkleTree.getHexRoot();
// Pretty-print tree
// const treeLeaves = merkleTree.getLeaves();

// const indicies = merkleTree.getProofIndices([0, 1]);
// const proof = merkleTree.getHexMultiProof([0, 1]);

// const treeFlat = merkleTree.getLayersFlat();

// const treeFlat = tree.getLayersFlat()
// const leavesCount = leaves.length
// const proofIndices = [1, 0];
// const proofLeaves = proofIndices.map((i) => treeLeaves[i]);
// const proof = merkleTree.getHexMultiProof(treeFlat, proofIndices);
// const proofFlags = merkleTree.getProofFlags(proofLeaves, proof);

const rootHash = merkleTree.getHexRoot();
const proofLeaves = [leaves[0], leaves[1]].map(keccak256);
const proof = merkleTree.getMultiProof(proofLeaves);
const proofFlags = merkleTree.getProofFlags(proofLeaves, proof);

console.error(proof);
console.error(proofLeaves.map((x) => x.toString("hex")));
console.error(proofFlags);
// console.error(strategyDetails);
console.error(
  merkleTree.verifyMultiProofWithFlags(
    rootHash,
    [proofLeaves[1], proofLeaves[0]],
    proof,
    proofFlags
  )
);
console.log(
  defaultAbiCoder.encode(
    ["bytes32", "bytes32[]", "bool[]"],
    [rootHash, proof, proofFlags]
  )
);
