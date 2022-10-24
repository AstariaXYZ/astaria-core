pragma solidity ^0.8.17;

interface IFlashAction {
  struct Underlying {
    address token;
    uint256 tokenId;
  }

  function onFlashAction(Underlying calldata, bytes calldata)
    external
    returns (bytes32);
}
