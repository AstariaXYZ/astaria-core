pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";
import {AstariaRouter} from "../../../AstariaRouter.sol";
import {V3SecurityHook} from "../../../security/V3SecurityHook.sol";
import {UNI_V3Validator} from "../../../strategies/UNI_V3Validator.sol";
import {TestnetConstants} from "../TestnetConstants.sol";
import {CollateralToken} from "../../../CollateralToken.sol";

contract V3Strategy is TestnetConstants, Script {
  function run() external {
    AstariaRouter router = AstariaRouter(ROUTER_ADDR);

    CollateralToken ct = CollateralToken(COLLATERAL_TOKEN_ADDR);
    vm.startBroadcast(msg.sender);

    UNI_V3Validator V3Validator = new UNI_V3Validator();

    router.file(
      "setStrategyValidator",
      abi.encode(uint8(2), address(V3Validator))
    );

    V3SecurityHook V3_SECURITY_HOOK = new V3SecurityHook(
      address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88) //nft position manager
    );

    ct.file(
      bytes32("setSecurityHook"),
      abi.encode(
        address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88), //v3 nft address
        address(V3_SECURITY_HOOK)
      )
    );

    vm.stopBroadcast();
  }
}
