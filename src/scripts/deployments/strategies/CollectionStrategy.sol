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
import {CollectionValidator} from "../../../strategies/CollectionValidator.sol";
import {TestnetConstants} from "../TestnetConstants.sol";

contract CollectionStrategy is TestnetConstants, Script {
  AstariaRouter router;

  function run() external {
    router = AstariaRouter(ROUTER_ADDR);
    vm.startBroadcast(msg.sender);

    CollectionValidator validator = new CollectionValidator();

    router.file(
      "setStrategyValidator",
      abi.encode(uint8(1), address(validator))
    );

    vm.stopBroadcast();
  }
}
