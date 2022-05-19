const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");
const { utils, BigNumber } = require("ethers");
const { getAddress, defaultAbiCoder, parseEther } = utils;
const args = process.argv.slice(2);
// console.log(args);
// List of 7 public Ethereum addresses

// console.log(incomingAddress);
// const addresses = [incomingAddress];
// Hash addresses to get the leaves

// get list of
// address, tokenId, valuation, interest, start, stop, lienPosition, schedule
const leaves = [];
const loan = keccak256([
  BigNumber.from(args[2]),
  BigNumber.from(args[3]),
  BigNumber.from(args[4]),
  BigNumber.from(args[5]),
  BigNumber.from(args[6]),
  BigNumber.from(args[7]),
]);
const collateral = keccak256([args[0], BigNumber.from(args[1])]);

leaves.push(keccak256([loan, collateral]));
// Create tree
const merkleTree = new MerkleTree(leaves, keccak256, { sort: true });
// Get root
const rootHash = merkleTree.getRoot();
// Pretty-print tree
const proof = merkleTree.getHexProof(merkleTree.getLeaves()[0]);
console.log(
  defaultAbiCoder.encode(["bytes32", "bytes32[]"], [rootHash, proof])
);
// console.log(rootHash.toString("hex"));
// process.stdout.write(defaultAbiCoder.encode(["bytes32"], ["0x" + rootHash]));

// collateralVault, maxAmount, interestRate, start, end, lienPosition, schedule;
// 0x938e5ed128458139a9c3306ace87c60bcba9c067	10 1000000000000000000	50000000000000000000	1651810553	1665029753	0	1000000000000000000
// 50000000000000000000	60000000000000000000	1651810553	1670300153	1	10000000000000000000	0xbc4ca0eda7647a8ab7c2061c2e118a18a936f13d	7381
// 30000000000000000000	60000000000000000000	1651810553	1670300153	0	10000000000000000000	0xb47e3cd837ddf8e4c57f05d70ab865de6e193bbb	9138
// 10000000000000000000	60000000000000000000	1651810553	1670300153	1	10000000000000000000	0xb47e3cd837ddf8e4c57f05d70ab865de6e193bbb	9138
//  csv.forEach(function (row:Array<string>) {
//     let loan = utils.solidityKeccak256([ "uint256","uint256","uint256","uint256","uint8","uint256" ], [ row[0], row[1], row[2], row[3], row[4], row[5] ]);
//     let collateral = utils.solidityKeccak256([ "address", "uint256" ], [ row[6], row[7] ]);
//     leaves.push(utils.solidityKeccak256([ "bytes32", "bytes32" ], [ loan, collateral ]));
//   });
