// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;
import {Script} from "forge-std/Script.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {
  MultiRolesAuthority
} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WEth} from "eip4626/WEth.sol";
import {ERC721} from "gpl/ERC721.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";

import {IERC20} from "../../interfaces/IERC20.sol";

import {CollateralToken} from "../../CollateralToken.sol";
import {LienToken} from "../../LienToken.sol";
import {AstariaRouter} from "../../AstariaRouter.sol";

import {Vault, PublicVault} from "../../PublicVault.sol";
import {TransferProxy} from "../../TransferProxy.sol";

import {ICollateralToken} from "../../interfaces/ICollateralToken.sol";
import {ILienToken} from "../../interfaces/ILienToken.sol";

import {WithdrawProxy} from "../../WithdrawProxy.sol";
import {LiquidationAccountant} from "../../LiquidationAccountant.sol";

interface IWETH9 is IERC20 {
  function deposit() external payable;

  function withdraw(uint256) external;
}

contract Deploy is Script {
  enum UserRoles {
    ADMIN,
    ASTARIA_ROUTER,
    WRAPPER,
    AUCTION_HOUSE,
    TRANSFER_PROXY,
    LIEN_TOKEN
  }

  event Deployed(address);

  IWETH9 WETH9;
  MultiRolesAuthority MRA;
  TransferProxy TRANSFER_PROXY;
  LienToken LIEN_TOKEN;
  CollateralToken COLLATERAL_TOKEN;
  Vault SOLO_IMPLEMENTATION;
  PublicVault VAULT_IMPLEMENTATION;
  WithdrawProxy WITHDRAW_PROXY;
  LiquidationAccountant LIQUIDATION_IMPLEMENTATION;
  AstariaRouter ASTARIA_ROUTER;
  AuctionHouse AUCTION_HOUSE;

  function run() external {
    vm.startBroadcast(msg.sender);

    if (vm.envBool(string("devnet"))) {
      WETH9 = IWETH9(
        address(new WEth("Wrapped Ether Test", "WETH", uint8(18)))
      );
    } else {
      WETH9 = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // mainnet weth
    }
    emit Deployed(address(WETH9));
    MRA = new MultiRolesAuthority(address(msg.sender), Authority(address(0)));
    emit Deployed(address(MRA));

    TRANSFER_PROXY = new TransferProxy(MRA);
    emit Deployed(address(TRANSFER_PROXY));

    LIEN_TOKEN = new LienToken(MRA, TRANSFER_PROXY, address(WETH9));
    emit Deployed(address(LIEN_TOKEN));
    COLLATERAL_TOKEN = new CollateralToken(
      MRA,
      TRANSFER_PROXY,
      ILienToken(address(LIEN_TOKEN))
    );
    emit Deployed(address(COLLATERAL_TOKEN));

    SOLO_IMPLEMENTATION = new Vault();
    emit Deployed(address(SOLO_IMPLEMENTATION));

    VAULT_IMPLEMENTATION = new PublicVault();

    WITHDRAW_PROXY = new WithdrawProxy();
    emit Deployed(address(WITHDRAW_PROXY));

    LIQUIDATION_IMPLEMENTATION = new LiquidationAccountant();
    emit Deployed(address(LIQUIDATION_IMPLEMENTATION));

    ASTARIA_ROUTER = new AstariaRouter(
      MRA,
      address(WETH9),
      ICollateralToken(address(COLLATERAL_TOKEN)),
      ILienToken(address(LIEN_TOKEN)),
      ITransferProxy(address(TRANSFER_PROXY)),
      address(VAULT_IMPLEMENTATION),
      address(SOLO_IMPLEMENTATION)
    );
    emit Deployed(address(ASTARIA_ROUTER));

    ASTARIA_ROUTER.file("WITHDRAW_IMPLEMENTATION", abi.encode(WITHDRAW_PROXY));
    ASTARIA_ROUTER.file(
      "LIQUIDATION_IMPLEMENTATION",
      abi.encode(LIQUIDATION_IMPLEMENTATION)
    );

    //
    AUCTION_HOUSE = new AuctionHouse(
      address(WETH9),
      MRA,
      ICollateralToken(address(COLLATERAL_TOKEN)),
      ILienToken(address(LIEN_TOKEN)),
      TRANSFER_PROXY
    );
    COLLATERAL_TOKEN.file(
      bytes32("setAstariaRouter"),
      abi.encode(address(ASTARIA_ROUTER))
    );
    COLLATERAL_TOKEN.file(
      bytes32("setAuctionHouse"),
      abi.encode(address(AUCTION_HOUSE))
    );
    emit Deployed(address(AUCTION_HOUSE));

    _setupRolesAndCapabilities();
    _setOwner();
    vm.stopBroadcast();
  }

  function _setupRolesAndCapabilities() internal {
    MRA.setRoleCapability(
      uint8(UserRoles.WRAPPER),
      AuctionHouse.createAuction.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.WRAPPER),
      AuctionHouse.endAuction.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      LienToken.createLien.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.WRAPPER),
      AuctionHouse.cancelAuction.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      CollateralToken.auctionVault.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      TRANSFER_PROXY.tokenTransferFrom.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.AUCTION_HOUSE),
      LienToken.removeLiens.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.AUCTION_HOUSE),
      LienToken.stopLiens.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.AUCTION_HOUSE),
      TRANSFER_PROXY.tokenTransferFrom.selector,
      true
    );
    MRA.setUserRole(
      address(ASTARIA_ROUTER),
      uint8(UserRoles.ASTARIA_ROUTER),
      true
    );
    MRA.setUserRole(address(COLLATERAL_TOKEN), uint8(UserRoles.WRAPPER), true);
    MRA.setUserRole(
      address(AUCTION_HOUSE),
      uint8(UserRoles.AUCTION_HOUSE),
      true
    );

    MRA.setRoleCapability(
      uint8(UserRoles.LIEN_TOKEN),
      TRANSFER_PROXY.tokenTransferFrom.selector,
      true
    );
    MRA.setUserRole(address(LIEN_TOKEN), uint8(UserRoles.LIEN_TOKEN), true);
  }

  function _setOwner() internal {
    MRA.setOwner(address(msg.sender));
    ASTARIA_ROUTER.setOwner(address(msg.sender));
    LIEN_TOKEN.setOwner(address(msg.sender));
    COLLATERAL_TOKEN.setOwner(address(msg.sender));
  }
}
