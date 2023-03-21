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
contract StackSeed1A {
  constructor(AstariaRouter ASTARIA_ROUTER, LienToken LIEN_TOKEN) {
    IAstariaRouter.Commitment[] memory commitments = new IAstariaRouter.Commitment[](2);
    
    ASTARIA_ROUTER.commitToLiens(commitments); 
    LIEN_TOKEN.makePayment();//collateralId, stack, amount
    //commit lien
  }
}
contract StackSeed1B {
  constructor() {
    //commit two liens
    //pay off both
    //commit lien
  }
}

contract StackSeed2A {
  //commit two liens
  //refinance first
  //commit lien
}

contract StackSeed2B {
  //commit two liens
  //refinance last
  //comfit lien
}
