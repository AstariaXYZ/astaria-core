library SeedUtils {
  function getRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
    uint256 n = leaves.length;
    uint256 offset = 0;
    bytes32[] memory newLeaves = new bytes32[]((n - (n & 1)) * 2);
    for (uint256 i = 0; i < leaves.length; i++) {
      newLeaves[i] = leaves[i];
    }
    uint256 ptr = leaves.length;
    while (n > 0) {
      for (uint256 i = 0; i < n - 1; i += 2) {
        leaves[ptr] = keccak256(
          abi.encodePacked(leaves[offset + i], leaves[offset + i + 1])
        );
      }
      offset += n;
      n = n / 2;
    }
    return leaves[newLeaves.length - 1];
  }

  //TODO: get proof
  function getProof(bytes32[] memory leaves, uint256 index)
    internal
    pure
    returns (bytes32[] memory proof)
  {
    uint256 n = leaves.length;
    uint256 offset = 0;
    uint256 y = index + 1;
    bytes32[] memory newLeaves = new bytes32[]((y - (y & 1)) * 2);
    for (uint256 i = 0; i < leaves.length; i++) {
      newLeaves[i] = leaves[i];
    }
    while (n > 0) {
      for (uint256 i = 0; i < n - 1; i += 2) {
        proof.push(keccak256(
          abi.encodePacked(leaves[offset + i], leaves[offset + i + 1])
        ));
      }
      offset += n;
      n = n / 2;
    }
    
  }
  //TODO: sign EIP712 
}
