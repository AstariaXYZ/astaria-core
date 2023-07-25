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

import {IFlashLoanRecipient} from "core/interfaces/IFlashLoanRecipient.sol";
import {IERC20} from "core/interfaces/IERC20.sol";
import {IBalancerVault} from "core/interfaces/IBalancerVault.sol";
import {IERC721Enumerable} from "core/interfaces/IERC721Enumerable.sol";
import {IWETH9} from "gpl/interfaces/IWETH9.sol";

import {
  LendPoolAddressesProvider
} from "bend-protocol/protocol/LendPoolAddressesProvider.sol";
import {WETHGateway} from "bend-protocol/protocol/WETHGateway.sol";
import {BNFTRegistry} from "bend-protocol/mock/BNFT/BNFTRegistry.sol";
import {
  BendProtocolDataProvider
} from "bend-protocol/misc/BendProtocolDataProvider.sol";

import {IAstariaRouter, AstariaRouter} from "core/AstariaRouter.sol";
import {VaultImplementation} from "core/VaultImplementation.sol";
import {PublicVault} from "core/PublicVault.sol";
import {TransferProxy} from "core/TransferProxy.sol";
import {WithdrawProxy} from "core/WithdrawProxy.sol";

import {Strings2} from "./test/utils/Strings2.sol";

import "./test/TestHelpers.t.sol";

contract ExternalRefinancing is IFlashLoanRecipient {
  AstariaRouter ASTARIA_ROUTER;

  constructor(address router) {
    ASTARIA_ROUTER = AstariaRouter(router);
  }

  address payable constant BEND_WETH_GATEWAY =
    payable(0x3B968D2D299B895A5Fcf3BBa7A64ad0F566e6F88); // TODO make changeable?

  address constant BEND_PROTOCOL_DATA_PROVIDER =
    0x3811DA50f55CCF75376C5535562F5b4797822480;

  address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8; // TODO verify
  address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

  function refinanceFromBenddao(
    address borrower,
    address tokenAddress,
    uint256 tokenId,
    uint256 debt,
    IAstariaRouter.Commitment calldata commitment
  ) public {
    address[] memory nfts = new address[](1);
    nfts[0] = tokenAddress;
    uint256[] memory ids = new uint256[](1);
    ids[0] = tokenId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = debt;

    _flashLoan(debt);
    WETHGateway(payable(BEND_WETH_GATEWAY)).batchRepayETH{value: debt}(
      nfts,
      ids,
      amounts
    );

    ERC721(tokenAddress).approve(address(ASTARIA_ROUTER), tokenId);
    ASTARIA_ROUTER.commitToLien(commitment);
  }

  struct BendLoanData {
    address bnftAddress;
    uint256 tokenId;
  }

  function getBendUserLoanData(
    address borrower
  ) public view returns (BendLoanData[] memory) {
    BendProtocolDataProvider.NftTokenData[]
      memory data = BendProtocolDataProvider(BEND_PROTOCOL_DATA_PROVIDER)
        .getAllNftsTokenDatas();

    uint256 totalOwnedNFTs = 0;
    for (uint256 i = 0; i < data.length; i++) {
      address bnftAddress = data[i].bNftAddress;
      totalOwnedNFTs += ERC721(bnftAddress).balanceOf(borrower);
    }

    BendLoanData[] memory tempBalancesArray = new BendLoanData[](
      totalOwnedNFTs
    );
    uint256 count = 0;

    for (uint256 i = 0; i < data.length; i++) {
      address bnftAddress = data[i].bNftAddress;
      uint256 numBnfts = ERC721(bnftAddress).balanceOf(borrower);

      for (uint256 j = 0; j < numBnfts; j++) {
        uint256 tokenId = IERC721Enumerable(bnftAddress).tokenOfOwnerByIndex(
          borrower,
          j
        );
        tempBalancesArray[count] = BendLoanData(bnftAddress, tokenId);
        count++;
      }
    }

    BendLoanData[] memory balancesArray = new BendLoanData[](count);
    for (uint256 i = 0; i < count; i++) {
      balancesArray[i] = tempBalancesArray[i];
    }

    return balancesArray;
  }

  function receiveFlashLoan(
    IERC20[] memory tokens,
    uint256[] memory amounts,
    uint256[] memory feeAmounts,
    bytes memory userData
  ) external override {
    tokens[0].transfer(BALANCER_VAULT, amounts[0]);
  }

  function _flashLoan(uint256 amount) internal {
    IERC20[] memory tokens = new IERC20[](1);
    tokens[0] = IERC20(WETH);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;
    IBalancerVault(BALANCER_VAULT).flashLoan(
      IFlashLoanRecipient(address(this)),
      tokens,
      amounts,
      bytes("")
    );

    // unwrap WETH, TODO switch to WETH repayments
    IWETH9(WETH).withdraw(amount);
  }

  receive() external payable {}

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
