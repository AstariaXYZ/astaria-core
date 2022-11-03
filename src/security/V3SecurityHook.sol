// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import {IV3PositionManager} from "interfaces/IV3PositionManager.sol";
import {ISecurityHook} from "interfaces/ISecurityHook.sol";

contract V3SecurityHook is ISecurityHook {
  address positionManager;

  constructor(address nftManager_) {
    positionManager = nftManager_;
  }

  function getState(address tokenContract, uint256 tokenId)
    external
    view
    returns (bytes memory)
  {
    (
      uint96 nonce,
      address operator,
      ,
      ,
      ,
      ,
      ,
      uint128 liquidity,
      ,
      ,
      ,

    ) = IV3PositionManager(positionManager).positions(tokenId);
    return abi.encode(nonce, operator, liquidity);
  }
}
