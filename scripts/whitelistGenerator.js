const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");
const { utils } = require("ethers");
const { getAddress, defaultAbiCoder } = utils;
const addresses = process.argv.slice(2);
// List of 7 public Ethereum addresses

// console.log(incomingAddress);
// const addresses = [incomingAddress];
// Hash addresses to get the leaves
const leaves = addresses.map((addr) => keccak256(getAddress(addr.toLowerCase())));
// Create tree
const merkleTree = new MerkleTree(leaves, keccak256, { sort: true });
// Get root
const rootHash = merkleTree.getRoot();
// Pretty-print tree
const proof = merkleTree.getHexProof(merkleTree.getLeaves()[0]);
console.log(
    defaultAbiCoder.encode(["bytes32", "bytes32[]"], [rootHash, proof])
);
// process.stdout.write(defaultAbiCoder.encode(["bytes32"], ["0x" + rootHash]));
