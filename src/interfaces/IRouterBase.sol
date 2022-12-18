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

interface IRouterBase {
  function ROUTER() external view returns (IAstariaRouter);

  function IMPL_TYPE() external view returns (uint8);
}
