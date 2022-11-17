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

import {ERC721} from "gpl/ERC721.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {VaultImplementation} from "../VaultImplementation.sol";
import {PublicVault} from "../PublicVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";
import {OrderParameters} from "seaport/lib/ConsiderationStructs.sol";

contract AstariaTest is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeCastLib for uint256;

  event NonceUpdated(uint32 nonce);
  event VaultShutdown();

  function testVaultShutdown() public {
    address publicVault = _createPublicVault({
      epochLength: 10 days, // 10 days
      strategist: strategistTwo,
      delegate: strategistOne
    });

    vm.expectEmit(true, true, true, true);
    emit VaultShutdown();
    vm.startPrank(strategistTwo);
    VaultImplementation(publicVault).shutdown();
    vm.stopPrank();
    assert(VaultImplementation(publicVault).getShutdown());
  }

  function testIncrementNonceAsStrategistAndDelegate() public {
    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    vm.expectEmit(true, true, true, true);
    emit NonceUpdated(1);
    vm.prank(strategistOne);
    VaultImplementation(privateVault).incrementNonce();

    vm.expectEmit(true, true, true, true);
    emit NonceUpdated(2);
    vm.prank(strategistTwo);
    VaultImplementation(privateVault).incrementNonce();
  }

  function testBasicPublicVaultLoan() public {
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
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    uint256 collateralId = tokenContract.computeId(tokenId);

    // make sure the borrow was successful
    assertEq(WETH9.balanceOf(address(this)), initialBalance + 10 ether);

    vm.warp(block.timestamp + 9 days);

    _repay(stack, 0, 10 ether, address(this));
  }

  function testBasicPrivateVaultLoan() public {
    TestNFT nft = new TestNFT(2);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    _lendToVault(
      Lender({addr: strategistOne, amountToLend: 50 ether}),
      privateVault
    );

    _commitToLien({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    assertEq(WETH9.balanceOf(address(this)), initialBalance + 10 ether);
  }

  function testWithdrawProxy() public {
    TestNFT nft = new TestNFT(3);
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

    uint256 collateralId = tokenContract.computeId(tokenId);

    uint256 vaultTokenBalance = IERC20(publicVault).balanceOf(address(1));

    _signalWithdraw(address(1), publicVault);

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(
      PublicVault(publicVault).getCurrentEpoch()
    );

    assertEq(vaultTokenBalance, IERC20(withdrawProxy).balanceOf(address(1)));

    vm.warp(block.timestamp + 15 days);

    PublicVault(publicVault).processEpoch();

    vm.warp(block.timestamp + 13 days);
    PublicVault(publicVault).transferWithdrawReserve();

    vm.startPrank(address(1));

    WithdrawProxy(withdrawProxy).redeem(
      vaultTokenBalance,
      address(1),
      address(1)
    );
    vm.stopPrank();
    assertEq(
      ERC20(PublicVault(publicVault).asset()).balanceOf(address(1)),
      50 ether
    );
  }

  function testLiquidationAtBoundary() public {
    TestNFT nft = new TestNFT(3);
    vm.label(address(nft), "nft");
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    address publicVault2 = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });
    address publicVault3 = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    address publicVault4 = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    address publicVault5 = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault2
    );
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault3
    );
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault4
    );
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault5
    );

    uint256 vaultTokenBalance = IERC20(publicVault).balanceOf(address(1));
    ILienToken.Stack[] memory stack;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 5 ether,
      isFirstLien: true
    });
    skip(10 seconds);
    (, stack) = _commitToLien({
      vault: publicVault2,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails,
      amount: 5 ether,
      isFirstLien: false,
      stack: stack
    });
    skip(10 seconds);
    (, stack) = _commitToLien({
      vault: publicVault3,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails2,
      amount: 5 ether,
      isFirstLien: false,
      stack: stack
    });
    skip(10 seconds);
    (, stack) = _commitToLien({
      vault: publicVault4,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails3,
      amount: 5 ether,
      isFirstLien: false,
      stack: stack
    });
    skip(10 seconds);
    (, stack) = _commitToLien({
      vault: publicVault5,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails4,
      amount: 5 ether,
      isFirstLien: false,
      stack: stack
    });

    uint256 collateralId = tokenContract.computeId(tokenId);

    _signalWithdraw(address(1), publicVault);
    _signalWithdraw(address(1), publicVault2);
    _signalWithdraw(address(1), publicVault3);
    _signalWithdraw(address(1), publicVault4);
    _signalWithdraw(address(1), publicVault5);

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(
      PublicVault(publicVault).getCurrentEpoch()
    );

    assertEq(vaultTokenBalance, IERC20(withdrawProxy).balanceOf(address(1)));

    skip(14 days); // end of loan
    (uint256 reserve, OrderParameters memory orderParams) = ASTARIA_ROUTER
      .liquidate(collateralId, uint8(0), stack);

    _bid(address(2), orderParams, 33 ether);
    skip(WithdrawProxy(withdrawProxy).getFinalAuctionEnd()); // epoch boundary

    PublicVault(publicVault).processEpoch();

    skip(13 days);
    WithdrawProxy(withdrawProxy).claim();

    PublicVault(publicVault).transferWithdrawReserve();

    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy).redeem(
      vaultTokenBalance,
      address(1),
      address(1)
    );
    vm.stopPrank();
    assertEq(WETH9.balanceOf(address(1)), 50287680745810395000);
  }

  function testBuyoutLien() public {
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
      tokenId: tokenId,
      lienDetails: refinanceLienDetails,
      amount: 10 ether,
      stack: stack
    });

    _lendToVault(
      Lender({addr: strategistOne, amountToLend: 50 ether}),
      privateVault
    );

    VaultImplementation(privateVault).buyoutLien(
      tokenContract.computeId(tokenId),
      uint8(0),
      refinanceTerms,
      stack
    );

    assertEq(
      WETH9.balanceOf(privateVault),
      40 ether - tenthOfRemaining - (accruedInterest - stack[0].point.amount),
      "Incorrect PrivateVault balance"
    );
    assertEq(
      WETH9.balanceOf(publicVault),
      50 ether + tenthOfRemaining + ((accruedInterest - stack[0].point.amount)),
      "Incorrect PublicVault balance"
    );
    assertEq(
      PublicVault(publicVault).getYIntercept(),
      50 ether + tenthOfRemaining + ((accruedInterest - stack[0].point.amount)),
      "Incorrect PublicVault YIntercept"
    );
    assertEq(
      PublicVault(publicVault).totalAssets(),
      50 ether + tenthOfRemaining + (accruedInterest - stack[0].point.amount),
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
      50 ether + tenthOfRemaining + (accruedInterest - stack[0].point.amount),
      "Incorrect withdrawer balance"
    );
  }

  function testReleaseToAddress() public {
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
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    uint256 collateralId = tokenContract.computeId(tokenId);

    // make sure the borrow was successful
    assertEq(WETH9.balanceOf(address(this)), initialBalance + 10 ether);

    vm.warp(block.timestamp + 9 days);

    _repay(stack, 0, 50 ether, address(this));

    COLLATERAL_TOKEN.releaseToAddress(collateralId, address(this));

    assertEq(ERC721(tokenContract).ownerOf(tokenId), address(this));
  }

  function testCollateralTokenFileSetup() public {
    bytes memory astariaRouterAddr = abi.encode(address(0));

    bytes memory securityHook = abi.encode(address(0), address(0));
    COLLATERAL_TOKEN.file(
      ICollateralToken.File(
        ICollateralToken.FileType.SecurityHook,
        securityHook
      )
    );
    assert(COLLATERAL_TOKEN.securityHooks(address(0)) == address(0));
  }

  function testLienTokenFileSetup() public {
    bytes memory collateralIdAddr = abi.encode(address(0));
    LIEN_TOKEN.file(
      ILienToken.File(ILienToken.FileType.CollateralToken, collateralIdAddr)
    );
    assert(LIEN_TOKEN.COLLATERAL_TOKEN() == ICollateralToken(address(0)));
  }

  function testEpochProcessionMultipleActors() public {
    address alice = address(1);
    address bob = address(2);
    address charlie = address(3);
    address devon = address(4);
    address edgar = address(5);

    TestNFT nft = new TestNFT(2);
    _mintNoDepositApproveRouter(address(nft), 5);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(Lender({addr: bob, amountToLend: 50 ether}), publicVault);
    _lendToVault(Lender({addr: alice, amountToLend: 50 ether}), publicVault);

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
    uint256 collateralId = tokenContract.computeId(tokenId);

    vm.warp(block.timestamp + 9 days);
    _repay(stack1, 0, 100 ether, address(this));
    _warpToEpochEnd(publicVault);
    //after epoch end
    uint256 balance = ERC20(PublicVault(publicVault).asset()).balanceOf(
      publicVault
    );
    PublicVault(publicVault).processEpoch();
    _lendToVault(Lender({addr: bob, amountToLend: 50 ether}), publicVault);
    _warpToEpochEnd(publicVault);

    _lendToVault(Lender({addr: alice, amountToLend: 50 ether}), publicVault);
    _signalWithdraw(alice, publicVault);

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
  }

  function testCancelAuction() public {
    address alice = address(1);
    address bob = address(2);
    TestNFT nft = new TestNFT(6);
    uint256 tokenId = uint256(5);
    address tokenContract = address(nft);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(Lender({addr: bob, amountToLend: 150 ether}), publicVault);
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: blueChipDetails,
      amount: 100 ether,
      isFirstLien: true
    });

    uint256 collateralId = tokenContract.computeId(tokenId);
    vm.warp(block.timestamp + 11 days);
    ASTARIA_ROUTER.liquidate(collateralId, uint8(0), stack);
    _bid(address(2), collateralId, 10 ether);
    _cancelAuction(collateralId, address(this));
    assertEq(
      address(this),
      ERC721(tokenContract).ownerOf(tokenId),
      "liquidator did not receive NFT"
    );
  }

  function testAuctionEnd() public {
    address alice = address(1);
    address bob = address(2);
    TestNFT nft = new TestNFT(6);
    uint256 tokenId = uint256(5);
    address tokenContract = address(nft);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(Lender({addr: bob, amountToLend: 150 ether}), publicVault);
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: blueChipDetails,
      amount: 100 ether,
      isFirstLien: true
    });

    uint256 collateralId = tokenContract.computeId(tokenId);
    vm.warp(block.timestamp + 11 days);
    ASTARIA_ROUTER.liquidate(collateralId, uint8(0), stack);
    _bid(address(2), collateralId, 10 ether);
    skip(4 days);
    //    ASTARIA_ROUTER.endAuction(collateralId);
    assertEq(nft.ownerOf(tokenId), address(2), "the owner is not the bidder");
  }

  function testAuctionEndNoBids() public {
    address alice = address(1);
    address bob = address(2);
    TestNFT nft = new TestNFT(6);
    uint256 tokenId = uint256(5);
    address tokenContract = address(nft);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(Lender({addr: bob, amountToLend: 150 ether}), publicVault);
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: blueChipDetails,
      amount: 100 ether,
      isFirstLien: true
    });

    uint256 collateralId = tokenContract.computeId(tokenId);
    vm.warp(block.timestamp + 11 days);
    ASTARIA_ROUTER.liquidate(collateralId, uint8(0), stack);
    skip(4 days);
    //    ASTARIA_ROUTER.endAuction(collateralId);
    PublicVault(publicVault).processEpoch();
    assertEq(
      nft.ownerOf(tokenId),
      address(this),
      "the owner is not the bidder"
    );
  }

  function _cancelAuction(uint256 auctionId, address sender) internal {
    //    (, , , uint256 reserve, ) = AUCTION_HOUSE.getAuctionData(auctionId);
    //    vm.deal(sender, reserve);
    //    vm.startPrank(sender);
    //    WETH9.deposit{value: reserve}();
    //    WETH9.approve(address(TRANSFER_PROXY), reserve);
    //    ASTARIA_ROUTER.cancelAuction(auctionId);
    //    vm.stopPrank();
  }

  uint8 FUZZ_SIZE = uint8(10);

  struct FuzzInputs {
    uint256 lendAmount;
    uint256 lendDay;
    uint64 lenderWithdrawEpoch;
    uint256 borrowAmount;
    uint256 borrowDay;
    bool willRepay;
    uint256 repayAmount;
    uint256 bidAmount;
  }

  modifier validateInputs(FuzzInputs[] memory args) {
    for (uint8 i = 0; i < args.length; i++) {
      FuzzInputs memory input = args[i];
      input.lendAmount = bound(input.lendAmount, 1 ether, 2 ether)
        .safeCastTo64();
      input.lendDay = bound(input.lendDay, 0, 42);
      input.lenderWithdrawEpoch = bound(input.lenderWithdrawEpoch, 0, 3)
        .safeCastTo64();
      input.borrowAmount = bound(input.borrowAmount, 1 ether, 2 ether);
      input.borrowDay = bound(input.borrowDay, 0, 42);

      if (input.willRepay) {
        input.repayAmount = input.borrowAmount;
        input.bidAmount = 0;
      } else {
        input.repayAmount = bound(
          input.repayAmount,
          0 ether,
          input.borrowAmount - 1
        );
        input.bidAmount = bound(
          input.bidAmount,
          0 ether,
          input.borrowAmount * 2
        );
      }
    }
    _;
  }
}
