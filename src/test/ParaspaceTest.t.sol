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

import {
  IERC1155Receiver
} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

import {ERC721} from "gpl/ERC721.sol";
import {IV3PositionManager} from "core/interfaces/IV3PositionManager.sol";
import {IERC20} from "core/interfaces/IERC20.sol";
import {ICollateralToken} from "../interfaces/ICollateralToken.sol";
import {ILienToken} from "../interfaces/ILienToken.sol";
import {IPublicVault} from "../interfaces/IPublicVault.sol";
import {CollateralToken} from "../CollateralToken.sol";
import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {VaultImplementation} from "../VaultImplementation.sol";
import {IVaultImplementation} from "../interfaces/IVaultImplementation.sol";
import {LienToken} from "../LienToken.sol";
import {PublicVault} from "../PublicVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";
import {Strings2} from "./utils/Strings2.sol";
import {ClaimFees} from "../actions/UNIV3/ClaimFees.sol";

import {WETHGateway} from "paraspace/ui/WETHGateway.sol";
//import {WETHGateway} from "lib/paraspace-core/contracts/ui/WETHGateway.sol";
import {IWETHGateway} from "paraspace/ui/interfaces/IWETHGateway.sol";
import {IPool} from "paraspace/interfaces/IPool.sol";
import {PoolCore} from "paraspace/protocol/pool/PoolCore.sol";

import "./TestHelpers.t.sol";

contract ParaspaceTest is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;

  address constant WETH_GATEWAY =
    address(0x92D6C316CdE81f6a179A60Ee4a3ea8A76D40508A); // wethgateway proxy
  address constant PARASPACE_VDEBTWETH =
    address(0x87F92191e14d970f919268045A57f7bE84559CEA);
  address constant WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  address constant POOL_ADDRESSES_PROVIDER =
    address(0x6cD30e716ADbE47dADf7319f6F2FB83d507c857d);
  address constant POOL_CORE =
    address(0x542ef16d4074a735DC475516F3E2d824F2b0B450);

  // https://etherscan.io/tx/0xf509456479e7c20880bc9227530d9f2c5b2a085ee54941c756667e8395dc0d84
  address constant LOAN_HOLDER =
    address(0x0001BB2a72173F3a1aaAE96BD0Ddb1f8BE4f91B7);
  uint256 constant REPAY_BLOCK = 17615656;

  uint256 mainnetFork;

  function setUp() public override {
    mainnetFork = vm.createFork(
      "https://eth-mainnet.g.alchemy.com/v2/Zq7Fxle2NDGpJN9WxSE33NShHrdMUpcx"
    );
  }

  function testRepayActiveLoan() public {
    vm.selectFork(mainnetFork);
    vm.roll(REPAY_BLOCK);
    vm.startPrank(LOAN_HOLDER);

    address payable holder = payable(LOAN_HOLDER);
    address payable gateway = payable(WETH_GATEWAY);

    uint256 debt = IERC20(PARASPACE_VDEBTWETH).balanceOf(LOAN_HOLDER);
    vm.deal(LOAN_HOLDER, debt);
    WETHGateway(gateway).repayETH{value: debt}(debt, holder);
    vm.stopPrank();
  }
}
