// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Clone} from "clones-with-immutable-args/Clone.sol";

import {ILienToken} from "interfaces/ILienToken.sol";
import {IRouterBase} from "interfaces/IRouterBase.sol";
import {IAstariaRouter} from "interfaces/IAstariaRouter.sol";

import {PublicVault} from "PublicVault.sol";
import {WithdrawProxy} from "WithdrawProxy.sol";

abstract contract LiquidationAccountantBase is Clone, IRouterBase {
  function ROUTER() public pure returns (IAstariaRouter) {
    return IAstariaRouter(_getArgAddress(0));
  }

  function IMPL_TYPE() public pure returns (uint8) {
    return _getArgUint8(20);
  }

  function underlying() public pure returns (address) {
    return _getArgAddress(21);
  }

  function VAULT() public pure returns (address) {
    return _getArgAddress(41);
  }

  function LIEN_TOKEN() public pure returns (address) {
    return _getArgAddress(61);
  }

  function WITHDRAW_PROXY() public pure returns (address) {
    return _getArgAddress(81);
  }

  function CLAIMABLE_EPOCH() public pure returns (uint256) {
    return _getArgUint64(101);
  }
}
