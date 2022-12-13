// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */
pragma solidity =0.8.17;

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Clone} from "clones-with-immutable-args/Clone.sol";

contract ClearingHouse is Clone {
  using SafeTransferLib for ERC20;

  function ROUTER() public pure returns (IAstariaRouter) {
    return IAstariaRouter(_getArgAddress(0));
  }

  function COLLATERAL_ID() public pure returns (uint256) {
    return _getArgUint256(21);
  }

  function IMPL_TYPE() public pure returns (uint8) {
    return _getArgUint8(20);
  }

  fallback() external payable {
    IAstariaRouter ASTARIA_ROUTER = IAstariaRouter(ROUTER());
    require(msg.sender == address(ASTARIA_ROUTER.COLLATERAL_TOKEN().SEAPORT()));
    WETH weth = WETH(payable(address(ASTARIA_ROUTER.WETH())));
    weth.deposit{value: msg.value}();
    uint256 payment = weth.balanceOf(address(this));
    ASTARIA_ROUTER.WETH().safeApprove(
      address(ASTARIA_ROUTER.TRANSFER_PROXY()),
      payment
    );
    ASTARIA_ROUTER.LIEN_TOKEN().payDebtViaClearingHouse(
      COLLATERAL_ID(),
      payment
    );
  }

  function settleLiquidatorNFTClaim() external {
    IAstariaRouter ASTARIA_ROUTER = IAstariaRouter(_getArgAddress(0));

    require(msg.sender == address(ASTARIA_ROUTER.COLLATERAL_TOKEN()));

    ASTARIA_ROUTER.LIEN_TOKEN().payDebtViaClearingHouse(_getArgUint256(21), 0);
  }
}
