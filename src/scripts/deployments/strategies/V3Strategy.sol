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
import {V3SecurityHook} from "core/security/V3SecurityHook.sol";
import {UNI_V3Validator} from "core/strategies/UNI_V3Validator.sol";
import {AstariaStack} from "../AstariaStack.sol";
import {CollateralToken} from "core/CollateralToken.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";

contract V3Strategy is AstariaStack {
  function run() external {
    IAstariaRouter router = IAstariaRouter(ASTARIA_ROUTER_ADDR);

    CollateralToken ct = CollateralToken(COLLATERAL_TOKEN_ADDR);
    vm.startBroadcast(msg.sender);

    UNI_V3Validator V3Validator = new UNI_V3Validator();

    router.file(
      IAstariaRouter.File(
        IAstariaRouter.FileType.StrategyValidator,
        abi.encode(V3Validator.VERSION_TYPE(), address(V3Validator))
      )
    );

    vm.stopBroadcast();
  }
}
