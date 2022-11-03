// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import {IRouterBase} from "core/interfaces/IRouterBase.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";

import {ERC4626Base} from "core/ERC4626Base.sol";

abstract contract WithdrawVaultBase is ERC4626Base, IRouterBase {
  function name() public view virtual returns (string memory);

  function symbol() public view virtual returns (string memory);

  function ROUTER() external pure returns (IAstariaRouter) {
    return IAstariaRouter(_getArgAddress(0));
  }

  function IMPL_TYPE() public pure override(IRouterBase) returns (uint8) {
    return _getArgUint8(20);
  }

  function owner() public pure returns (address) {
    return _getArgAddress(21);
  }

  function underlying()
    public
    pure
    virtual
    override(ERC4626Base)
    returns (address)
  {
    return _getArgAddress(41);
  }
}
