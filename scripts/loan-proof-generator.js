const sdk = require("@astariaxyz/sdk");
const { utils, BigNumber, Wallet } = require("ethers");

const { defaultAbiCoder } = utils;

const main = async () => {
  const args = process.argv.slice(2);
  const detailsType = parseInt(BigNumber.from(args.shift()).toString());
  const leaves = [];

  let mapping = [];

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
  const termData = defaultAbiCoder.decode(mapping, args.shift()).map((x) => {
    if (x instanceof BigNumber) {
      return x.toString();
    }
    return x;
  });

  const pk = args.shift();

  const wallet = new Wallet(pk);

  const strategyData = defaultAbiCoder.decode(
    ["uint8", "uint256", "address"],
    args.shift()
  );

  const strategy = {
    version: strategyData[0],
    expiration: strategyData[1],
    vault: strategyData[2],
    nonce: BigNumber.from(0),
    delegate: wallet.address,
  };

  leaves.push(termData);

  const output = leaves.reduce((acc, cur) => {
    return acc + cur.join(",") + "\n";
  }, "");

  const merkleTree = new sdk.StrategyTree(output);

  const rootHash = merkleTree.getHexRoot();
  const proof = merkleTree.getHexProof(merkleTree.getLeaf(0));
  const chainId = args.shift();

  const signature = await sdk.signRootLocal(
    await sdk.getTypedData(
      strategy,
      rootHash,
      strategy.vault,
      parseInt(chainId)
    ),
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
