// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */
pragma solidity ^0.8.17;

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Clone} from "clones-with-immutable-args/Clone.sol";

contract ClearingHouse is Clone {
  using SafeTransferLib for ERC20;

  fallback() external payable {
    IAstariaRouter ASTARIA_ROUTER = IAstariaRouter(_getArgAddress(0));
    require(msg.sender == address(ASTARIA_ROUTER.COLLATERAL_TOKEN().SEAPORT()));
    WETH(payable(address(ASTARIA_ROUTER.WETH()))).deposit{value: msg.value}();
    uint256 payment = ASTARIA_ROUTER.WETH().balanceOf(address(this));
    ASTARIA_ROUTER.WETH().safeApprove(
      address(ASTARIA_ROUTER.TRANSFER_PROXY()),
      payment
    );
    ASTARIA_ROUTER.LIEN_TOKEN().payDebtViaClearingHouse(
      _getArgUint256(21),
      payment
    );
  }
}
