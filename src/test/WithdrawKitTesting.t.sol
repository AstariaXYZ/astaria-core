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
import "core/WithdrawKit.sol";

contract WithdrawKitTesting is TestHelpers {
  error WithdrawReserveNotZero(uint64 epoch, uint256 reserve);

  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeCastLib for uint256;

  function testWithdrawKitSimple() public {
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

    WithdrawKit wk = new WithdrawKit();
    vm.startPrank(address(1));

    withdrawProxy.previewRedeem(vaultTokenBalance);
    WithdrawProxy(withdrawProxy).approve(address(wk), vaultTokenBalance);
    wk.redeem(withdrawProxy, withdrawProxy.previewRedeem(vaultTokenBalance));
    vm.stopPrank();
    assertEq(
      ERC20(PublicVault(publicVault).asset()).balanceOf(address(1)),
      50 ether
    );
  }

  function testWithdrawKitComplic() public {
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

    WithdrawKit wk = new WithdrawKit();
    vm.startPrank(address(1));

    withdrawProxy.previewRedeem(vaultTokenBalance);
    WithdrawProxy(withdrawProxy).approve(address(wk), vaultTokenBalance);
    wk.redeem(withdrawProxy, withdrawProxy.previewRedeem(vaultTokenBalance));
    vm.stopPrank();
    assertEq(
      ERC20(PublicVault(publicVault).asset()).balanceOf(address(1)),
      50 ether
    );
  }

  function testCompleteWithdrawAfterOneEpochWithdrawKit() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 7 days
    });
    _lendToVault(
      Lender({addr: address(1), amountToLend: 60 ether}),
      publicVault
    );

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

    vm.warp(block.timestamp + 3 days);

    _signalWithdraw(address(1), publicVault);
    _warpToEpochEnd(publicVault);

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    emit log_named_string("withdrawProxy symbol", withdrawProxy.symbol());
    emit log_named_string("withdrawProxy name", withdrawProxy.name());
    WithdrawKit wk = new WithdrawKit();
    vm.startPrank(address(1));

    uint256 withdrawTokenBalance = withdrawProxy.balanceOf(address(1));
    WithdrawProxy(withdrawProxy).approve(address(wk), withdrawTokenBalance);
    vm.expectRevert(
      abi.encodeWithSelector(
        WithdrawKit.WithdrawReserveNotZero.selector,
        1,
        10287671708519679750
      )
    );
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();
  }

  function testClaimWithdrawKit() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 7 days
    });
    _lendToVault(
      Lender({addr: address(1), amountToLend: 60 ether}),
      publicVault
    );
    _signalWithdraw(address(1), publicVault);

    ILienToken.Details memory details = standardLienDetails;
    details.duration = 5 days;

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

    skip(6 days);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(
      stack,
      uint8(0)
    );

    _warpToEpochEnd(publicVault);

    skip(3 days);

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    WithdrawKit wk = new WithdrawKit();
    vm.startPrank(address(1));

    uint256 withdrawTokenBalance = withdrawProxy.balanceOf(address(1));
    WithdrawProxy(withdrawProxy).approve(address(wk), withdrawTokenBalance);
    wk.redeem(withdrawProxy, withdrawProxy.previewRedeem(withdrawTokenBalance));
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(address(1)),
      50 ether,
      "LP did not receive all WETH not lent out"
    );
  }

  function testDrainWithdrawKit() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 7 days
    });
    _lendToVault(
      Lender({addr: address(1), amountToLend: 60 ether}),
      publicVault
    );
    _signalWithdraw(address(1), publicVault);

    ILienToken.Details memory details = standardLienDetails;
    details.duration = 13 days;

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

    skip(13 days);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(
      stack,
      uint8(0)
    );

    _bid(Bidder(bidder, bidderPK), listedOrder, 10 ether);

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);
    WithdrawKit wk = new WithdrawKit();
    vm.startPrank(address(1));

    uint256 withdrawTokenBalance = withdrawProxy.balanceOf(address(1));

    WithdrawProxy(withdrawProxy).approve(address(wk), withdrawTokenBalance);
    vm.expectRevert(
      abi.encodeWithSelector(
        WithdrawKit.WithdrawReserveNotZero.selector,
        1,
        3512487316075939884
      )
    );
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();
  }

  function testWithdrawKitAbandonedVault() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 7 days
    });
    _lendToVault(
      Lender({addr: address(1), amountToLend: 60 ether}),
      publicVault
    );
    _signalWithdraw(address(1), publicVault);

    ILienToken.Details memory details = standardLienDetails;

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

    skip(5 days);
    _repay(stack, 0, 100 ether, address(this));

    skip(10 weeks);
    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);
    WithdrawKit wk = new WithdrawKit();
    vm.startPrank(address(1));

    uint256 withdrawTokenBalance = withdrawProxy.balanceOf(address(1));

    WithdrawProxy(withdrawProxy).approve(address(wk), withdrawTokenBalance);
    wk.redeem(withdrawProxy, withdrawProxy.previewRedeem(withdrawTokenBalance));
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(address(1)),
      60205479452052000000,
      "LP did not receive all WETH not lent out"
    );
  }

  function testWithdrawKitWithEmptyLiquidation() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 30 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
    _signalWithdraw(address(1), publicVault);
    ILienToken.Details memory lien = standardLienDetails;
    lien.duration = 1 days;

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
    skip(1 days);

    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(
      stack,
      uint8(0)
    );

    WithdrawKit wk = new WithdrawKit();

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);
    _warpToEpochEnd(publicVault);
    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy).approve(address(wk), LP1Balance);
    vm.expectRevert(); // ZERO_ASSETS
    wk.redeem(withdrawProxy, LP1Balance);
    vm.stopPrank();
  }

  function testWithdrawKitEvenLiquidation() public {
    WithdrawKit wk = new WithdrawKit();
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

    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      publicVault
    );
    uint256 LP2Balance = ERC20(publicVault).balanceOf(address(2));

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

    _bid(Bidder(bidder, bidderPK), listedOrder2, 20 ether);
    vm.warp(withdrawProxy.getFinalAuctionEnd());

    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy).approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy, withdrawProxy.previewRedeem(LP1Balance));
    vm.stopPrank();

    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();

    _warpToEpochEnd(publicVault);
    _signalWithdraw(address(2), publicVault);
    withdrawProxy = PublicVault(publicVault).getWithdrawProxy(2);
    PublicVault(publicVault).processEpoch();

    vm.startPrank(address(2));
    WithdrawProxy(withdrawProxy).approve(address(wk), LP2Balance);
    wk.redeem(withdrawProxy, withdrawProxy.previewRedeem(LP2Balance));
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

  function testWithdrawKitAuctionBoundaryEpochOrdering() public {
    WithdrawKit wk = new WithdrawKit();
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

    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));

    _signalWithdrawAtFutureEpoch(address(1), publicVault, 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      publicVault
    );

    uint256 LP2Balance = ERC20(publicVault).balanceOf(address(2));

    _signalWithdrawAtFutureEpoch(address(2), publicVault, 1);

    //    ILienToken.Details memory lien1 = standardLienDetails;
    //    lien1.duration = 13 days; // will set payee to WithdrawProxy
    ILienToken.Stack[][] memory stacks = new ILienToken.Stack[][](2);
    uint256[][] memory liens = new uint256[][](2);

    (liens[0], stacks[0]) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId1,
      lienDetails: standardLienDetails13Days,
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

    //    WithdrawProxy withdrawProxy2 = PublicVault(publicVault).getWithdrawProxy(1);

    //    assertEq(
    //      LIEN_TOKEN.getPayee(liens[1][0]),
    //      address(withdrawProxy2),
    //      "Second lien not pointing to second WithdrawProxy"
    //    );

    _bid(Bidder(bidderTwo, bidderTwoPK), listedOrder2, 200 ether);
    //
    //    PublicVault(publicVault).transferWithdrawReserve();
    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy1).approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy1, 0);
    vm.stopPrank();

    withdrawProxy1 = PublicVault(publicVault).getWithdrawProxy(1);
    vm.warp(withdrawProxy1.getFinalAuctionEnd());

    vm.startPrank(address(2));
    WithdrawProxy(withdrawProxy1).approve(address(wk), LP2Balance);
    wk.redeem(withdrawProxy1, 0);
    vm.stopPrank();

    ///////////////////
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

  function testWithdrawKitFutureLiquidationWithBlockingWithdrawReserve()
    public
  {
    TestNFT nft = new TestNFT(2);
    WithdrawKit wk = new WithdrawKit();
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
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
    _signalWithdrawAtFutureEpoch(address(1), publicVault, 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 25 ether}),
      publicVault
    );
    vm.label(address(2), "lender 2");
    uint256 LP2Balance = ERC20(publicVault).balanceOf(address(2));
    _signalWithdrawAtFutureEpoch(address(2), publicVault, 0);

    _lendToVault(
      Lender({addr: address(3), amountToLend: 50 ether}),
      publicVault
    );
    vm.label(address(3), "lender 3");
    uint256 LP3Balance = ERC20(publicVault).balanceOf(address(3));
    _signalWithdrawAtFutureEpoch(address(3), publicVault, 1);

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days;
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

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);
    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy).approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();

    vm.startPrank(address(2));
    WithdrawProxy(withdrawProxy).approve(address(wk), LP2Balance);
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();

    WithdrawProxy withdrawProxy2 = PublicVault(publicVault).getWithdrawProxy(1);
    vm.startPrank(address(3));
    WithdrawProxy(withdrawProxy2).approve(address(wk), LP3Balance);
    wk.redeem(withdrawProxy2, 0);
    vm.stopPrank();

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

    assertEq(
      WETH9.balanceOf(address(3)),
      58630139364418398750,
      "LP 3 WETH balance incorrect"
    );

    assertEq(WETH9.balanceOf(publicVault), 0, "PUBLICVAULT STILL HAS ASSETS");
    assertEq(WETH9.balanceOf(publicVault), 0, "PublicVault still has assets");
  }

  function testMultipleWithdrawsLiquidationOverbid() public {
    TestNFT nft = new TestNFT(2);
    WithdrawKit wk = new WithdrawKit();
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
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );
    vm.label(address(1), "lender 1");
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
    _signalWithdrawAtFutureEpoch(address(1), publicVault, 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 35 ether}),
      publicVault
    );
    uint256 LP2Balance = ERC20(publicVault).balanceOf(address(2));
    vm.label(address(2), "lender 2");

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days; // payee will be set to WithdrawProxy at liquidation
    lien1.maxAmount = 75 ether;
    lien1.rate = 1;
    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 75 ether,
      isFirstLien: true
    });

    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();

    _signalWithdrawAtFutureEpoch(address(2), publicVault, 1);

    _lendToVault(
      Lender({addr: address(3), amountToLend: 15 ether}),
      publicVault
    );
    uint256 LP3Balance = ERC20(publicVault).balanceOf(address(3));
    vm.label(address(3), "lender 3");

    _warpToEpochEnd(publicVault);
    uint256 collateralId = tokenContract.computeId(tokenId);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(
      stack,
      uint8(0)
    );
    _bid(Bidder(bidder, bidderPK), listedOrder, 100 ether);

    PublicVault(publicVault).transferWithdrawReserve();

    PublicVault(publicVault).processEpoch();

    _warpToEpochEnd(publicVault);
    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy).approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(address(1)),
      50000000000053364679,
      "Incorrect LP 1 WETH balance"
    );

    WithdrawProxy withdrawProxy2 = PublicVault(publicVault).getWithdrawProxy(1);
    vm.startPrank(address(2));
    WithdrawProxy(withdrawProxy2).approve(address(wk), LP2Balance);
    wk.redeem(withdrawProxy2, 0);
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(address(2)),
      35000000000100859377,
      "Incorrect LP 2 WETH balance"
    );
  }

  function testWithdrawKitInsufficientLiquidationRecovery() public {
    TestNFT nft = new TestNFT(2);
    WithdrawKit wk = new WithdrawKit();
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
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
    vm.label(address(1), "lender 1");
    _signalWithdrawAtFutureEpoch(address(1), publicVault, 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 35 ether}),
      publicVault
    );
    uint256 LP2Balance = ERC20(publicVault).balanceOf(address(2));
    vm.label(address(2), "lender 2");

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days; // payee will be set to WithdrawProxy at liquidation
    lien1.maxAmount = 75 ether;
    lien1.rate = 1;
    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 75 ether,
      isFirstLien: true
    });

    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();

    _signalWithdrawAtFutureEpoch(address(2), publicVault, 1);

    _lendToVault(
      Lender({addr: address(3), amountToLend: 15 ether}),
      publicVault
    );
    vm.label(address(3), "lender 3");

    _warpToEpochEnd(publicVault);
    uint256 collateralId = tokenContract.computeId(tokenId);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(
      stack,
      uint8(0)
    );
    _bid(Bidder(bidder, bidderPK), listedOrder, 50 ether);

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);
    WithdrawProxy withdrawProxy2 = PublicVault(publicVault).getWithdrawProxy(1);

    skip(5 days);

    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy).approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();

    vm.startPrank(address(2));
    WithdrawProxy(withdrawProxy2).approve(address(wk), LP2Balance);
    wk.redeem(withdrawProxy2, 0);
    vm.stopPrank();
    assertEq(
      WETH9.balanceOf(address(1)),
      50000000000053364679,
      "Incorrect LP 1 WETH balance"
    );

    assertEq(
      WETH9.balanceOf(address(2)),
      11775231481447897052,
      "Incorrect LP 2 WETH balance"
    );
  }

  function testWithdrawKitCompleteWithdrawalsSufficientLiquidationRecovery()
    public
  {
    TestNFT nft = new TestNFT(2);
    WithdrawKit wk = new WithdrawKit();
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
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );
    vm.label(address(1), "lender 1");
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
    _signalWithdrawAtFutureEpoch(address(1), publicVault, 0);

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days;
    lien1.maxAmount = 50 ether;
    lien1.rate = 1;
    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 50 ether,
      isFirstLien: true
    });

    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();

    _warpToEpochEnd(publicVault);
    uint256 collateralId = tokenContract.computeId(tokenId);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(
      stack,
      uint8(0)
    );
    _bid(Bidder(bidder, bidderPK), listedOrder, 100 ether);

    skip(10 days);

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy).approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(address(1)),
      50000000000060480050,
      "Incorrect LP 1 WETH balance"
    );
  }

  function testWithdrawKitCompleteWithdrawalsUnderbid() public {
    TestNFT nft = new TestNFT(2);
    WithdrawKit wk = new WithdrawKit();
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
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );
    vm.label(address(1), "lender 1");
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
    _signalWithdrawAtFutureEpoch(address(1), publicVault, 0);

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days;
    lien1.maxAmount = 50 ether;
    lien1.rate = 1;
    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 50 ether,
      isFirstLien: true
    });

    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).transferWithdrawReserve();
    PublicVault(publicVault).processEpoch();

    _warpToEpochEnd(publicVault);
    uint256 collateralId = tokenContract.computeId(tokenId);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(
      stack,
      uint8(0)
    );
    _bid(Bidder(bidder, bidderPK), listedOrder, 25 ether);

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy).approve(address(wk), LP1Balance);
    vm.expectRevert(
      abi.encodeWithSelector(
        WithdrawKit.WithdrawReserveNotZero.selector,
        1,
        29928240740801219960
      )
    );
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();
  }

  function testWithdrawKitAfterBlockingLiquidations() public {
    TestNFT nft = new TestNFT(2);
    WithdrawKit wk = new WithdrawKit();
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
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
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

    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy).approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();

    assertEq(WETH9.balanceOf(publicVault), 0, "PublicVault balance not 0");

    assertEq(
      WETH9.balanceOf(address(1)),
      51150685882784959500,
      "Incorrect LP 1 balance"
    );
  }

  function testWithdrawKitWithZeroizedVault() public {
    TestNFT nft = new TestNFT(2);
    WithdrawKit wk = new WithdrawKit();
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
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
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

    WithdrawProxy withdrawProxy1 = PublicVault(publicVault).getWithdrawProxy(0);
    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy1).approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy1, 0);
    vm.stopPrank();
    assertEq(WETH9.balanceOf(address(1)), 50 ether, "LP 1 balance incorrect");

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      publicVault
    );
    uint256 LP2Balance = ERC20(publicVault).balanceOf(address(2));

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

    WithdrawProxy withdrawProxy2 = PublicVault(publicVault).getWithdrawProxy(1);
    vm.startPrank(address(2));
    WithdrawProxy(withdrawProxy2).approve(address(wk), LP2Balance);
    wk.redeem(withdrawProxy2, 0);
    vm.stopPrank();
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
}
