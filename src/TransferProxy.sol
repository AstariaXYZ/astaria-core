// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity =0.8.17;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";

import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";

contract TransferProxy is Auth, ITransferProxy {
  using SafeTransferLib for ERC20;

  constructor(Authority _AUTHORITY) Auth(msg.sender, _AUTHORITY) {
    //only constructor we care about is  Auth
  }

  function tokenTransferFrom(
    address token,
    address from,
    address to,
    uint256 amount
  ) external requiresAuth {
    ERC20(token).safeTransferFrom(from, to, amount);
  }
}
