// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import {IERC721} from "core/interfaces/IERC721.sol";

library CollateralLookup {
  function computeId(address token, uint256 tokenId)
    internal
    view
    returns (uint256)
  {
    require(
      IERC721(token).ownerOf(tokenId) != address(0),
      "must be a valid token id"
    );
    return uint256(keccak256(abi.encodePacked(token, tokenId)));
  }
}
