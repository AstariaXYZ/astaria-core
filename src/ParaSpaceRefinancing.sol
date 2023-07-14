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

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {
  MultiRolesAuthority
} from "solmate/auth/authorities/MultiRolesAuthority.sol";

import {ERC721} from "gpl/ERC721.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {WETHGateway} from "paraspace/ui/WETHGateway.sol";
//import {WETHGateway} from "lib/paraspace-core/contracts/ui/WETHGateway.sol";
import {IWETHGateway} from "paraspace/ui/interfaces/IWETHGateway.sol";
import {IPool} from "paraspace/interfaces/IPool.sol";
import {PoolCore} from "paraspace/protocol/pool/PoolCore.sol";

import {IAstariaRouter, AstariaRouter} from "core/AstariaRouter.sol";
import {VaultImplementation} from "core/VaultImplementation.sol";
import {PublicVault} from "core/PublicVault.sol";
import {TransferProxy} from "core/TransferProxy.sol";
import {WithdrawProxy} from "core/WithdrawProxy.sol";

import {Strings2} from "./test/utils/Strings2.sol";

import "./test/TestHelpers.t.sol";

contract ParaSpaceRefinancing {
  AstariaRouter ASTARIA_ROUTER;
  address payable constant PARASPACE_WETH_GATEWAY =
    payable(0x92D6C316CdE81f6a179A60Ee4a3ea8A76D40508A); // TODO make changeable?

  constructor(address router) {
    ASTARIA_ROUTER = AstariaRouter(router);
  }

  function refinanceFromParaspace(
    address borrower,
    address tokenAddress,
    uint256 tokenId,
    uint256 debt,
    IAstariaRouter.Commitment calldata commitment
  ) public {
    WETHGateway(PARASPACE_WETH_GATEWAY).repayETH{value: debt}(debt, borrower);
    // flash loan here
    ERC721(tokenAddress).approve(address(ASTARIA_ROUTER), tokenId);
    ASTARIA_ROUTER.commitToLien(commitment);
  }
}
