pragma solidity =0.8.17;

import "forge-std/Script.sol";

//goerli deployments
contract AstariaStack is Script {
  address WETH9_ADDR = vm.envAddress("WETH9_ADDR");
  address ROUTER_ADDR = vm.envAddress("ROUTER_ADDR");
  address MRA_ADDR = vm.envAddress("MRA_ADDR");
  address TRANSFER_PROXY_ADDR = vm.envAddress("TRANSFER_PROXY_ADDR");
  address LIEN_TOKEN_ADDR = vm.envAddress("LIEN_TOKEN_ADDR");
  address COLLATERAL_TOKEN_ADDR = vm.envAddress("COLLATERAL_TOKEN_ADDR");
  address SOLO_IMPL_ADDR = vm.envAddress("SOLO_IMPL_ADDR");
  address PUBLIC_IMPL_ADDR = vm.envAddress("PUBLIC_IMPL_ADDR");
  address WITHDRAW_PROXY_ADDR = vm.envAddress("WITHDRAW_PROXY_ADDR");
  address LIQUIDATION_ACCOUNTANT_ADDR =
    vm.envAddress("LIQUIDATION_ACCOUNTANT_ADDR");
}
