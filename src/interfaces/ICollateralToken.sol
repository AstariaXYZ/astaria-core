// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 * 
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.15;

import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {IERC721} from "gpl/interfaces/IERC721.sol";

interface ICollateralBase {
  function auctionVault(
    uint256,
    address,
    uint256
  ) external returns (uint256);

  function AUCTION_HOUSE() external view returns (IAuctionHouse);

  function auctionWindow() external view returns (uint256);

  function getUnderlying(uint256) external view returns (address, uint256);
}

interface ICollateralToken is ICollateralBase, IERC721 {}
