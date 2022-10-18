const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");
const { utils, BigNumber } = require("ethers");
const { getAddress, solidityKeccak256, defaultAbiCoder } = utils;
const args = process.argv.slice(2);

const detailsType = parseInt(BigNumber.from(args.shift()).toString());
const leaves = [];
let mapping;
if (detailsType === 0) {
  mapping = [
    "uint8",
    "address",
    "uint256",
    "address",
    "uint256",
    "uint256",
    "uint256",
    "uint256",
  ];

} else if (detailsType === 1) {
  mapping = [
    "uint8",
    "address",
    "address",
    "uint256",
    "uint256",
    "uint256",
    "uint256",
  ];
} else if (detailsType === 2) {
  mapping = [
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
  ];
}
// console.error(leaves);
// Create tree

const termData = defaultAbiCoder.decode(mapping, args.shift()).map((x) => {
  if (x instanceof BigNumber) {
    return x.toString();
  }
  return x;
});

leaves.push(defaultAbiCoder.encode(mapping, termData));

const merkleTree = new MerkleTree(
  leaves.map((x) => keccak256(x)).sort(Buffer.compare),
  keccak256,
  {
    sort: true,
  }
);

const rootHash = merkleTree.getHexRoot();
const proofLeaves = [leaves[0]].map(keccak256);
const proof = merkleTree.getHexProof(MerkleTree.bufferToHex(proofLeaves[0]));
// console.error(
//   merkleTree.verify(proof, MerkleTree.bufferToHex(proofLeaves[0]), rootHash)
// );
console.log(
  defaultAbiCoder.encode(["bytes32", "bytes32[]"], [rootHash, proof])
);
