// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity =0.8.17;
import {Script} from "forge-std/Script.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {
  MultiRolesAuthority
} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC721} from "gpl/ERC721.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";

import {IERC20} from "core/interfaces/IERC20.sol";

import {CollateralToken} from "core/CollateralToken.sol";
import {LienToken} from "core/LienToken.sol";
import {AstariaRouter} from "core/AstariaRouter.sol";

import {Vault} from "core/Vault.sol";
import {PublicVault} from "core/PublicVault.sol";
import {TransferProxy} from "core/TransferProxy.sol";

import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";

import {WithdrawProxy} from "core/WithdrawProxy.sol";
import {BeaconProxy} from "core/BeaconProxy.sol";
import {ClearingHouse} from "core/ClearingHouse.sol";
import {IRoyaltyEngine} from "core/interfaces/IRoyaltyEngine.sol";
import {
  ConsiderationInterface
} from "seaport/interfaces/ConsiderationInterface.sol";

interface IWETH9 is IERC20 {
  function deposit() external payable;

  function withdraw(uint256) external;
}

contract Deploy is Script {
  enum UserRoles {
    ADMIN,
    ASTARIA_ROUTER,
    WRAPPER,
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
  AstariaRouter ASTARIA_ROUTER;

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
      WETH9 = IWETH9(address(new WETH()));
      vm.writeLine(
        string(".env"),
        string(abi.encodePacked("WETH9_ADDR=", vm.toString(address(WETH9))))
      );
    } else {
      WETH9 = IWETH9(weth); // mainnet weth
    }
    emit Deployed(address(WETH9));
    MRA = new MultiRolesAuthority(msg.sender, Authority(address(0)));
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

    address SEAPORT = address(1);

    ClearingHouse CLEARING_HOUSE_IMPL = new ClearingHouse();
    address royaltyRegistry = address(
      0x0385603ab55642cb4Dd5De3aE9e306809991804f
    );
    IRoyaltyEngine ROYALTY_REGISTRY = IRoyaltyEngine(address(royaltyRegistry));
    COLLATERAL_TOKEN = new CollateralToken(
      MRA,
      TRANSFER_PROXY,
      ILienToken(address(LIEN_TOKEN)),
      ConsiderationInterface(SEAPORT),
      ROYALTY_REGISTRY
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
      address(BEACON_PROXY),
      address(CLEARING_HOUSE_IMPL)
    );
    emit Deployed(address(ASTARIA_ROUTER));
    vm.writeLine(
      string(".env"),
      string(
        abi.encodePacked("ROUTER_ADDR=", vm.toString(address(ASTARIA_ROUTER)))
      )
    );

    ICollateralToken.File[] memory ctfiles = new ICollateralToken.File[](1);

    ctfiles[0] = ICollateralToken.File({
      what: ICollateralToken.FileType.AstariaRouter,
      data: abi.encode(address(ASTARIA_ROUTER))
    });
    COLLATERAL_TOKEN.fileBatch(ctfiles);
    _setupRolesAndCapabilities();
    _setOwner();
    vm.stopBroadcast();
  }

  function _setupRolesAndCapabilities() internal {
    //TODO refactor deploy flow to use single set of contracts to deploy in test and prod
  }

  function _setOwner() internal {
    MRA.transferOwnership(msg.sender);
    ASTARIA_ROUTER.transferOwnership(msg.sender);
    LIEN_TOKEN.transferOwnership(msg.sender);
    COLLATERAL_TOKEN.transferOwnership(msg.sender);
  }
}
