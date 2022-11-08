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
import {IWithdrawProxy} from "core/interfaces/IWithdrawProxy.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {Clone} from "clones-with-immutable-args/Clone.sol";

abstract contract WithdrawVaultBase is
  Clone,
  IERC4626,
  IRouterBase,
  IWithdrawProxy
{
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

  function asset() public pure virtual override(IERC4626) returns (address) {
    return _getArgAddress(41);
  }

  function VAULT() public pure returns (address) {
    return _getArgAddress(61);
  }

  function CLAIMABLE_EPOCH() public pure returns (uint256) {
    return _getArgUint64(81);
  }
}
