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

import {
  LendPoolAddressesProvider
} from "bend-protocol/protocol/LendPoolAddressesProvider.sol";
//import {BendUpgradeableProxy} from "bend-protocol/libraries/proxy/BendUpgradeableProxy.sol";
import {WETHGateway} from "bend-protocol/protocol/WETHGateway.sol";
import {BNFTRegistry} from "bend-protocol/mock/BNFT/BNFTRegistry.sol";
import {
  BendProtocolDataProvider
} from "bend-protocol/misc/BendProtocolDataProvider.sol";

import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {VaultImplementation} from "../VaultImplementation.sol";
import {PublicVault} from "../PublicVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";

contract BendDaoTest is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeCastLib for uint256;

  uint256 mainnetFork;

  struct Loan {
    address tokenContract;
    uint256 tokenId;
    uint256 outstandingDebt;
  }

  address WETH_GATEWAY = 0x3B968D2D299B895A5Fcf3BBa7A64ad0F566e6F88;
  address LEND_POOL_PROVIDER = 0x24451F47CaF13B24f4b5034e1dF6c0E401ec0e46;
  address PROTOCOL_DATA_PROVIDER = 0x3811DA50f55CCF75376C5535562F5b4797822480;

  function setUp() public override {
    mainnetFork = vm.createFork(
      "https://eth-mainnet.g.alchemy.com/v2/Zq7Fxle2NDGpJN9WxSE33NShHrdMUpcx"
    );
  }

  function testRefinance() public {
    vm.selectFork(mainnetFork);
    vm.roll(17636704);
    vm.startPrank(0x221856C687333A29BBF5c8F29E7e0247436CCF7D);
    address[] memory nfts = new address[](1);
    nfts[0] = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D;
    uint256[] memory ids = new uint256[](1);
    ids[0] = 122;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 48123908081253539840000;
    vm.deal(
      0x221856C687333A29BBF5c8F29E7e0247436CCF7D,
      50123908081253539840000
    );
    WETHGateway(payable(WETH_GATEWAY)).batchRepayETH{
      value: 48123908081253539840000
    }(nfts, ids, amounts);
    vm.stopPrank();
  }

  struct Balance {
    address bnftAddress;
    uint256 balance;
  }

  function getUserLoanData(
    address borrower
  ) public view returns (Balance[] memory) {
    BendProtocolDataProvider.NftTokenData[]
      memory data = BendProtocolDataProvider(PROTOCOL_DATA_PROVIDER)
        .getAllNftsTokenDatas();

    Balance[] memory tempBalancesArray = new Balance[](data.length);
    uint256 count = 0;

    for (uint256 i = 0; i < data.length; i++) {
      address bnftAddress = data[i].bNftAddress;

      uint256 balance = ERC721(bnftAddress).balanceOf(borrower);

      if (balance > 0) {
        tempBalancesArray[count] = Balance(bnftAddress, balance);
        count++;
      }
    }

    Balance[] memory balancesArray = new Balance[](count);
    for (uint256 i = 0; i < count; i++) {
      balancesArray[i] = tempBalancesArray[i];
    }

    return balancesArray;
  }

  function _isInArray(
    address[] memory array,
    address addrToCheck
  ) internal view returns (bool) {
    for (uint256 i = 0; i < array.length; i++) {
      if (array[i] == addrToCheck) {
        return true;
      }
    }
    return false;
  }
}
