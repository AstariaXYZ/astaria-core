import {
  StrategyTree,
  signRootLocal,
  getTypedData,
  Strategy,
} from "@astariaxyz/sdk";
import { utils, BigNumber, Wallet } from "ethers";
const { defaultAbiCoder } = utils;

const main = async () => {
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
      "uint256",
    ];
  } else if (detailsType === 2) {
    mapping = [
      "uint8",
      "address",
      "address",
      "address",
      "address",
      "uint24",
      "int24",
      "int24",
      "uint128",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
      "uint256",
    ];
  }
  // Create tree

  const termData: string[] = defaultAbiCoder
    // @ts-ignore
    .decode(mapping, args.shift())
    .map((x) => {
      if (x instanceof BigNumber) {
        return x.toString();
      }
      return x;
    });

  const pk: string = args.shift() as string;

  const wallet = new Wallet(pk);

  const strategyData: any = defaultAbiCoder.decode(
    ["uint8", "uint256", "address"],
    args.shift() as string
  );

  const strategy: Strategy = {
    version: strategyData[0],
    expiration: strategyData[1],
    vault: strategyData[2],
    nonce: BigNumber.from(0),
    delegate: wallet.address,
  };
  // @ts-ignore
  leaves.push(termData);
  const output: string = leaves.reduce((acc, cur) => {
    return acc + cur.join(",") + "\n";
  }, "");

  const merkleTree = new StrategyTree(output);

  const rootHash: string = merkleTree.getHexRoot();
  const proof = merkleTree.getHexProof(merkleTree.getLeaf(0));
  // console.error(
  //   merkleTree.verify(proof, MerkleTree.bufferToHex(proofLeaves[0]), rootHash)
  // );

  const signature = await signRootLocal(
    await getTypedData(strategy, rootHash, strategy.vault, 31337),
    wallet
  );

  console.log(
    defaultAbiCoder.encode(
      ["bytes32", "bytes32[]", "bytes"],
      [rootHash, proof, utils.joinSignature(signature)]
    )
  );
};

main();
