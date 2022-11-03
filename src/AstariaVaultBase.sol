// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {IAstariaVaultBase} from "core/interfaces/IAstariaVaultBase.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {IERC4626Base} from "core/interfaces/IERC4626Base.sol";
import {IRouterBase} from "core/interfaces/IRouterBase.sol";

import {ERC4626Base} from "ERC4626Base.sol";

abstract contract AstariaVaultBase is ERC4626Base, IAstariaVaultBase {
  function name() public view virtual returns (string memory);

  function symbol() public view virtual returns (string memory);

  function ROUTER() public pure returns (IAstariaRouter) {
    return IAstariaRouter(_getArgAddress(0)); //ends at 20
  }

  function IMPL_TYPE() public pure returns (uint8) {
    return _getArgUint8(20); //ends at 21
  }

  function owner() public pure returns (address) {
    return _getArgAddress(21); //ends at 44
  }

  function underlying()
    public
    pure
    virtual
    override(IERC4626Base, ERC4626Base)
    returns (address)
  {
    return _getArgAddress(41); //ends at 64
  }

  function START() public pure returns (uint256) {
    return _getArgUint256(61);
  }

  function EPOCH_LENGTH() public pure returns (uint256) {
    return _getArgUint256(93); //ends at 116
  }

  function VAULT_FEE() public pure returns (uint256) {
    return _getArgUint256(125);
  }

  function AUCTION_HOUSE() public view returns (IAuctionHouse) {
    return ROUTER().AUCTION_HOUSE();
  }

  function COLLATERAL_TOKEN() public view returns (ICollateralToken) {
    return ROUTER().COLLATERAL_TOKEN();
  }
}
