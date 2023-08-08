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
import {TransferProxy, Receiver} from "core/TransferProxy.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {WithdrawProxy} from "core/WithdrawProxy.sol";
import {BeaconProxy} from "core/BeaconProxy.sol";
import {RepaymentHelper} from "core/RepaymentHelper.sol";
import {
  ConsiderationInterface
} from "seaport-types/src/interfaces/ConsiderationInterface.sol";
import {
  TransparentUpgradeableProxy
} from "lib/seaport/lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {
  ProxyAdmin
} from "lib/seaport/lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {
  Initializable
} from "lib/seaport/lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

import {
  ICollectionValidator,
  CollectionValidator
} from "src/strategies/CollectionValidator.sol";
import {
  UniqueValidator,
  IUniqueValidator
} from "src/strategies/UniqueValidator.sol";

contract Deploy is Script {
  enum UserRoles {
    ADMIN,
    ASTARIA_ROUTER,
    WRAPPER,
    TRANSFER_PROXY,
    LIEN_TOKEN,
    PAUSER
  }

  event Deployed(address);

  CollateralToken COLLATERAL_TOKEN;
  LienToken LIEN_TOKEN;
  AstariaRouter ASTARIA_ROUTER;
  PublicVault PUBLIC_VAULT_IMPLEMENTATION;
  WithdrawProxy WITHDRAW_PROXY;
  Vault SOLO_IMPLEMENTATION;
  TransferProxy TRANSFER_PROXY;
  MultiRolesAuthority MRA;
  ConsiderationInterface SEAPORT;
  ProxyAdmin PROXY_ADMIN;
  BeaconProxy BEACON_PROXY;
  RepaymentHelper REPAYMENT_HELPER;

  bool testModeDisabled = true;
  bool setupDefaultStrategies = true;

  WETH WETH9;
  bool pauseAfterDeploy = false;

  function run() public virtual {
    deploy();
  }

  function deploy() public virtual {
    if (testModeDisabled) {
      vm.startBroadcast(msg.sender);
    }

    try vm.envAddress("WETH9_ADDR") {
      WETH9 = WETH(payable(vm.envAddress("WETH9_ADDR")));
    } catch {
      WETH9 = new WETH();
    }
    if (address(SEAPORT) == address(0)) {
      try vm.envAddress("SEAPORT_ADDR") {
        SEAPORT = ConsiderationInterface(vm.envAddress("SEAPORT_ADDR"));
      } catch {
        revert("SEAPORT_ADDR not found");
      }
    }

    // test harness needs to be able to set roles on the MRA, if deploying for real its msg.sender who its deployed as owner
    address auth = testModeDisabled ? msg.sender : address(this);
    MRA = new MultiRolesAuthority(auth, Authority(address(0)));
    if (testModeDisabled) {
      vm.writeLine(
        string(".env"),
        string(abi.encodePacked("MRA_ADDR=", vm.toString(address(MRA))))
      );
    }

    TRANSFER_PROXY = new TransferProxy(MRA, address(new Receiver()));
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
        abi.encodeWithSelector(LIEN_TOKEN.initialize.selector, MRA)
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

    REPAYMENT_HELPER = new RepaymentHelper(
      address(WETH9),
      address(LIEN_TOKEN),
      address(TRANSFER_PROXY)
    );

    if (testModeDisabled) {
      vm.writeLine(
        string(".env"),
        string(
          abi.encodePacked(
            "REPAYMENT_HELPER=",
            vm.toString(address(REPAYMENT_HELPER))
          )
        )
      );
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
    BEACON_PROXY = new BeaconProxy();
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
            address(WETH9)
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

    if (setupDefaultStrategies) {
      _setupDefaultStrategies();
    }

    if (testModeDisabled) {
      _setupRolesAndCapabilities();

      if (pauseAfterDeploy) {
        ASTARIA_ROUTER.__emergencyPause();
      }
      _setOwner();
      vm.stopBroadcast();
    }
  }

  function _setupRolesAndCapabilities() internal {
    // ROUTER CAPABILITIES

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
      LienToken.handleLiquidation.selector,
      true
    );

    //    MRA.setRoleCapability(
    //      uint8(UserRoles.LIEN_TOKEN),
    //      CollateralToken.settleAuction.selector,
    //      true
    //    );

    MRA.setRoleCapability(
      uint8(UserRoles.LIEN_TOKEN),
      TRANSFER_PROXY.tokenTransferFromWithErrorReceiver.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.PAUSER),
      ASTARIA_ROUTER.__emergencyPause.selector,
      true
    );

    MRA.setUserRole(
      address(ASTARIA_ROUTER),
      uint8(UserRoles.ASTARIA_ROUTER),
      true
    );
    MRA.setUserRole(address(COLLATERAL_TOKEN), uint8(UserRoles.WRAPPER), true);
    MRA.setUserRole(address(LIEN_TOKEN), uint8(UserRoles.LIEN_TOKEN), true);

    address pauser;

    try vm.envAddress("PROTOCOL_PASUER_ADDR") {
      pauser = vm.envAddress("PROTOCOL_PASUER_ADDR");
    } catch {
      pauser = testModeDisabled ? msg.sender : address(this);
    }
    MRA.setUserRole(address(pauser), uint8(UserRoles.LIEN_TOKEN), true);
  }

  function _setOwner() internal {
    address guardian;
    try vm.envAddress("GUARDIAN_ADDR") {
      guardian = vm.envAddress("GUARDIAN_ADDR");
    } catch {
      revert("No guardian address set in .env file");
    }
    address manager;
    try vm.envAddress("PROTOCOL_MGR_ADDR") {
      manager = vm.envAddress("PROTOCOL_MGR_ADDR");
    } catch {
      revert("No manager address set in .env file");
    }
    ASTARIA_ROUTER.setNewGuardian(guardian);
    PROXY_ADMIN.transferOwnership(guardian);
    MRA.transferOwnership(guardian);
    ASTARIA_ROUTER.transferOwnership(manager);
    LIEN_TOKEN.transferOwnership(manager);
    COLLATERAL_TOKEN.transferOwnership(manager);
  }

  function _setupDefaultStrategies() internal {
    //strategy unique
    UniqueValidator UNIQUE_STRATEGY_VALIDATOR = new UniqueValidator();
    //strategy collection
    CollectionValidator COLLECTION_STRATEGY_VALIDATOR = new CollectionValidator();
    //strategy univ3

    IAstariaRouter.File[] memory files = new IAstariaRouter.File[](2);

    files[0] = IAstariaRouter.File(
      IAstariaRouter.FileType.StrategyValidator,
      abi.encode(uint8(1), address(UNIQUE_STRATEGY_VALIDATOR))
    );
    files[1] = IAstariaRouter.File(
      IAstariaRouter.FileType.StrategyValidator,
      abi.encode(uint8(2), address(COLLECTION_STRATEGY_VALIDATOR))
    );

    ASTARIA_ROUTER.fileBatch(files);
  }
}
