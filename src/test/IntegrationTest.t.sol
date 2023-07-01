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

import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {VaultImplementation} from "../VaultImplementation.sol";
import {PublicVault} from "../PublicVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";

contract IntegrationTest is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeCastLib for uint256;

  // function testPublicVaultSlopeIncDecIntegration() public {
  //   // mint 2 new NFTs
  //   TestNFT nft = new TestNFT(2);
  //   _mintNoDepositApproveRouter(address(nft), 2);
  //   address tokenContract = address(nft);
  //   uint256 tokenId1 = uint256(1);
  //   uint256 tokenId2 = uint256(2);

  //   // initialize LienDetails 14 days, 50 ETH, @150%
  //   ILienToken.Details memory lienDetails = ILienToken.Details({
  //     maxAmount: 50 ether,
  //     rate: uint256(1e16).mulDivDown(150, 1).mulDivDown(1, 365 days),
  //     duration: 14 days,
  //     maxPotentialDebt: 0 ether,
  //     liquidationInitialAsk: 500 ether
  //   });

  //   // deploy a new PublicVault
  //   address payable publicVault = _createPublicVault({
  //     strategist: strategistOne,
  //     delegate: strategistTwo,
  //     epochLength: 14 days
  //   });

  //   // address 1 lends 50 ETH to the fault
  //   _lendToVault(
  //     Lender({addr: address(1), amountToLend: 50 ether}),
  //     publicVault
  //   );

  //   // commit to a new lien of 10 ETH under LienDetails
  //   uint256 amount = 10 ether;
  //   (uint256[] memory liens, ILienToken.Stack memory stack) = _commitToLien({
  //     vault: payable(publicVault),
  //     strategist: strategistOne,
  //     strategistPK: strategistOnePK,
  //     tokenContract: tokenContract,
  //     tokenId: tokenId1,
  //     lienDetails: lienDetails,
  //     amount: amount,
  //     isFirstLien: true
  //   });

  //   // calculating slope as y2 - y1 / x2 - x1
  //   uint256 expectedSlope1 = amount.mulDivDown(lienDetails.rate, 1e18);

  //   // assert slope matches the calculation
  //   assertEq(
  //     expectedSlope1,
  //     PublicVault(payable(publicVault)).getSlope(),
  //     "Incorrect PublicVault slope calc"
  //   );

  //   // compute the collateralId
  //   uint256 collateralId1 = tokenContract.computeId(tokenId1);

  //   // pay half the lien (5 ETH) w/o warping time so it is the same instant that the Lien was created
  //   stack = _pay(stack, 0, 5 ether, address(this));

  //   // divide the slope by two (because wepaid half the lien so slope shoudl be half the calculation)
  //   uint256 expectedSlope2 = expectedSlope1.mulDivDown(1, 2);
  //   assertEq(
  //     PublicVault(payable(publicVault)).getSlope(),
  //     expectedSlope2,
  //     "Incorrect PublicVault slope calc"
  //   );

  //   // warp forward while 5 ETH is owed
  //   vm.warp(block.timestamp + 14 days - 1);

  //   // should be 5 ETH + accrual
  //   uint256 lienAmount = LIEN_TOKEN.getOwed(stack);

  //   // pay down lien exactly
  //   _pay(stack, 0, lienAmount, address(this));

  //   // assert PublicVault slope is 0 because the Lien was paid off
  //   assertEq(
  //     PublicVault(payable(publicVault)).getSlope(),
  //     0,
  //     "Incorrect PublicVault slope calc"
  //   );
  // }
}
