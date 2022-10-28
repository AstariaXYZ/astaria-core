// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {
  MultiRolesAuthority
} from "solmate/auth/authorities/MultiRolesAuthority.sol";

import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {ERC721} from "gpl/ERC721.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {IPublicVault} from "core/interfaces/IPublicVault.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {IVault, VaultImplementation} from "../VaultImplementation.sol";
import {LiquidationAccountant} from "../LiquidationAccountant.sol";
import {PublicVault} from "../PublicVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";

contract WithdrawTest is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeCastLib for uint256;

  // One LP, one lien that's liquidated with no bids, so withdrawing LP does not receive anything from WithdrawProxy
  function testWithdrawLiquidatedNoBids() public {
    TestNFT nft = new TestNFT(1);
    // _mintAndDeposit(address(nft), 1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 30 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    _signalWithdraw(address(1), publicVault);

    ILienToken.Details memory lien = standardLienDetails;
    lien.duration = 1 days;

    // borrow 10 eth against the dummy NFT
    (, ILienToken.LienEvent[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien,
      amount: 50 ether,
      isFirstLien: true
    });

    uint256 collateralId = tokenContract.computeId(tokenId);

    vm.warp(block.timestamp + lien.duration);

    ASTARIA_ROUTER.liquidate(collateralId, uint8(0), stack);

    // _bid(address(2), collateralId, 1 ether);

    vm.warp(block.timestamp + 2 days); // end of auction

    AUCTION_HOUSE.endAuction(0);

    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();
    PublicVault(publicVault).transferWithdrawReserve();

    address withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    assertEq(
      WithdrawProxy(withdrawProxy).previewRedeem(
        ERC20(withdrawProxy).balanceOf(address(1))
      ),
      0
    );
  }

  function testLiquidationAccountant5050Split() public {
    TestNFT nft = new TestNFT(2);
    _mintNoDepositApproveRouter(address(nft), 5);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      publicVault
    );

    assertEq(
      ERC20(publicVault).balanceOf(address(1)),
      ERC20(publicVault).balanceOf(address(2)),
      "minted supply to LPs not equal"
    );

    (, ILienToken.LienEvent[] memory stack1) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    (, ILienToken.LienEvent[] memory stack2) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: uint256(5),
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: false
    });

    uint256 collateralId = tokenContract.computeId(tokenId);
    uint256 collateralId2 = tokenContract.computeId(uint256(5));

    _signalWithdraw(address(1), publicVault);

    address withdrawProxy = PublicVault(publicVault).getWithdrawProxy(
      PublicVault(publicVault).getCurrentEpoch()
    );

    vm.warp(block.timestamp + 14 days);

    ASTARIA_ROUTER.liquidate(collateralId, uint8(0), stack1);
    ASTARIA_ROUTER.liquidate(collateralId2, uint8(0), stack2); // TODO test this

    _bid(address(3), collateralId, 5 ether);
    _bid(address(3), collateralId2, 20 ether);

    address liquidationAccountant = PublicVault(publicVault)
      .getLiquidationAccountant(0);

    assertTrue(
      liquidationAccountant != address(0),
      "LiquidationAccountant not deployed"
    );
    _warpToEpochEnd(publicVault); // epoch boundary

    PublicVault(publicVault).processEpoch();

    vm.warp(block.timestamp + 13 days);

    LiquidationAccountant(liquidationAccountant).claim();
    uint256 publicVaultBalance = WETH9.balanceOf(publicVault);

    PublicVault(publicVault).transferWithdrawReserve();

    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy).redeem(
      IERC20(withdrawProxy).balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.stopPrank();

    _signalWithdraw(address(2), publicVault);
    withdrawProxy = PublicVault(publicVault).getWithdrawProxy(
      PublicVault(publicVault).getCurrentEpoch()
    );

    _warpToEpochEnd(publicVault);

    PublicVault(publicVault).processEpoch();
    PublicVault(publicVault).transferWithdrawReserve();
    vm.startPrank(address(2));
    WithdrawProxy(withdrawProxy).redeem(
      IERC20(withdrawProxy).balanceOf(address(2)),
      address(2),
      address(2)
    );
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(publicVault),
      0,
      "PublicVault should have 0 assets"
    );
    assertEq(
      WETH9.balanceOf(publicVault),
      0,
      "PublicVault should have 0 assets"
    );
    assertEq(
      WETH9.balanceOf(PublicVault(publicVault).getLiquidationAccountant(0)),
      0,
      "LiquidationAccountant should have 0 assets"
    );
    assertEq(
      WETH9.balanceOf(address(1)),
      WETH9.balanceOf(address(2)),
      "Unequal amounts of WETH"
    );
  }

  function testLiquidationAccountantEpochOrdering() public {
    TestNFT nft = new TestNFT(2);
    _mintNoDepositApproveRouter(address(nft), 2);
    address tokenContract = address(nft);
    uint256 tokenId1 = uint256(1);
    uint256 tokenId2 = uint256(2);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    _signalWithdrawAtFutureEpoch(address(1), publicVault, 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      publicVault
    );

    _signalWithdrawAtFutureEpoch(address(2), publicVault, 1);

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 13 days; // will trigger LiquidationAccountant
    ILienToken.LienEvent[][] memory stacks = new ILienToken.LienEvent[][](2);
    uint256[][] memory liens = new uint256[][](2);

    (liens[0], stacks[0]) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId1,
      lienDetails: lien1,
      amount: 10 ether,
      isFirstLien: true
    });

    uint256 lienId1 = liens[0][0];

    ILienToken.Details memory lien2 = standardLienDetails;
    lien2.duration = 27 days; // will trigger LiquidationAccountant for next epoch
    (liens[1], stacks[1]) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId2,
      lienDetails: lien2,
      amount: 10 ether,
      isFirstLien: true
    });
    uint256 lienId2 = liens[1][0];

    _warpToEpochEnd(publicVault);

    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidState.selector,
        IPublicVault.InvalidStates.LIENS_OPEN_FOR_EPOCH_NOT_ZERO
      )
    );
    PublicVault(publicVault).processEpoch();

    uint256 collateralId1 = tokenContract.computeId(tokenId1);

    ASTARIA_ROUTER.liquidate(collateralId1, uint8(0), stacks[0]);

    address liquidationAccountant1 = PublicVault(publicVault)
      .getLiquidationAccountant(0);

    assertEq(
      LIEN_TOKEN.getPayee(lienId1),
      liquidationAccountant1,
      "First lien not pointing to first LiquidationAccountant"
    );

    _bid(address(3), collateralId1, 20 ether);

    assertTrue(
      liquidationAccountant1 != address(0),
      "LiquidationAccountant 0 not deployed"
    );

    PublicVault(publicVault).processEpoch(); // epoch 0 processing
    LiquidationAccountant(liquidationAccountant1).claim();

    vm.warp(block.timestamp + 14 days);

    uint256 collateralId2 = tokenContract.computeId(tokenId2);

    ASTARIA_ROUTER.liquidate(collateralId2, uint8(0), stacks[1]);

    address liquidationAccountant2 = PublicVault(publicVault)
      .getLiquidationAccountant(1);

    assertEq(
      LIEN_TOKEN.getPayee(lienId2),
      liquidationAccountant2,
      "Second lien not pointing to second LiquidationAccountant"
    );

    _bid(address(3), collateralId2, 20 ether);

    assertTrue(
      liquidationAccountant2 != address(0),
      "LiquidationAccountant 1 not deployed"
    );
    PublicVault(publicVault).transferWithdrawReserve();

    address withdrawProxy1 = PublicVault(publicVault).getWithdrawProxy(0);
    WithdrawProxy(withdrawProxy1).redeem(
      IERC20(withdrawProxy1).balanceOf(address(1)),
      address(1),
      address(1)
    );

    PublicVault(publicVault).processEpoch();
    LiquidationAccountant(liquidationAccountant2).claim();
    PublicVault(publicVault).transferWithdrawReserve();
    address withdrawProxy2 = PublicVault(publicVault).getWithdrawProxy(1);
    WithdrawProxy(withdrawProxy2).redeem(
      IERC20(withdrawProxy2).balanceOf(address(2)),
      address(2),
      address(2)
    );
    assertEq(
      WETH9.balanceOf(publicVault),
      0,
      "PublicVault should have 0 assets"
    );
    assertEq(
      WETH9.balanceOf(PublicVault(publicVault).getWithdrawProxy(0)),
      0,
      "WithdrawProxy 0 should have 0 assets"
    );
    assertEq(
      WETH9.balanceOf(PublicVault(publicVault).getWithdrawProxy(1)),
      0,
      "WithdrawProxy 1 should have 0 assets"
    );
    assertEq(
      WETH9.balanceOf(PublicVault(publicVault).getLiquidationAccountant(0)),
      0,
      "LiquidationAccountant 0 should have 0 assets"
    );
    assertEq(
      WETH9.balanceOf(PublicVault(publicVault).getLiquidationAccountant(1)),
      0,
      "LiquidationAccountant 1 should have 0 assets"
    );

    assertEq(
      WETH9.balanceOf(address(1)),
      50575342941392479750,
      "LPs have different amounts"
    );

    assertEq(
      WETH9.balanceOf(address(2)),
      51150685407138079750,
      "LPs have different amounts"
    );
  }

  enum InvalidStates {
    EPOCH_TOO_LOW,
    EPOCH_TOO_HIGH,
    EPOCH_NOT_OVER,
    WITHDRAW_RESERVE_NOT_ZERO,
    LIENS_OPEN_FOR_EPOCH_NOT_ZERO,
    LIQUIDATION_ACCOUNTANT_FINAL_AUCTION_OPEN,
    LIQUIDATION_ACCOUNTANT_ALREADY_DEPLOYED_FOR_EPOCH
  }
  error InvalidState(InvalidStates);

  function testFutureLiquidationWithBlockingWithdrawReserve() public {
    TestNFT nft = new TestNFT(2);
    _mintAndDeposit(address(nft), 5);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 25 ether}),
      publicVault
    );
    _signalWithdrawAtFutureEpoch(address(1), publicVault, 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 25 ether}),
      publicVault
    );
    _signalWithdrawAtFutureEpoch(address(2), publicVault, 0);

    _lendToVault(
      Lender({addr: address(3), amountToLend: 50 ether}),
      publicVault
    );
    _signalWithdrawAtFutureEpoch(address(3), publicVault, 1);

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days; // will trigger LiquidationAccountant
    lien1.maxAmount = 100 ether;
    (
      uint256[] memory liens,
      ILienToken.LienEvent[] memory stack
    ) = _commitToLien({
        vault: publicVault,
        strategist: strategistOne,
        strategistPK: strategistOnePK,
        tokenContract: tokenContract,
        tokenId: tokenId,
        lienDetails: lien1,
        amount: 100 ether,
        isFirstLien: true
      });

    uint256 lienId = liens[0];

    assertEq(
      PublicVault(publicVault).getSlope(),
      4756468797500,
      "incorrect PublicVault slope calc"
    );

    assertTrue(
      PublicVault(publicVault).getLiquidationAccountant(0) == address(0),
      "LiquidationAccountant should not be deployed"
    );

    _warpToEpochEnd(publicVault);

    assertEq(
      PublicVault(publicVault).getSlope(),
      4756468797500,
      "incorrect PublicVault slope calc"
    );

    PublicVault(publicVault).processEpoch();

    assertEq(
      PublicVault(publicVault).getWithdrawReserve(),
      52876714706962398750,
      "Epoch 0 withdrawReserve calculation incorrect"
    );

    _warpToEpochEnd(publicVault);

    uint256 collateralId = tokenContract.computeId(tokenId);
    ASTARIA_ROUTER.liquidate(collateralId, uint8(0), stack);
    _bid(address(4), collateralId, 150 ether);

    assertTrue(
      PublicVault(publicVault).getLiquidationAccountant(1) != address(0),
      "LiquidationAccountant for epoch 1 not deployed"
    );
    assertEq(
      PublicVault(publicVault).getSlope(),
      0,
      "PublicVault slope should be 0"
    );
    assertEq(
      PublicVault(publicVault).getYIntercept(),
      58630139364418398750,
      "PublicVault yIntercept calculation incorrect"
    );

    vm.warp(block.timestamp + 3 days);

    address accountant1 = PublicVault(publicVault).getLiquidationAccountant(1);

    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidState.selector,
        IPublicVault.InvalidStates.WITHDRAW_RESERVE_NOT_ZERO
      )
    );
    PublicVault(publicVault).processEpoch();

    PublicVault(publicVault).transferWithdrawReserve();
    PublicVault(publicVault).processEpoch();

    PublicVault(publicVault).transferWithdrawReserve();

    assertEq(
      PublicVault(publicVault).getWithdrawReserve(),
      0,
      "withdrawReserve should be 0 after transfer"
    ); // TODO check

    assertEq(
      PublicVault(publicVault).getYIntercept(),
      0,
      "PublicVault yIntercept calculation incorrect"
    );

    address withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);
    assertTrue(WETH9.balanceOf(withdrawProxy) != 0, "WITHDRAWPROXY IS 0");

    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy).redeem(
      IERC20(withdrawProxy).balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.stopPrank();

    vm.startPrank(address(2));
    WithdrawProxy(withdrawProxy).redeem(
      IERC20(withdrawProxy).balanceOf(address(2)),
      address(2),
      address(2)
    );
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(address(1)),
      26438357353481199375,
      "LP 1 WETH balance incorrect"
    );
    assertEq(
      WETH9.balanceOf(address(2)),
      26438357353481199375,
      "LP 2 WETH balance incorrect"
    );

    LiquidationAccountant(accountant1).claim();
    address withdrawProxy2 = PublicVault(publicVault).getWithdrawProxy(1);
    assertTrue(WETH9.balanceOf(withdrawProxy2) != 0, "WITHDRAWPROXY 2 IS 0");

    vm.startPrank(address(3));
    WithdrawProxy(withdrawProxy2).redeem(
      IERC20(withdrawProxy2).balanceOf(address(3)),
      address(3),
      address(3)
    );
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(address(3)),
      58630139364418398750,
      "LP 3 WETH balance incorrect"
    );

    assertEq(WETH9.balanceOf(publicVault), 0, "PUBLICVAULT STILL HAS ASSETS");
    assertEq(
      WETH9.balanceOf(accountant1),
      0,
      "LIQUIDATIONACCOUNTANT STILL HAS ASSETS"
    );
  }
}
