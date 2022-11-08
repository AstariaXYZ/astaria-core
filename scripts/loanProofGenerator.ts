import { StrategyTree } from "../lib/astaria-sdk/dist/index";
import { utils, BigNumber } from "ethers";
const { defaultAbiCoder } = utils;
const args = process.argv.slice(2);
const detailsType = parseInt(BigNumber.from(args.shift()).toString());
const leaves = [];
let mapping: any = [];
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
    "address",
    "address",
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

const termData: string[] = defaultAbiCoder
  // @ts-ignore
  .decode(mapping, args.shift())
  .map((x) => {
    // console.error(x);
    if (x instanceof BigNumber) {
      return x.toString();
    }
    return x;
  });

// @ts-ignore
leaves.push(termData);
// console.error(leaves);
//
const output: string = leaves.reduce((acc, cur) => {
  return acc + cur.join(",") + "\n";
}, "");

const merkleTree = new StrategyTree(output);

const rootHash: string = merkleTree.getHexRoot();
const proof = merkleTree.getHexProof(merkleTree.getLeaf(0));
// console.error(
//   merkleTree.verify(proof, MerkleTree.bufferToHex(proofLeaves[0]), rootHash)
// );
console.log(
  defaultAbiCoder.encode(["bytes32", "bytes32[]"], [rootHash, proof])
);
