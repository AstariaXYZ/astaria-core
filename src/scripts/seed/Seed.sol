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
import {IERC4626} from "core/interfaces/IERC4626.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {
  StackSeed1A,
  StackSeed1B,
  StackSeed2A,
  StackSeed2B,
} from "core/scripts/deployments/StackSeed.sol";

contract Seed is AstariaStack, TestHelpers {
  AstariaRouter public ASTARIA_ROUTER;
  LienToken public LIEN_TOKEN;

  function setUp() public override(TestHelpers) {}

  function run() public override(Deploy) {
    MockERC20 astariaWETH = MockERC20(
      0x508f2c434E66Df1706CBa7Ae137976C814B5633E
    );
    TestNFT nft = TestNFT(address(0xd6eF92fA2eF2Cb702f0bFfF54b111b076aC0237D));

    //ASTARIA_ROUTER = AstariaRouter(ASTARIA_ROUTER_ADDR);

    //COLLATERAL_TOKEN = CollateralToken(COLLATERAL_TOKEN_ADDR);

    //LIEN_TOKEN = LienToken(LIEN_TOKEN_ADDR);
    address vault = address(0x459043EA157003b59cD7F666aa73Ee664E051250);

    vm.startBroadcast();
    astariaWETH.mint(msg.sender, 5e18);

    uint256 startId = nft.totalSupply();
    for (uint256 i = startId; i < startId + 8; i++) {
      nft.mint(msg.sender, i);
    }

    new StackSeed1A();
    new StackSeed1B();
    new StackSeed2A();
    new StackSeed2B();
    vm.stopBroadcast();
  }
}
