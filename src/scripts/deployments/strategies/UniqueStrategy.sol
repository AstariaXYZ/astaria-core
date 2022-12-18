// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */
pragma solidity =0.8.17;

import {Script} from "forge-std/Script.sol";
import {UniqueValidator} from "../../../strategies/UniqueValidator.sol";
import {AstariaStack} from "../AstariaStack.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";

contract UniqueStrategy is AstariaStack {
  IAstariaRouter router;

  function run() external {
    router = IAstariaRouter(ROUTER_ADDR);
    vm.startBroadcast(msg.sender);

    UniqueValidator validator = new UniqueValidator();

    router.file(
      IAstariaRouter.File(
        IAstariaRouter.FileType.StrategyValidator,
        abi.encode(validator.VERSION_TYPE(), address(validator))
      )
    );

    vm.stopBroadcast();
  }
}
