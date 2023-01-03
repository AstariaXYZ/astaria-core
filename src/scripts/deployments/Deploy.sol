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
import {
  TransparentUpgradeableProxy
} from "lib/seaport/lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {
  ProxyAdmin
} from "lib/seaport/lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {
  Initializable
} from "lib/seaport/lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

contract Deploy is Script {
  enum UserRoles {
    ADMIN,
    ASTARIA_ROUTER,
    WRAPPER,
    TRANSFER_PROXY,
    LIEN_TOKEN
  }

  event Deployed(address);

  CollateralToken COLLATERAL_TOKEN;
  LienToken LIEN_TOKEN;
  AstariaRouter ASTARIA_ROUTER;
  PublicVault PUBLIC_VAULT_IMPLEMENTATION;
  WithdrawProxy WITHDRAW_PROXY;
  Vault SOLO_IMPLEMENTATION;
  TransferProxy TRANSFER_PROXY;
  WETH WETH9;
  MultiRolesAuthority MRA;
  ConsiderationInterface SEAPORT;
  ProxyAdmin PROXY_ADMIN;

  bool testModeDisabled = true;

  function run() public virtual {
    deploy();
  }

  function deploy() public virtual {
    if (testModeDisabled) {
      vm.startBroadcast(msg.sender);
    }

    address weth;

    try vm.envAddress("WETH9_ADDR") {
      weth = vm.envAddress("WETH9_ADDR");
    } catch {}
    if (address(SEAPORT) == address(0)) {
      try vm.envAddress("SEAPORT_ADDR") {
        SEAPORT = ConsiderationInterface(vm.envAddress("SEAPORT_ADDR"));
      } catch {
        revert("SEAPORT_ADDR not found");
      }
    }

    if (weth == address(0)) {
      WETH9 = new WETH();
      if (testModeDisabled) {
        vm.writeLine(
          string(".env"),
          string(abi.encodePacked("WETH9_ADDR=", vm.toString(address(WETH9))))
        );
      }
    } else {
      WETH9 = WETH(payable(weth)); // mainnet weth
      if (testModeDisabled) {
        vm.writeLine(
          string(".env"),
          string(abi.encodePacked("WETH9_ADDR=", vm.toString(address(WETH9))))
        );
      }
    }
    address auth = testModeDisabled ? msg.sender : address(this);
    MRA = new MultiRolesAuthority(auth, Authority(address(0)));
    if (testModeDisabled) {
      vm.writeLine(
        string(".env"),
        string(abi.encodePacked("MRA_ADDR=", vm.toString(address(MRA))))
      );
    }

    TRANSFER_PROXY = new TransferProxy(MRA);
    if (testModeDisabled) {
      //      vm.setEnv("TRANSFER_PROXY_ADDR", address(TRANSFER_PROXY));
      vm.writeLine(
        string(".env"),
        string(
          abi.encodePacked(
            "TRANSFER_PROXY_ADDR=",
            vm.toString(address(TRANSFER_PROXY))
          )
        )
      );
    }

    PROXY_ADMIN = new ProxyAdmin();
    if (testModeDisabled) {
      vm.writeLine(
        string(".env"),
        string(
          abi.encodePacked(
            "PROXY_ADMIN_ADDR=",
            vm.toString(address(PROXY_ADMIN))
          )
        )
      );
    }

    LienToken LT_IMPL = new LienToken();

    if (testModeDisabled) {
      vm.writeLine(
        string(".env"),
        string(
          abi.encodePacked(
            "LIEN_TOKEN_IMPL_ADDR=",
            vm.toString(address(LT_IMPL))
          )
        )
      );
    }
    // LienToken proxy deployment/setup
    TransparentUpgradeableProxy lienTokenProxy = new TransparentUpgradeableProxy(
        address(LT_IMPL),
        address(PROXY_ADMIN),
        abi.encodeWithSelector(
          LIEN_TOKEN.initialize.selector,
          MRA,
          TRANSFER_PROXY
        )
      );
    LIEN_TOKEN = LienToken(address(lienTokenProxy));
    if (testModeDisabled) {
      //      vm.setEnv("TRANSPARENT_UPGRADEABLE_PROXY_ADDR", address(transparentUpgradeableProxy));
      vm.writeLine(
        string(".env"),
        string(
          abi.encodePacked(
            "LIEN_TOKEN_PROXY_ADDR=",
            vm.toString(address(lienTokenProxy))
          )
        )
      );
    }
    ClearingHouse CLEARING_HOUSE_IMPL = new ClearingHouse();

    if (testModeDisabled) {
      //      vm.setEnv("CLEARING_HOUSE_IMPL_ADDR", address(CLEARING_HOUSE_IMPL));
      vm.writeLine(
        string(".env"),
        string(
          abi.encodePacked(
            "CLEARING_HOUSE_IMPL_ADDR=",
            vm.toString(address(CLEARING_HOUSE_IMPL))
          )
        )
      );
    }

    CollateralToken CT_IMPL = new CollateralToken();

    if (testModeDisabled) {
      //      vm.setEnv("COLLATERAL_TOKEN_ADDR", address(COLLATERAL_TOKEN));
      vm.writeLine(
        string(".env"),
        string(
          abi.encodePacked(
            "COLLATERAL_TOKEN_IMPL_ADDR=",
            vm.toString(address(CT_IMPL))
          )
        )
      );
    }
    {
      TransparentUpgradeableProxy collateralTokenProxy = new TransparentUpgradeableProxy(
          address(CT_IMPL),
          address(PROXY_ADMIN),
          abi.encodeWithSelector(
            COLLATERAL_TOKEN.initialize.selector,
            MRA,
            TRANSFER_PROXY,
            ILienToken(address(LIEN_TOKEN)),
            ConsiderationInterface(SEAPORT)
          )
        );
      COLLATERAL_TOKEN = CollateralToken(address(collateralTokenProxy));
      assert(COLLATERAL_TOKEN.owner() == auth);
      if (testModeDisabled) {
        //      vm.setEnv("TRANSPARENT_UPGRADEABLE_PROXY_ADDR", address(transparentUpgradeableProxy));
        vm.writeLine(
          string(".env"),
          string(
            abi.encodePacked(
              "COLLATERAL_TOKEN_PROXY_ADDR=",
              vm.toString(address(collateralTokenProxy))
            )
          )
        );
      }
    }

    SOLO_IMPLEMENTATION = new Vault();
    if (testModeDisabled) {
      vm.writeLine(
        string(".env"),
        string(
          abi.encodePacked(
            "SOLO_IMPLEMENTATION_ADDR=",
            vm.toString(address(SOLO_IMPLEMENTATION))
          )
        )
      );
    }
    PUBLIC_VAULT_IMPLEMENTATION = new PublicVault();
    if (testModeDisabled) {
      vm.writeLine(
        string(".env"),
        string(
          abi.encodePacked(
            "PUBLIC_VAULT_IMPLEMENTATION_ADDR=",
            vm.toString(address(PUBLIC_VAULT_IMPLEMENTATION))
          )
        )
      );
    }
    WITHDRAW_PROXY = new WithdrawProxy();
    if (testModeDisabled) {
      vm.writeLine(
        string(".env"),
        string(
          abi.encodePacked(
            "WITHDRAW_PROXY_ADDR=",
            vm.toString(address(WITHDRAW_PROXY))
          )
        )
      );
    }
    BeaconProxy BEACON_PROXY = new BeaconProxy();
    if (testModeDisabled) {
      vm.writeLine(
        string(".env"),
        string(
          abi.encodePacked(
            "BEACON_PROXY_ADDR=",
            vm.toString(address(BEACON_PROXY))
          )
        )
      );
    }

    {
      AstariaRouter AR_IMPL = new AstariaRouter();
      if (testModeDisabled) {
        vm.writeLine(
          string(".env"),
          string(
            abi.encodePacked(
              "ASTARIA_ROUTER_IMPL_ADDR=",
              vm.toString(address(AR_IMPL))
            )
          )
        );
      }

      TransparentUpgradeableProxy astariaRouterProxy = new TransparentUpgradeableProxy(
          address(AR_IMPL),
          address(PROXY_ADMIN),
          abi.encodeWithSelector(
            AstariaRouter.initialize.selector,
            MRA,
            ICollateralToken(address(COLLATERAL_TOKEN)),
            ILienToken(address(LIEN_TOKEN)),
            ITransferProxy(address(TRANSFER_PROXY)),
            address(PUBLIC_VAULT_IMPLEMENTATION),
            address(SOLO_IMPLEMENTATION),
            address(WITHDRAW_PROXY),
            address(BEACON_PROXY),
            address(CLEARING_HOUSE_IMPL)
          )
        );
      ASTARIA_ROUTER = AstariaRouter(address(astariaRouterProxy));

      if (testModeDisabled) {
        vm.writeLine(
          string(".env"),
          string(
            abi.encodePacked(
              "ASTARIA_ROUTER_PROXY_ADDR=",
              vm.toString(address(astariaRouterProxy))
            )
          )
        );
      }
    }
    {
      ICollateralToken.File[] memory ctfiles = new ICollateralToken.File[](1);

      ctfiles[0] = ICollateralToken.File({
        what: ICollateralToken.FileType.AstariaRouter,
        data: abi.encode(address(ASTARIA_ROUTER))
      });
      COLLATERAL_TOKEN.fileBatch(ctfiles);
    }
    _setupRolesAndCapabilities();

    LIEN_TOKEN.file(
      ILienToken.File(
        ILienToken.FileType.CollateralToken,
        abi.encode(address(COLLATERAL_TOKEN))
      )
    );
    LIEN_TOKEN.file(
      ILienToken.File(
        ILienToken.FileType.AstariaRouter,
        abi.encode(address(ASTARIA_ROUTER))
      )
    );
    if (testModeDisabled) {
      vm.stopBroadcast();
    } else {
      //      _setOwner();
    }
  }

  function _setupRolesAndCapabilities() internal {
    // ROUTER CAPABILITIES

    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      LienToken.createLien.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      TRANSFER_PROXY.tokenTransferFrom.selector,
      true
    );

    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      CollateralToken.auctionVault.selector,
      true
    );

    // LIEN TOKEN CAPABILITIES
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      LienToken.stopLiens.selector,
      true
    );

    MRA.setRoleCapability(
      uint8(UserRoles.LIEN_TOKEN),
      CollateralToken.settleAuction.selector,
      true
    );

    MRA.setRoleCapability(
      uint8(UserRoles.LIEN_TOKEN),
      TRANSFER_PROXY.tokenTransferFrom.selector,
      true
    );

    // SEAPORT CAPABILITIES

    MRA.setUserRole(
      address(ASTARIA_ROUTER),
      uint8(UserRoles.ASTARIA_ROUTER),
      true
    );
    MRA.setUserRole(address(COLLATERAL_TOKEN), uint8(UserRoles.WRAPPER), true);
    MRA.setUserRole(address(LIEN_TOKEN), uint8(UserRoles.LIEN_TOKEN), true);
  }

  function _setOwner() internal {
    MRA.transferOwnership(msg.sender);
    ASTARIA_ROUTER.transferOwnership(msg.sender);
    LIEN_TOKEN.transferOwnership(msg.sender);
    COLLATERAL_TOKEN.transferOwnership(msg.sender);
  }
}
