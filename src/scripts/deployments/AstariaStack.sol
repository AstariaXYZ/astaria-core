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

import "forge-std/Script.sol";
import {AstariaRouter} from "core/AstariaRouter.sol";
import {
  MultiRolesAuthority
} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {TransferProxy} from "core/TransferProxy.sol";
import {CollateralToken} from "core/CollateralToken.sol";
import {LienToken} from "core/LienToken.sol";
import {Consideration} from "seaport-core/src/lib/Consideration.sol";

//goerli deployments
contract AstariaStack is Script {
  address SEAPORT_ADDR = vm.envAddress("SEAPORT_ADDR");
  address WETH9_ADDR = vm.envAddress("WETH9_ADDR");
  address MRA_ADDR = vm.envAddress("MRA_ADDR");
  address TRANSFER_PROXY_ADDR = vm.envAddress("TRANSFER_PROXY_ADDR");
  address LIEN_TOKEN_IMPL_ADDR = vm.envAddress("LIEN_TOKEN_IMPL_ADDR");
  address LIEN_TOKEN_ADDR = vm.envAddress("LIEN_TOKEN_PROXY_ADDR");
  address COLLATERAL_TOKEN_IMPL_ADDR =
    vm.envAddress("COLLATERAL_TOKEN_IMPL_ADDR");
  address COLLATERAL_TOKEN_ADDR = vm.envAddress("COLLATERAL_TOKEN_PROXY_ADDR");
  address SOLO_IMPLEMENTATION_ADDR = vm.envAddress("SOLO_IMPLEMENTATION_ADDR");
  address PUBLIC_VAULT_IMPLEMENTATION_ADDR =
    vm.envAddress("PUBLIC_VAULT_IMPLEMENTATION_ADDR");
  address WITHDRAW_PROXY_ADDR = vm.envAddress("WITHDRAW_PROXY_ADDR");
  address BEACON_PROXY_ADDR = vm.envAddress("BEACON_PROXY_ADDR");
  address CLEARING_HOUSE_IMPL_ADDR = vm.envAddress("CLEARING_HOUSE_IMPL_ADDR");
  address ASTARIA_ROUTER_IMPL_ADDR = vm.envAddress("ASTARIA_ROUTER_IMPL_ADDR");
  address ASTARIA_ROUTER_ADDR = vm.envAddress("ASTARIA_ROUTER_PROXY_ADDR");
}
