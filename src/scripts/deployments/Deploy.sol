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
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";

import {IERC20} from "core/interfaces/IERC20.sol";

import {CollateralToken} from "core/CollateralToken.sol";
import {LienToken} from "core/LienToken.sol";
import {AstariaRouter} from "core/AstariaRouter.sol";

import {Vault, PublicVault} from "core/PublicVault.sol";
import {TransferProxy} from "core/TransferProxy.sol";

import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";

import {WithdrawProxy} from "core/WithdrawProxy.sol";
import {LiquidationAccountant} from "core/LiquidationAccountant.sol";
import {BeaconProxy} from "core/BeaconProxy.sol";

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

    try
      vm.removeFile(
        string(abi.encodePacked(".env-", vm.toString(block.chainid)))
      )
    {} catch {}
    address weth;

    try vm.envAddress("WETH9_ADDR") {
      weth = vm.envAddress("WETH9_ADDR");
    } catch {}
    if (weth == address(0)) {
      WETH9 = IWETH9(
        address(new WEth("Wrapped Ether Test", "WETH", uint8(18)))
      );
      vm.writeLine(
        string(".env"),
        string(abi.encodePacked("WETH9_ADDR=", vm.toString(address(WETH9))))
      );
    } else {
      WETH9 = IWETH9(weth); // mainnet weth
    }
    emit Deployed(address(WETH9));
    MRA = new MultiRolesAuthority(address(msg.sender), Authority(address(0)));
    vm.writeLine(
      string(".env"),
      string(abi.encodePacked("MRA_ADDR=", vm.toString(address(MRA))))
    );
    emit Deployed(address(MRA));

    TRANSFER_PROXY = new TransferProxy(MRA);
    emit Deployed(address(TRANSFER_PROXY));
    vm.writeLine(
      string(".env"),
      string(
        abi.encodePacked(
          "TRANSFER_PROXY_ADDR=",
          vm.toString(address(TRANSFER_PROXY))
        )
      )
    );
    LIEN_TOKEN = new LienToken(MRA, TRANSFER_PROXY, address(WETH9));
    emit Deployed(address(LIEN_TOKEN));

    vm.writeLine(
      string(".env"),
      string(
        abi.encodePacked("LIEN_TOKEN_ADDR=", vm.toString(address(LIEN_TOKEN)))
      )
    );

    COLLATERAL_TOKEN = new CollateralToken(
      MRA,
      TRANSFER_PROXY,
      ILienToken(address(LIEN_TOKEN))
    );
    emit Deployed(address(COLLATERAL_TOKEN));

    vm.writeLine(
      string(".env"),
      string(
        abi.encodePacked(
          "COLLATERAL_TOKEN_ADDR=",
          vm.toString(address(COLLATERAL_TOKEN))
        )
      )
    );

    SOLO_IMPLEMENTATION = new Vault();
    emit Deployed(address(SOLO_IMPLEMENTATION));
    vm.writeLine(
      string(".env"),
      string(
        abi.encodePacked(
          "SOLO_IMPL_ADDR=",
          vm.toString(address(SOLO_IMPLEMENTATION))
        )
      )
    );
    VAULT_IMPLEMENTATION = new PublicVault();
    vm.writeLine(
      string(".env"),
      string(
        abi.encodePacked(
          "PUBLIC_IMPL_ADDR=",
          vm.toString(address(VAULT_IMPLEMENTATION))
        )
      )
    );
    WITHDRAW_PROXY = new WithdrawProxy();
    emit Deployed(address(WITHDRAW_PROXY));
    vm.writeLine(
      string(".env"),
      string(
        abi.encodePacked(
          "WITHDRAW_PROXY_ADDR=",
          vm.toString(address(WITHDRAW_PROXY))
        )
      )
    );
    LIQUIDATION_IMPLEMENTATION = new LiquidationAccountant();
    emit Deployed(address(LIQUIDATION_IMPLEMENTATION));
    vm.writeLine(
      string(".env"),
      string(
        abi.encodePacked(
          "LIQUIDATION_ACCOUNTANT_ADDR=",
          vm.toString(address(LIQUIDATION_IMPLEMENTATION))
        )
      )
    );
    BeaconProxy BEACON_PROXY = new BeaconProxy();
    ASTARIA_ROUTER = new AstariaRouter(
      MRA,
      address(WETH9),
      ICollateralToken(address(COLLATERAL_TOKEN)),
      ILienToken(address(LIEN_TOKEN)),
      ITransferProxy(address(TRANSFER_PROXY)),
      address(VAULT_IMPLEMENTATION),
      address(SOLO_IMPLEMENTATION),
      address(WITHDRAW_PROXY),
      address(LIQUIDATION_IMPLEMENTATION),
      address(BEACON_PROXY)
    );
    emit Deployed(address(ASTARIA_ROUTER));
    vm.writeLine(
      string(".env"),
      string(
        abi.encodePacked("ROUTER_ADDR=", vm.toString(address(ASTARIA_ROUTER)))
      )
    );
    //    bytes32[] calldata what = new bytes32[](2);
    //    bytes[] calldata data = new bytes[](2);
    //    what[0] = bytes32("WITHDRAW_IMPLEMENTATION");
    //    what[1] = bytes32("LIQUIDATION_IMPLEMENTATION");
    //    data[0] = abi.encode(address(WITHDRAW_PROXY));
    //    data[1] = abi.encode(address(LIQUIDATION_IMPLEMENTATION));

    //    AstariaRouter.File[] memory files = new AstariaRouter.File[](2);
    //    files[0] = AstariaRouter.File(
    //      bytes32("WITHDRAW_IMPLEMENTATION"),
    //      abi.encode(address(WITHDRAW_PROXY))
    //    );
    //    files[1] = AstariaRouter.File(
    //      bytes32("LIQUIDATION_IMPLEMENTATION"),
    //      abi.encode(address(LIQUIDATION_IMPLEMENTATION))
    //    );
    //    ASTARIA_ROUTER.fileBatch(files);

    AUCTION_HOUSE = new AuctionHouse(
      address(WETH9),
      MRA,
      ICollateralToken(address(COLLATERAL_TOKEN)),
      ILienToken(address(LIEN_TOKEN)),
      TRANSFER_PROXY,
      ASTARIA_ROUTER
    );
    vm.writeLine(
      string(".env"),
      string(
        abi.encodePacked(
          "AUCTION_HOUSE_ADDR=",
          vm.toString(address(AUCTION_HOUSE))
        )
      )
    );
    CollateralToken.File[] memory ctfiles = new ICollateralToken.File[](1);

    ctfiles[0] = ICollateralToken.File({
      what: "setAstariaRouter",
      data: abi.encode(address(ASTARIA_ROUTER))
    });
    ctfiles[1] = ICollateralToken.File({
      what: "setAuctionHouse",
      data: abi.encode(address(AUCTION_HOUSE))
    });
    COLLATERAL_TOKEN.fileBatch(ctfiles);
    emit Deployed(address(AUCTION_HOUSE));

    _setupRolesAndCapabilities();
    _setOwner();
    vm.stopBroadcast();
  }

  function _setupRolesAndCapabilities() internal {
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      AuctionHouse.createAuction.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
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
    //    MRA.setRoleCapability(
    //      uint8(UserRoles.ASTARIA_ROUTER),
    //      CollateralToken.auctionVault.selector,
    //      true
    //    );
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
      uint8(UserRoles.AUCTION_HOUSE),
      bytes4(keccak256(bytes("makePayment(uint256,uint256,uint8,address)"))),
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
    MRA.transferOwnership(address(msg.sender));
    ASTARIA_ROUTER.transferOwnership(address(msg.sender));
    LIEN_TOKEN.transferOwnership(address(msg.sender));
    COLLATERAL_TOKEN.transferOwnership(address(msg.sender));
  }
}
