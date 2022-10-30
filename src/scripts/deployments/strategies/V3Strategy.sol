pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";
import {AstariaRouter} from "core/AstariaRouter.sol";
import {V3SecurityHook} from "core/security/V3SecurityHook.sol";
import {UNI_V3Validator} from "core/strategies/UNI_V3Validator.sol";
import {AstariaStack} from "../AstariaStack.sol";
import {CollateralToken} from "core/CollateralToken.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";

contract V3Strategy is AstariaStack {
  function run() external {
    AstariaRouter router = AstariaRouter(ROUTER_ADDR);

    CollateralToken ct = CollateralToken(COLLATERAL_TOKEN_ADDR);
    vm.startBroadcast(msg.sender);

    UNI_V3Validator V3Validator = new UNI_V3Validator();

    router.file(
      AstariaRouter.File(
        bytes32("setStrategyValidator"),
        abi.encode(uint8(2), address(V3Validator))
      )
    );

    V3SecurityHook V3_SECURITY_HOOK = new V3SecurityHook(
      address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88) //nft position manager
    );

    ct.file(
      ICollateralToken.File(
        bytes32("setSecurityHook"),
        abi.encode(
          address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88), //v3 nft address
          address(V3_SECURITY_HOOK)
        )
      )
    );

    vm.stopBroadcast();
  }
}
