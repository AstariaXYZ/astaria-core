// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity =0.8.17;

import {IERC721} from "core/interfaces/IERC721.sol";

library CollateralLookup {
  function computeId(address token, uint256 tokenId)
    internal
    pure
    returns (uint256 hash)
  {
    assembly {
      mstore(0, token) // sets the right most 20 bytes in the first memory slot.
      mstore(0x20, tokenId) // stores tokenId in the second memory slot.
      hash := keccak256(12, 52) // keccak from the 12th byte up to the entire second memory slot.
    }
  }
}
