// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import {ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";

contract ERC721Recipient is ERC721TokenReceiver {
  function onERC721Received(
    address,
    address,
    uint256,
    bytes calldata
  ) public virtual override returns (bytes4) {
    return ERC721TokenReceiver.onERC721Received.selector;
  }
}
