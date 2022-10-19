// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */
pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";
import {AstariaRouter} from "../../../AstariaRouter.sol";
import {UniqueValidator} from "../../../strategies/UniqueValidator.sol";
import {TestnetConstants} from "../TestnetConstants.sol";

contract UniqueStrategy is TestnetConstants, Script {
  AstariaRouter router;

  function run() external {
    router = AstariaRouter(ROUTER_ADDR);
    vm.startBroadcast(msg.sender);

    UniqueValidator validator = new UniqueValidator();

    router.file(
      "setStrategyValidator",
      abi.encode(uint8(0), address(validator))
    );

    vm.stopBroadcast();
  }
}
