// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.16;

import {IERC4626Base} from "interfaces/IERC4626Base.sol";
import {ICollateralToken} from "interfaces/ICollateralToken.sol";
import {IAstariaRouter} from "interfaces/IAstariaRouter.sol";
import {IRouterBase} from "interfaces/IRouterBase.sol";

import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";

interface IAstariaVaultBase is IERC4626Base, IRouterBase {
  function owner() external view returns (address);

  function COLLATERAL_TOKEN() external view returns (ICollateralToken);

  function AUCTION_HOUSE() external view returns (IAuctionHouse);

  function START() external view returns (uint256);

  function EPOCH_LENGTH() external view returns (uint256);

  function VAULT_FEE() external view returns (uint256);
}
