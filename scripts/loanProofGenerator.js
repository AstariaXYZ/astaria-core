"use strict";
exports.__esModule = true;
var index_1 = require("../lib/astaria-sdk/dist/index");
var ethers_1 = require("ethers");
var defaultAbiCoder = ethers_1.utils.defaultAbiCoder;
var args = process.argv.slice(2);
var detailsType = parseInt(ethers_1.BigNumber.from(args.shift()).toString());
var leaves = [];
var mapping = [];
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
}
else if (detailsType === 1) {
    mapping = [
        "uint8",
        "address",
        "address",
        "uint256",
        "uint256",
        "uint256",
        "uint256",
    ];
}
else if (detailsType === 2) {
    // uint8 version;
    //     address token;
    //     address[] assets;
    //     uint24 fee;
    //     int24 tickLower;
    //     int24 tickUpper;
    //     uint128 minLiquidity;
    //     uint256 amount0Min;
    //     uint256 amount1Min;
    //     address borrower;
    mapping = [
        "uint8",
        "address",
        "address[]",
        "uint24",
        "int24",
        "int24",
        "uint128",
        "uint256",
        "uint256",
        "address",
        "uint256",
        "uint256",
        "uint256",
        "uint256",
    ];
}
// console.error(leaves);
// Create tree
var termData = defaultAbiCoder
    // @ts-ignore
    .decode(mapping, args.shift())
    .map(function (x) {
    // console.error(x);
    if (x instanceof ethers_1.BigNumber) {
        return x.toString();
    }
    return x;
});
// @ts-ignore
leaves.push(termData);
// console.error(leaves);
//
var output = leaves.reduce(function (acc, cur) {
    return acc + cur.join(",") + "\n";
}, "");
var merkleTree = new index_1.StrategyTree(output);
var rootHash = merkleTree.getHexRoot();
var proof = merkleTree.getHexProof(merkleTree.getLeaf(0));
// console.error(
//   merkleTree.verify(proof, MerkleTree.bufferToHex(proofLeaves[0]), rootHash)
// );
console.log(defaultAbiCoder.encode(["bytes32", "bytes32[]"], [rootHash, proof]));
