// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

contract SigUtils {
  struct EIP712Message {
    uint256 nonce;
    uint256 deadline;
    bytes32 root;
  }

  bytes32 public constant STRATEGY_TYPEHASH =
    keccak256("StrategyDetails(uint256 nonce,uint256 deadline,bytes32 root)");

  // computes the hash of a permit
  function getStructHash(
    EIP712Message memory _message
  ) internal pure returns (bytes32) {
    return
      keccak256(
        abi.encode(
          STRATEGY_TYPEHASH,
          _message.nonce,
          _message.deadline,
          _message.root
        )
      );
  }

  // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
  function getTypedDataHash(
    bytes32 domainSeperator,
    EIP712Message memory message
  ) public pure returns (bytes32) {
    return
      keccak256(
        abi.encodePacked("\x19\x01", domainSeperator, getStructHash(message))
      );
  }
}
