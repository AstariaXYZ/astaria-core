const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");
const { utils, BigNumber } = require("ethers");
const { getAddress, solidityKeccak256, defaultAbiCoder } = utils;
const args = process.argv.slice(2);

const detailsType = parseInt(BigNumber.from(args.shift()).toString());
const leaves = [];
if (detailsType === 0) {
  const detailsMapping = [
    "uint8",
    "address",
    "uint256",
    "address",
    "uint256",
    "uint256",
    "uint256",
    "uint256",
  ];
  const termData = defaultAbiCoder
    .decode(detailsMapping, args.shift())
    .map((x) => {
      if (x instanceof BigNumber) {
        return x.toString();
      }
      return x;
    });
  // digest = solidityKeccak256(...details);
  // console.error(termData);
  const clone = termData.map((x) => x);
  clone[1][7] = "1000";

  // TODO: push these through the sdk to get the correct encoding without doing it here

  leaves.push(defaultAbiCoder.encode(detailsMapping, termData));
  leaves.push(defaultAbiCoder.encode(detailsMapping, clone));
}
// else if (detailsType === 1) {
//   details = [
//     ["uint8", "address", "address", "uint256", "uint256", "uint256", "uint256"],
//     [
//       "1", // version
//       getAddress(args.shift()), // token
//       getAddress(args.shift()), // borrower
//       ...defaultAbiCoder
//         .decode(["uint256", "uint256", "uint256", "uint256"], args.shift())
//         .map((x) => BigNumber.from(x).toString()),
//     ],
//   ];
//   leaves.push(solidityKeccak256(...details));
// } else if (detailsType === 2) {
//   details = [
//     [
//       "uint8",
//       "address",
//       "address[]",
//       "uint24",
//       "int24",
//       "int24",
//       "uint128",
//       "address",
//       "uint256",
//       "uint256",
//       "uint256",
//       "uint256",
//     ],
//     [
//       "1", // version
//       getAddress(args.shift()), // token
//       args.shift(), // assets
//       args.shift(), // fee
//       args.shift(), // tickLower
//       args.shift(), // tickUpper
//       args.shift(), // minLiquidity
//       args.shift(), // borrower
//       ...defaultAbiCoder
//         .decode(["uint256", "uint256", "uint256", "uint256"], args.shift())
//         .map((x) => BigNumber.from(x).toString()),
//     ],
//   ];
//   leaves.push(solidityKeccak256(...details));
// }
// console.error(leaves);
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
const proofLeaves = [leaves[0]].map(keccak256);
const proof = merkleTree.getHexProof(MerkleTree.bufferToHex(proofLeaves[0]));
// console.error(merkleTree.verify(proof, MerkleTree.bufferToHex(proofLeaves[0]), rootHash));
console.log(
  defaultAbiCoder.encode(["bytes32", "bytes32[]"], [rootHash, proof])
);
