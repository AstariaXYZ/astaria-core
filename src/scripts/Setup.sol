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

pragma solidity ^0.8.17;

import "core/test/TestHelpers.t.sol";
import {Script} from "forge-std/Script.sol";
import {AstariaStack} from "core/scripts/deployments/AstariaStack.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";

contract Setup is Script {
  function setUp() public {}

  function run() public {
    vm.startBroadcast();
    vm.stopBroadcast();
  }
}
