// SPDX-License-Identifier: BUSL-1.1

/**
 *  █████╗ ███████╗████████╗ █████╗ ██████╗ ██╗ █████╗
 * ██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██║██╔══██╗
 * ███████║███████╗   ██║   ███████║██████╔╝██║███████║
 * ██╔══██║╚════██║   ██║   ██╔══██║██╔══██╗██║██╔══██║
 * ██║  ██║███████║   ██║   ██║  ██║██║  ██║██║██║  ██║
 * ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝
 *
 * Astaria Labs, Inc
 */

pragma solidity =0.8.17;

import {Script} from "forge-std/Script.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {CollectionValidator} from "core/strategies/CollectionValidator.sol";
import {AstariaStack} from "../AstariaStack.sol";

contract CollectionStrategy is AstariaStack {
  IAstariaRouter router;

  function run() external {
    router = IAstariaRouter(ASTARIA_ROUTER_ADDR);
    vm.startBroadcast(msg.sender);

    CollectionValidator validator = new CollectionValidator();

    router.file(
      IAstariaRouter.File(
        IAstariaRouter.FileType.StrategyValidator,
        abi.encode(validator.VERSION_TYPE(), address(validator))
      )
    );

    vm.stopBroadcast();
  }
}
