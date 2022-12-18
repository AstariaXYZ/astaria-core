// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
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
import {IPublicVault} from "core/interfaces/IPublicVault.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {VaultImplementation} from "../VaultImplementation.sol";
import {PublicVault} from "../PublicVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";
import {OrderParameters} from "seaport/lib/ConsiderationStructs.sol";

contract WithdrawTest is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeCastLib for uint256;

  // One LP, one lien that's liquidated with no bids, so withdrawing LP does not receive anything from WithdrawProxy
  function testWithdrawLiquidatedNoBids() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

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
    (, ILienToken.Stack[] memory stack) = _commitToLien({
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

    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(
      stack,
      uint8(0)
    );

    vm.warp(block.timestamp + 2 days); // end of auction

    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();
    PublicVault(publicVault).transferWithdrawReserve();

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    assertEq(
      withdrawProxy.previewRedeem(withdrawProxy.balanceOf(address(1))),
      0
    );
  }

  function testLiquidation5050Split() public {
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

    (, ILienToken.Stack[] memory stack1) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    (, ILienToken.Stack[] memory stack2) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: uint256(5),
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    uint256 collateralId = tokenContract.computeId(tokenId);
    uint256 collateralId2 = tokenContract.computeId(uint256(5));

    _signalWithdraw(address(1), publicVault);

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(
      PublicVault(publicVault).getCurrentEpoch()
    );

    skip(14 days);

    OrderParameters memory listedOrder1 = ASTARIA_ROUTER.liquidate(
      stack1,
      uint8(0)
    );
    OrderParameters memory listedOrder2 = ASTARIA_ROUTER.liquidate(
      stack2,
      uint8(0)
    );

    //TODO: figure out how to do multiple bids here properly

    _bid(Bidder(bidder, bidderPK), listedOrder2, 20 ether);
    vm.warp(withdrawProxy.getFinalAuctionEnd());
    emit log_named_uint("finalAuctionEnd", block.timestamp);
    PublicVault(publicVault).processEpoch();

    skip(13 days);

    withdrawProxy.claim();

    PublicVault(publicVault).transferWithdrawReserve();

    vm.startPrank(address(1));
    withdrawProxy.redeem(
      withdrawProxy.balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.stopPrank();

    _signalWithdraw(address(2), publicVault);
    withdrawProxy = PublicVault(publicVault).getWithdrawProxy(
      PublicVault(publicVault).getCurrentEpoch()
    );

    uint256 finalAuctionEnd = withdrawProxy.getFinalAuctionEnd();

    PublicVault(publicVault).processEpoch();
    PublicVault(publicVault).transferWithdrawReserve();
    vm.startPrank(address(2));
    withdrawProxy.redeem(
      withdrawProxy.balanceOf(address(2)),
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
      WETH9.balanceOf(address(1)),
      WETH9.balanceOf(address(2)),
      "Unequal amounts of WETH"
    );
  }

  function testLiquidationBoundaryEpochOrdering() public {
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
    lien1.duration = 13 days; // will set payee to WithdrawProxy
    ILienToken.Stack[][] memory stacks = new ILienToken.Stack[][](2);
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

    ILienToken.Details memory lien2 = standardLienDetails;
    lien2.duration = 27 days; // payee will be sent to WithdrawProxy at liquidation
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

    _warpToEpochEnd(publicVault);

    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidState.selector,
        IPublicVault.InvalidStates.LIENS_OPEN_FOR_EPOCH_NOT_ZERO
      )
    );
    PublicVault(publicVault).processEpoch();

    OrderParameters memory listedOrder1 = ASTARIA_ROUTER.liquidate(
      stacks[0],
      uint8(0)
    );

    WithdrawProxy withdrawProxy1 = PublicVault(publicVault).getWithdrawProxy(0);

    assertEq(
      LIEN_TOKEN.getPayee(liens[0][0]),
      address(withdrawProxy1),
      "First lien not pointing to first WithdrawProxy"
    );

    _bid(Bidder(bidder, bidderPK), listedOrder1, 200 ether);

    vm.warp(withdrawProxy1.getFinalAuctionEnd());
    PublicVault(publicVault).processEpoch(); // epoch 0 processing

    vm.warp(block.timestamp + 14 days);

    OrderParameters memory listedOrder2 = ASTARIA_ROUTER.liquidate(
      stacks[1],
      uint8(0)
    );

    WithdrawProxy withdrawProxy2 = PublicVault(publicVault).getWithdrawProxy(1);

    assertEq(
      LIEN_TOKEN.getPayee(liens[1][0]),
      address(withdrawProxy2),
      "Second lien not pointing to second WithdrawProxy"
    );

    _bid(Bidder(bidderTwo, bidderTwoPK), listedOrder2, 200 ether);

    PublicVault(publicVault).transferWithdrawReserve();

    withdrawProxy1.claim();

    withdrawProxy1.redeem(
      withdrawProxy1.balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.warp(withdrawProxy2.getFinalAuctionEnd());
    PublicVault(publicVault).processEpoch();

    PublicVault(publicVault).transferWithdrawReserve();

    withdrawProxy2.claim(); // TODO maybe 2
    withdrawProxy2.redeem(
      withdrawProxy2.balanceOf(address(2)),
      address(2),
      address(2)
    );
    assertEq(
      WETH9.balanceOf(publicVault),
      0,
      "PublicVault should have 0 assets"
    );
    assertEq(
      WETH9.balanceOf(address(PublicVault(publicVault).getWithdrawProxy(0))),
      0,
      "WithdrawProxy 0 should have 0 assets"
    );
    assertEq(
      WETH9.balanceOf(address(PublicVault(publicVault).getWithdrawProxy(1))),
      0,
      "WithdrawProxy 1 should have 0 assets"
    );

    assertEq(
      WETH9.balanceOf(address(1)),
      50636986777008079750,
      "LPs have different amounts"
    );

    assertEq(
      WETH9.balanceOf(address(2)),
      51212329242753679750,
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

    vm.label(publicVault, "publicVault");

    _lendToVault(
      Lender({addr: address(1), amountToLend: 25 ether}),
      publicVault
    );
    vm.label(address(1), "lender 1");
    _signalWithdrawAtFutureEpoch(address(1), publicVault, 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 25 ether}),
      publicVault
    );
    vm.label(address(2), "lender 2");
    _signalWithdrawAtFutureEpoch(address(2), publicVault, 0);

    _lendToVault(
      Lender({addr: address(3), amountToLend: 50 ether}),
      publicVault
    );
    vm.label(address(3), "lender 3");
    _signalWithdrawAtFutureEpoch(address(3), publicVault, 1);

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days; // payee will be set to WithdrawProxy at liquidation
    lien1.maxAmount = 100 ether;
    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 100 ether,
      isFirstLien: true
    });

    assertEq(
      PublicVault(publicVault).getSlope(),
      4756468797500,
      "incorrect PublicVault slope calc"
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
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(
      stack,
      uint8(0)
    );
    _bid(Bidder(bidder, bidderPK), listedOrder, 150 ether);

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
    );

    assertEq(
      PublicVault(publicVault).getYIntercept(),
      0,
      "PublicVault yIntercept calculation incorrect"
    );

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);
    assertTrue(
      WETH9.balanceOf(address(withdrawProxy)) != 0,
      "WITHDRAWPROXY IS 0"
    );

    vm.startPrank(address(1));
    withdrawProxy.redeem(
      withdrawProxy.balanceOf(address(1)),
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

    // WithdrawProxy(withdrawProxy).claim();
    WithdrawProxy withdrawProxy2 = PublicVault(publicVault).getWithdrawProxy(1);
    withdrawProxy2.claim();
    assertTrue(
      WETH9.balanceOf(address(withdrawProxy2)) != 0,
      "WITHDRAWPROXY 2 IS 0"
    );

    vm.startPrank(address(3));
    withdrawProxy2.redeem(
      withdrawProxy2.balanceOf(address(3)),
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
    assertEq(WETH9.balanceOf(publicVault), 0, "PublicVault still has assets");
  }

  function testBlockingLiquidationsProcessEpoch() public {
    TestNFT nft = new TestNFT(2);
    _mintAndDeposit(address(nft), 5);
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
    uint256[][] memory liens = new uint256[][](2);
    ILienToken.Stack[][] memory stacks = new ILienToken.Stack[][](2);

    (liens[0], stacks[0]) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId1,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    (liens[1], stacks[1]) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId2,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    _warpToEpochEnd(publicVault);

    uint256 collateralId1 = tokenContract.computeId(tokenId1);
    OrderParameters memory listedOrder1 = ASTARIA_ROUTER.liquidate(
      stacks[0],
      uint8(0)
    );

    _bid(Bidder(bidder, bidderPK), listedOrder1, 10000 ether);

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    vm.expectRevert(
      abi.encodeWithSelector(
        WithdrawProxy.InvalidState.selector,
        WithdrawProxy.InvalidStates.PROCESS_EPOCH_NOT_COMPLETE
      )
    );
    withdrawProxy.claim();

    uint256 collateralId2 = tokenContract.computeId(tokenId2);
    OrderParameters memory listedOrder2 = ASTARIA_ROUTER.liquidate(
      stacks[1],
      uint8(0)
    );
    _bid(Bidder(bidder, bidderPK), listedOrder2, 10000 ether);

    vm.expectRevert(
      abi.encodeWithSelector(
        WithdrawProxy.InvalidState.selector,
        WithdrawProxy.InvalidStates.PROCESS_EPOCH_NOT_COMPLETE
      )
    );
    withdrawProxy.claim();

    skip(withdrawProxy.getFinalAuctionEnd());
    PublicVault(publicVault).processEpoch();

    assertEq(
      PublicVault(publicVault).getSlope(),
      0,
      "PublicVault slope after epoch 0 should be 0"
    );
    assertEq(
      PublicVault(publicVault).getWithdrawReserve(),
      30 ether,
      "Incorrect PublicVault withdrawReserve calculation after epoch 0"
    );
    assertEq(
      PublicVault(publicVault).getLiquidationWithdrawRatio(),
      1e18,
      "Incorrect PublicVault withdrawRatio calculation after epoch 0"
    );

    withdrawProxy.claim();
    PublicVault(publicVault).transferWithdrawReserve();

    assertEq(WETH9.balanceOf(publicVault), 0, "PublicVault balance not 0");

    vm.startPrank(address(1));
    withdrawProxy.redeem(
      withdrawProxy.balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(address(1)),
      51150685882784959500,
      "Incorrect LP 1 balance"
    );
  }

  function testZeroizedVaultNewLP() public {
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
    uint256 initialVaultSupply = PublicVault(publicVault).totalSupply();
    _signalWithdrawAtFutureEpoch(address(1), publicVault, 0);
    uint256[][] memory liens = new uint256[][](2);
    ILienToken.Stack[][] memory stacks = new ILienToken.Stack[][](2);
    (liens[0], stacks[0]) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId1,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    _repay(stacks[0], 0, 10 ether, address(this));

    _warpToEpochEnd(publicVault);

    PublicVault(publicVault).processEpoch();

    assertEq(
      PublicVault(publicVault).getSlope(),
      0,
      "PublicVault slope should be 0 after epoch 0"
    );
    assertEq(
      PublicVault(publicVault).totalSupply(),
      0,
      "VaultToken balance should have been burned after epoch 0"
    );
    assertEq(
      PublicVault(publicVault).getWithdrawReserve(),
      50 ether,
      "PublicVault withdrawReserve calculation after epoch 0 incorrect"
    );
    assertEq(
      PublicVault(publicVault).getYIntercept(),
      0,
      "PublicVault yIntercept after epoch 0 should be 0"
    );

    PublicVault(publicVault).transferWithdrawReserve();
    WithdrawProxy withdrawProxy1 = PublicVault(publicVault).getWithdrawProxy(0);
    withdrawProxy1.redeem(
      withdrawProxy1.balanceOf(address(1)),
      address(1),
      address(1)
    );
    assertEq(WETH9.balanceOf(address(1)), 50 ether, "LP 1 balance incorrect");

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      publicVault
    );

    _signalWithdrawAtFutureEpoch(address(2), publicVault, 1);

    ILienToken.Details memory lien2 = standardLienDetails;
    lien2.duration = 14 days; // payee will be set to WithdrawProxy at liquidation

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

    vm.warp(
      PublicVault(publicVault).getEpochEnd(
        PublicVault(publicVault).getCurrentEpoch()
      ) - 1
    );

    _repay(stacks[1], 0, 10575342465745600000, address(this)); // TODO update to precise val
    assertEq(
      initialVaultSupply,
      PublicVault(publicVault).totalSupply(),
      "VaultToken supplies unequal"
    );
    assertEq(
      PublicVault(publicVault).getYIntercept(),
      50575341514451840500,
      "incorrect PublicVault yIntercept calculation after lien 2 repayment"
    );
    assertEq(
      PublicVault(publicVault).totalAssets(),
      50575341514451840500,
      "incorrect PublicVault totalAssets() after lien 2 repayment"
    );
    assertEq(
      PublicVault(publicVault).getSlope(),
      0,
      "PublicVault slope should be 0 after second lien repayment"
    );
    assertEq(
      PublicVault(publicVault).getLiquidationWithdrawRatio(),
      1e18,
      "PublicVault liquidationWithdrawRatio should be 0"
    );

    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();

    assertEq(
      PublicVault(publicVault).getWithdrawReserve(),
      50575341514451840500,
      "Incorrect PublicVault withdrawReserve calculation after epoch 1"
    );
    PublicVault(publicVault).transferWithdrawReserve();
    WithdrawProxy withdrawProxy2 = PublicVault(publicVault).getWithdrawProxy(1);
    withdrawProxy2.redeem(
      withdrawProxy2.balanceOf(address(2)),
      address(2),
      address(2)
    );
    assertEq(
      WETH9.balanceOf(address(2)),
      50575341514451840500,
      "LP 2 balance incorrect"
    );
    assertEq(
      WETH9.balanceOf(publicVault),
      0 ether,
      "PublicVault balance should be 0"
    );
  }

  function testLiquidationNearBoundaryNoWithdraws() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

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

    ILienToken.Details memory details = standardLienDetails;
    details.duration = 13 days;

    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details,
      amount: 10 ether,
      isFirstLien: true
    });

    vm.warp(block.timestamp + 13 days);
    uint256 collateralId = tokenContract.computeId(tokenId);
    assertEq(
      LIEN_TOKEN.getOwed(stack[0]),
      uint192(10534246575335200000),
      "Incorrect lien interest"
    );

    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(
      stack,
      uint8(0)
    );

    _bid(Bidder(bidder, bidderPK), listedOrder, 6.96 ether);
    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    vm.warp(withdrawProxy.getFinalAuctionEnd());
    PublicVault(publicVault).processEpoch();

    vm.warp(block.timestamp + 4 days);

    withdrawProxy.claim();

    assertEq(
      WETH9.balanceOf(publicVault),
      44378530092592593454,
      "Incorrect PublicVault balance"
    );
    assertEq(
      PublicVault(publicVault).getYIntercept(),
      44378530092592593454,
      "Incorrect PublicVault YIntercept"
    );
    assertEq(
      PublicVault(publicVault).totalAssets(),
      44378530092592593454,
      "Incorrect PublicVault totalAssets()"
    );
    assertEq(
      PublicVault(publicVault).getSlope(),
      0,
      "Incorrect PublicVault slope"
    );
  }
}
