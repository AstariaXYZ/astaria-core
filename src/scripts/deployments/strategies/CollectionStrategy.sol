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
import {AstariaRouter} from "core/AstariaRouter.sol";
import {CollectionValidator} from "core/strategies/CollectionValidator.sol";
import {AstariaStack} from "../AstariaStack.sol";

contract CollectionStrategy is AstariaStack {
  AstariaRouter router;

  function run() external {
    router = AstariaRouter(ROUTER_ADDR);
    vm.startBroadcast(msg.sender);

    CollectionValidator validator = new CollectionValidator();

    router.file(
      AstariaRouter.File(
        bytes32("setStrategyValidator"),
        abi.encode(uint8(1), address(validator))
      )
    );

    vm.stopBroadcast();
  }
}
