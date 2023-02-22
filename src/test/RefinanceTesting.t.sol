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

import {ICollateralToken} from "../interfaces/ICollateralToken.sol";
import {ILienToken} from "../interfaces/ILienToken.sol";
import {IPublicVault} from "../interfaces/IPublicVault.sol";
import {CollateralToken, IFlashAction} from "../CollateralToken.sol";
import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {VaultImplementation} from "../VaultImplementation.sol";
import {IVaultImplementation} from "../interfaces/IVaultImplementation.sol";
import {LienToken} from "../LienToken.sol";
import {PublicVault} from "../PublicVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";

contract RefinanceTesting is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;

  function testPrivateVaultBuysPublicVaultLien() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    // borrow 10 eth against the dummy NFT
    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    vm.warp(block.timestamp + 7 days);

    uint256 accruedInterest = uint256(LIEN_TOKEN.getOwed(stack[0]));
    uint256 tenthOfRemaining = (uint256(
      LIEN_TOKEN.getOwed(stack[0], block.timestamp + 3 days)
    ) - accruedInterest).mulDivDown(1, 10);

    uint256 buyoutFee = _locateCurrentAmount({
      startAmount: tenthOfRemaining,
      endAmount: 0,
      startTime: 1,
      endTime: 1 + standardLienDetails.duration.mulDivDown(900, 1000),
      roundUp: true
    });

    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails,
      amount: 10 ether,
      stack: stack
    });

    _lendToPrivateVault(
      Lender({addr: strategistOne, amountToLend: 50 ether}),
      privateVault
    );
    vm.startPrank(strategistTwo);
    VaultImplementation(privateVault).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(privateVault),
      40 ether - buyoutFee - (accruedInterest - stack[0].point.amount),
      "Incorrect PrivateVault balance"
    );
    assertEq(
      WETH9.balanceOf(publicVault),
      50 ether + buyoutFee + ((accruedInterest - stack[0].point.amount)),
      "Incorrect PublicVault balance"
    );
    assertEq(
      PublicVault(publicVault).getYIntercept(),
      50 ether + buyoutFee + ((accruedInterest - stack[0].point.amount)),
      "Incorrect PublicVault YIntercept"
    );
    assertEq(
      PublicVault(publicVault).totalAssets(),
      50 ether + buyoutFee + (accruedInterest - stack[0].point.amount),
      "Incorrect PublicVault YIntercept"
    );
    assertEq(
      PublicVault(publicVault).getSlope(),
      0,
      "Incorrect PublicVault slope"
    );

    _signalWithdraw(address(1), publicVault);
    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();
    PublicVault(publicVault).transferWithdrawReserve();

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    withdrawProxy.redeem(
      withdrawProxy.balanceOf(address(1)),
      address(1),
      address(1)
    );
    assertEq(
      WETH9.balanceOf(address(1)),
      50 ether + buyoutFee + (accruedInterest - stack[0].point.amount),
      "Incorrect withdrawer balance"
    );
  }

  function testCannotBuyoutLienDifferentCollateral() public {
    TestNFT nft = new TestNFT(2);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    // borrow 10 eth against the dummy NFT
    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });
    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack[] memory stack2) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: uint256(1),
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    vm.warp(block.timestamp + 3 days);

    uint256 accruedInterest = uint256(LIEN_TOKEN.getOwed(stack[0]));
    uint256 tenthOfRemaining = (uint256(
      LIEN_TOKEN.getOwed(stack[0], block.timestamp + 7 days)
    ) - accruedInterest).mulDivDown(1, 10);

    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: uint256(1),
      lienDetails: refinanceLienDetails,
      amount: 10 ether,
      stack: stack
    });

    _lendToPrivateVault(
      Lender({addr: strategistOne, amountToLend: 50 ether}),
      privateVault
    );

    vm.expectRevert(
      abi.encodeWithSelector(
        ILienToken.InvalidState.selector,
        ILienToken.InvalidStates.INVALID_HASH
      )
    );
    VaultImplementation(privateVault).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );
  }

  // Adapted from C4 #303 and #319 with new fee structure
  function testBuyoutLienBothPublicVault() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    // borrow 10 eth against the dummy NFT
    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    vm.warp(block.timestamp + 9 days);

    uint256 owed = uint256(LIEN_TOKEN.getOwed(stack[0]));

    address publicVault2 = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    ILienToken.Details memory sameRateRefinance = refinanceLienDetails;
    sameRateRefinance.rate = getWadRateFromDecimal(150);

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: publicVault2,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: sameRateRefinance,
      amount: 10 ether,
      stack: stack
    });

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      publicVault2
    );

    uint256 originalSlope = PublicVault(publicVault).getSlope();

    VaultImplementation(publicVault2).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );

    assertEq(
      WETH9.balanceOf(publicVault2),
      50 ether - owed,
      "Incorrect PublicVault2 balance"
    );
    assertEq(
      WETH9.balanceOf(publicVault),
      50 ether + (owed - stack[0].point.amount),
      "Incorrect PublicVault balance"
    );
    assertEq(
      PublicVault(publicVault).getYIntercept(),
      50 ether + (owed - stack[0].point.amount),
      "Incorrect PublicVault YIntercept"
    );
    assertEq(
      PublicVault(publicVault).totalAssets(),
      50 ether + (owed - stack[0].point.amount),
      "Incorrect PublicVault totalAssets"
    );
    assertEq(
      PublicVault(publicVault).getSlope(),
      0,
      "Incorrect PublicVault slope"
    );

    _signalWithdraw(address(1), publicVault);
    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();
    PublicVault(publicVault).transferWithdrawReserve();

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    withdrawProxy.redeem(
      withdrawProxy.balanceOf(address(1)),
      address(1),
      address(1)
    );
    assertEq(
      WETH9.balanceOf(address(1)),
      50 ether + (owed - stack[0].point.amount),
      "Incorrect withdrawer balance"
    );

    _warpToEpochEnd(publicVault2);
    PublicVault(publicVault2).processEpoch();

    assertEq(
      WETH9.balanceOf(publicVault2),
      50 ether - owed,
      "Incorrect PublicVault2 balance"
    );

    assertEq(
      PublicVault(publicVault2).totalAssets(),
      50 ether +
        ((14 * 1 days + 1) * getWadRateFromDecimal(150).mulWadDown(owed)),
      "Target PublicVault totalAssets incorrect"
    );
    assertTrue(
      PublicVault(publicVault2).getYIntercept() != 0,
      "Incorrect PublicVault2 YIntercept"
    );
    assertEq(
      PublicVault(publicVault2).getYIntercept(),
      50 ether,
      "Incorrect PublicVault2 YIntercept"
    );
  }

  function getWadRateFromDecimal(
    uint256 decimal
  ) internal pure returns (uint256) {
    return uint256(1e16).mulDivDown(decimal, 365 days);
  }

  function testPublicVaultCannotBuyoutBefore90PercentDurationOver() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    // borrow 10 eth against the dummy NFT
    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    vm.warp(block.timestamp + 7 days);

    address publicVault2 = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    ILienToken.Details memory sameRateRefinance = refinanceLienDetails;
    sameRateRefinance.rate = (uint256(1e16) * 150) / (365 days);

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: publicVault2,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: sameRateRefinance,
      amount: 10 ether,
      stack: stack
    });

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      publicVault2
    );

    vm.expectRevert(
      abi.encodeWithSelector(ILienToken.RefinanceBlocked.selector)
    );
    VaultImplementation(publicVault2).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );
  }

  function testSamePublicVaultRefinanceHasNoFee() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    // borrow 10 eth against the dummy NFT
    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    assertEq(
      LIEN_TOKEN.getPayee(stack[0].point.lienId),
      publicVault,
      "ASDFASDFDSAF"
    );

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails,
      amount: 10 ether,
      stack: stack
    });

    VaultImplementation(publicVault).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );

    assertEq(
      WETH9.balanceOf(publicVault),
      40 ether,
      "PublicVault was charged a fee"
    );
  }

  function testSamePrivateVaultRefinanceHasNoFee() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    _lendToPrivateVault(
      Lender({addr: strategistOne, amountToLend: 50 ether}),
      privateVault
    );

    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    assertEq(
      LIEN_TOKEN.getPayee(stack[0].point.lienId),
      strategistOne,
      "ASDFASDFDSAF"
    );
    assertEq(LIEN_TOKEN.ownerOf(stack[0].point.lienId), strategistOne, "fuck");

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails,
      amount: 10 ether,
      stack: stack
    });

    VaultImplementation(privateVault).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );

    assertEq(
      WETH9.balanceOf(privateVault),
      30 ether,
      "PrivateVault was charged a fee"
    );

    assertEq(
      WETH9.balanceOf(strategistOne),
      10 ether,
      "Strategist did not receive buyout amount"
    );
  }

  function testFailCannotRefinanceAsNotVault() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    // borrow 10 eth against the dummy NFT
    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    vm.warp(block.timestamp + 7 days);

    uint256 accruedInterest = uint256(LIEN_TOKEN.getOwed(stack[0]));
    uint256 tenthOfRemaining = (uint256(
      LIEN_TOKEN.getOwed(stack[0], block.timestamp + 3 days)
    ) - accruedInterest).mulDivDown(1, 10);

    uint256 buyoutFee = _locateCurrentAmount({
      startAmount: tenthOfRemaining,
      endAmount: 0,
      startTime: 1,
      endTime: 1 + standardLienDetails.duration.mulDivDown(900, 1000),
      roundUp: true
    });

    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails,
      amount: 10 ether,
      stack: stack
    });

    _lendToPrivateVault(
      Lender({addr: strategistOne, amountToLend: 50 ether}),
      privateVault
    );

    vm.startPrank(strategistTwo);
    //    vm.expectRevert(
    //      abi.encodeWithSelector(
    //        ILienToken.InvalidSender.selector
    //      )
    //    );
    LIEN_TOKEN.buyoutLien(
      ILienToken.LienActionBuyout({
        chargeable: true,
        position: uint8(0),
        encumber: ILienToken.LienActionEncumber({
          amount: accruedInterest,
          receiver: address(1),
          lien: ASTARIA_ROUTER.validateCommitment({
            commitment: refinanceTerms,
            timeToSecondEpochEnd: 0
          }),
          stack: stack
        })
      })
    );
    vm.stopPrank();
  }
}
