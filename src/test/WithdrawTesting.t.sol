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
import {IPublicVault} from "core/interfaces/IPublicVault.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {VaultImplementation} from "../VaultImplementation.sol";
import {PublicVault} from "../PublicVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";
import {OrderParameters} from "seaport-types/src/lib/ConsiderationStructs.sol";

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
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 30 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );

    _signalWithdraw(address(1), payable(publicVault));

    ILienToken.Details memory lien = standardLienDetails;
    lien.duration = 1 days;

    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien,
      amount: 50 ether
    });

    uint256 collateralId = tokenContract.computeId(tokenId);

    vm.warp(block.timestamp + lien.duration);

    OrderParameters memory listedOrder = _liquidate(stack);

    vm.warp(block.timestamp + 2 days); // end of auction

    _warpToEpochEnd(publicVault);
    PublicVault(payable(publicVault)).processEpoch();
    PublicVault(payable(publicVault)).transferWithdrawReserve();

    IWithdrawProxy withdrawProxy = PublicVault(payable(publicVault))
      .getWithdrawProxy(0);

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
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      payable(publicVault)
    );

    assertEq(
      ERC20(publicVault).balanceOf(address(1)),
      ERC20(publicVault).balanceOf(address(2)),
      "minted supply to LPs not equal"
    );

    (, ILienToken.Stack memory stack1) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether
    });

    (, ILienToken.Stack memory stack2) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: uint256(5),
      lienDetails: standardLienDetails,
      amount: 10 ether
    });

    uint256 collateralId = tokenContract.computeId(tokenId);
    uint256 collateralId2 = tokenContract.computeId(uint256(5));

    _signalWithdraw(address(1), payable(publicVault));

    IWithdrawProxy withdrawProxy = PublicVault(payable(publicVault))
      .getWithdrawProxy(PublicVault(payable(publicVault)).getCurrentEpoch());

    skip(14 days);

    OrderParameters memory listedOrder1 = _liquidate(stack1);
    OrderParameters memory listedOrder2 = _liquidate(stack2);

    //TODO: figure out how to do multiple bids here properly

    _bid(Bidder(bidder, bidderPK), listedOrder2, 20 ether, stack2);
    vm.warp(withdrawProxy.getFinalAuctionEnd());
    PublicVault(payable(publicVault)).processEpoch();

    skip(13 days);

    withdrawProxy.claim();

    PublicVault(payable(publicVault)).transferWithdrawReserve();

    vm.startPrank(address(1));
    withdrawProxy.redeem(
      withdrawProxy.balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.stopPrank();

    _signalWithdraw(address(2), payable(publicVault));
    withdrawProxy = PublicVault(payable(publicVault)).getWithdrawProxy(
      PublicVault(payable(publicVault)).getCurrentEpoch()
    );

    uint256 finalAuctionEnd = withdrawProxy.getFinalAuctionEnd();

    PublicVault(payable(publicVault)).processEpoch();
    PublicVault(payable(publicVault)).transferWithdrawReserve();
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
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );

    _signalWithdrawAtFutureEpoch(address(1), payable(publicVault), 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      payable(publicVault)
    );

    _signalWithdrawAtFutureEpoch(address(2), payable(publicVault), 1);

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 13 days; // will set payee to WithdrawProxy
    uint256[] memory liens = new uint256[](2);

    ILienToken.Stack[] memory stacks = new ILienToken.Stack[](2); // hold multiple loans
    (liens[0], stacks[0]) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId1,
      lienDetails: lien1,
      amount: 10 ether
    });

    ILienToken.Details memory lien2 = standardLienDetails;
    lien2.duration = 27 days; // payee will be sent to WithdrawProxy at liquidation
    (liens[1], stacks[1]) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId2,
      lienDetails: lien2,
      amount: 10 ether
    });

    _warpToEpochEnd(publicVault);

    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidVaultState.selector,
        IPublicVault.InvalidVaultStates.LIENS_OPEN_FOR_EPOCH_NOT_ZERO
      )
    );
    PublicVault(payable(publicVault)).processEpoch();

    //maybe even just manually asser this test as it is the outlier
    OrderParameters memory listedOrder1 = ASTARIA_ROUTER.liquidate(stacks[0]);

    IWithdrawProxy withdrawProxy1 = PublicVault(payable(publicVault))
      .getWithdrawProxy(0);

    assertEq(
      LIEN_TOKEN.ownerOf(liens[0]),
      address(withdrawProxy1),
      "First lien not pointing to first WithdrawProxy"
    );

    _bid(Bidder(bidder, bidderPK), listedOrder1, 200 ether, stacks[0]);

    vm.warp(withdrawProxy1.getFinalAuctionEnd());
    PublicVault(payable(publicVault)).processEpoch(); // epoch 0 processing

    vm.warp(block.timestamp + 14 days);

    // TODO: helper method with asserts for  a liquidate when a claim is going to happen
    //maybe even just manually asser this test as it is the outlier
    OrderParameters memory listedOrder2 = ASTARIA_ROUTER.liquidate(stacks[1]);

    IWithdrawProxy withdrawProxy2 = PublicVault(payable(publicVault))
      .getWithdrawProxy(1);

    assertEq(
      LIEN_TOKEN.ownerOf(liens[1]),
      address(withdrawProxy2),
      "Second lien not pointing to second WithdrawProxy"
    );

    _bid(Bidder(bidderTwo, bidderTwoPK), listedOrder2, 200 ether, stacks[1]);

    PublicVault(payable(publicVault)).transferWithdrawReserve();

    withdrawProxy1.claim();

    withdrawProxy1.redeem(
      withdrawProxy1.balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.warp(withdrawProxy2.getFinalAuctionEnd());
    PublicVault(payable(publicVault)).processEpoch();

    PublicVault(payable(publicVault)).transferWithdrawReserve();

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
      WETH9.balanceOf(
        address(PublicVault(payable(publicVault)).getWithdrawProxy(0))
      ),
      0,
      "WithdrawProxy 0 should have 0 assets"
    );
    assertEq(
      WETH9.balanceOf(
        address(PublicVault(payable(publicVault)).getWithdrawProxy(1))
      ),
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
    LIQUIDATION_ACCOUNTANT_ALREADY_DEPLOYED_FOR_EPOCH
  }
  error InvalidState(InvalidStates);

  function testFutureLiquidationWithBlockingWithdrawReserve() public {
    TestNFT nft = new TestNFT(2);
    _mintNoDepositApproveRouter(address(nft), 5);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    vm.label(publicVault, "publicVault");

    _lendToVault(
      Lender({addr: address(1), amountToLend: 25 ether}),
      payable(publicVault)
    );
    vm.label(address(1), "lender 1");
    _signalWithdrawAtFutureEpoch(address(1), payable(publicVault), 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 25 ether}),
      payable(publicVault)
    );
    vm.label(address(2), "lender 2");
    _signalWithdrawAtFutureEpoch(address(2), payable(publicVault), 0);

    _lendToVault(
      Lender({addr: address(3), amountToLend: 50 ether}),
      payable(publicVault)
    );
    vm.label(address(3), "lender 3");
    _signalWithdrawAtFutureEpoch(address(3), payable(publicVault), 1);

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days; // payee will be set to WithdrawProxy at liquidation
    lien1.maxAmount = 100 ether;
    (uint256 liens, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 100 ether
    });

    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      4756468797500,
      "incorrect PublicVault slope calc"
    );

    _warpToEpochEnd(publicVault);

    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      4756468797500,
      "incorrect PublicVault slope calc"
    );

    PublicVault(payable(publicVault)).processEpoch();

    assertEq(
      PublicVault(payable(publicVault)).getWithdrawReserve(),
      52876714706962398750,
      "Epoch 0 withdrawReserve calculation incorrect"
    );

    _warpToEpochEnd(publicVault);

    uint256 collateralId = tokenContract.computeId(tokenId);
    OrderParameters memory listedOrder = _liquidate(stack);
    _bid(Bidder(bidder, bidderPK), listedOrder, 150 ether, stack);

    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope should be 0"
    );
    assertEq(
      PublicVault(payable(publicVault)).getYIntercept(),
      58630139364418398750,
      "PublicVault yIntercept calculation incorrect"
    );

    vm.warp(block.timestamp + 3 days);

    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidVaultState.selector,
        IPublicVault.InvalidVaultStates.WITHDRAW_RESERVE_NOT_ZERO
      )
    );
    PublicVault(payable(publicVault)).processEpoch();

    PublicVault(payable(publicVault)).transferWithdrawReserve();
    PublicVault(payable(publicVault)).processEpoch();

    PublicVault(payable(publicVault)).transferWithdrawReserve();

    assertEq(
      PublicVault(payable(publicVault)).getWithdrawReserve(),
      0,
      "withdrawReserve should be 0 after transfer"
    );

    assertEq(
      PublicVault(payable(publicVault)).getYIntercept(),
      0,
      "PublicVault yIntercept calculation incorrect"
    );

    IWithdrawProxy withdrawProxy = PublicVault(payable(publicVault))
      .getWithdrawProxy(0);

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
    IWithdrawProxy(withdrawProxy).redeem(
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
    IWithdrawProxy withdrawProxy2 = PublicVault(payable(publicVault))
      .getWithdrawProxy(1);

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

  function testMultipleWithdrawsLiquidationOverbid() public {
    TestNFT nft = new TestNFT(2);
    _mintNoDepositApproveRouter(address(nft), 5);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    vm.label(publicVault, "publicVault");

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );
    vm.label(address(1), "lender 1");
    _signalWithdrawAtFutureEpoch(address(1), payable(publicVault), 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 35 ether}),
      payable(publicVault)
    );
    vm.label(address(2), "lender 2");

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days; // payee will be set to WithdrawProxy at liquidation
    lien1.maxAmount = 75 ether;
    lien1.rate = 1;
    (uint256 liens, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 75 ether
    });

    _warpToEpochEnd(publicVault);
    PublicVault(payable(publicVault)).processEpoch();

    _signalWithdrawAtFutureEpoch(address(2), payable(publicVault), 1);

    _lendToVault(
      Lender({addr: address(3), amountToLend: 15 ether}),
      payable(publicVault)
    );
    vm.label(address(3), "lender 3");

    _warpToEpochEnd(publicVault);
    uint256 collateralId = tokenContract.computeId(tokenId);
    OrderParameters memory listedOrder = _liquidate(stack);
    _bid(Bidder(bidder, bidderPK), listedOrder, 100 ether, stack);

    PublicVault(payable(publicVault)).transferWithdrawReserve();

    PublicVault(payable(publicVault)).processEpoch();

    _warpToEpochEnd(publicVault);
    address withdrawProxy = address(
      PublicVault(payable(publicVault)).getWithdrawProxy(0)
    );

    vm.startPrank(address(1));
    IWithdrawProxy(withdrawProxy).redeem(
      IERC20(withdrawProxy).balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.stopPrank();
    assertEq(
      WETH9.balanceOf(address(1)),
      50000000000053364679,
      "Incorrect LP 1 WETH balance"
    );

    address withdrawProxy2 = address(
      PublicVault(payable(publicVault)).getWithdrawProxy(1)
    );
    WithdrawProxy(withdrawProxy2).claim();

    vm.startPrank(address(2));
    WithdrawProxy(withdrawProxy2).redeem(
      IERC20(withdrawProxy2).balanceOf(address(2)),
      address(2),
      address(2)
    );
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(address(2)),
      35000000000100859377,
      "Incorrect LP 2 WETH balance"
    );
  }

  function testMultipleWithdrawsLiquidationUnderbid() public {
    TestNFT nft = new TestNFT(2);
    _mintNoDepositApproveRouter(address(nft), 5);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    vm.label(publicVault, "publicVault");

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );
    vm.label(address(1), "lender 1");
    _signalWithdrawAtFutureEpoch(address(1), payable(publicVault), 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 35 ether}),
      payable(publicVault)
    );
    vm.label(address(2), "lender 2");

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days; // payee will be set to WithdrawProxy at liquidation
    lien1.maxAmount = 75 ether;
    lien1.rate = 1;
    (uint256 liens, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 75 ether
    });

    _warpToEpochEnd(publicVault);
    uint256 amountOwedAtEpoch0 = LIEN_TOKEN.getOwed(stack);
    PublicVault(payable(publicVault)).processEpoch();

    _signalWithdrawAtFutureEpoch(address(2), payable(publicVault), 1);

    // uint256 collateralId = tokenContract.computeId(tokenId);
    {
      assertEq(
        WETH9.balanceOf(publicVault),
        10 ether,
        "PublicVault WETH9 balance incorrect"
      );
    }

    PublicVault(payable(publicVault)).transferWithdrawReserve();

    IWithdrawProxy withdrawProxy0 = PublicVault(payable(publicVault))
      .getWithdrawProxy(0);
    {
      (
        uint256 withdrawRatio,
        uint256 expected,
        uint40 finalAuctionEnd,
        uint256 withdrawReserveReceived
      ) = withdrawProxy0.getState();

      assertEq(
        withdrawRatio,
        uint256(50 ether).mulDivDown(1e18, uint256(85 ether)),
        "withdrawRatio incorrect"
      );

      assertEq(expected, 0, "Expected value incorrect");

      assertEq(finalAuctionEnd, 0, "finalAuctionEnd not as expected");

      assertEq(
        withdrawReserveReceived,
        10 ether,
        "withdrawReserveReceived incorrect"
      );
    }

    assertEq(
      WETH9.balanceOf(address(withdrawProxy0)),
      10 ether,
      "WithdrawProxy[0] WETH9 balance incorrect"
    );

    _lendToVault(
      Lender({addr: address(3), amountToLend: 15 ether}),
      payable(publicVault)
    );
    vm.label(address(3), "lender 3");

    _warpToEpochEnd(publicVault);

    uint256 expectedFinalAuctionEnd = block.timestamp + 3 days;
    OrderParameters memory listedOrder = _liquidate(stack);
    uint256 executionPrice = _bid(
      Bidder(bidder, bidderPK),
      listedOrder,
      50 ether,
      stack
    );
    uint256 liquidatorFee = ASTARIA_ROUTER.getLiquidatorFee(executionPrice);
    // uint256 decreaseInYintercept = amountOwed - (executionPrice - liquidatorFee);
    IWithdrawProxy withdrawProxy1 = PublicVault(payable(publicVault))
      .getWithdrawProxy(1);

    assertEq(
      WETH9.balanceOf(address(withdrawProxy1)),
      executionPrice - liquidatorFee,
      "WithdrawProxy[1] has incorrect WETH balance"
    );

    {
      (
        uint256 withdrawRatio,
        uint256 expected,
        uint40 finalAuctionEnd,
        uint256 withdrawReserveReceived
      ) = withdrawProxy0.getState();

      assertEq(
        withdrawRatio,
        uint256(50 ether).mulDivDown(1e18, uint256(85 ether)),
        "withdrawRatio incorrect"
      );

      assertEq(expected, 0, "Expected value incorrect");

      assertEq(finalAuctionEnd, 0, "finalAuctionEnd not as expected");

      // uint256 withdrawRatioEpoch0 = uint256(50 ether).mulDivDown(1e18, uint256(85 ether));
      assertEq(
        withdrawReserveReceived,
        10 ether,
        "withdrawReserveReceived incorrect"
      );
    }

    // calls drain from WithdrawProxy[1]
    PublicVault(payable(publicVault)).transferWithdrawReserve();

    {
      (
        uint256 withdrawRatio,
        ,
        ,
        uint256 withdrawReserveReceived
      ) = withdrawProxy0.getState();

      assertEq(
        withdrawReserveReceived,
        uint256(amountOwedAtEpoch0 + 10 ether).mulDivDown(withdrawRatio, 1e18),
        "withdrawReserveReceived incorrect"
      );

      assertEq(
        WETH9.balanceOf(address(withdrawProxy0)),
        uint256(amountOwedAtEpoch0 + 10 ether).mulDivDown(withdrawRatio, 1e18),
        "WETH9 balance of WithdrawProxy[0] divergent"
      );
    }

    assertEq(
      PublicVault(payable(publicVault)).getYIntercept(),
      50000000000128075395,
      "PublicVault yIntercept divergent"
    );

    vm.expectRevert(
      abi.encodeWithSelector(
        WithdrawProxy.InvalidState.selector,
        WithdrawProxy.InvalidStates.PROCESS_EPOCH_NOT_COMPLETE
      )
    );
    withdrawProxy1.claim();

    PublicVault(payable(publicVault)).processEpoch();

    {
      (
        uint256 withdrawRatio,
        uint256 expected,
        uint40 finalAuctionEnd,
        uint256 withdrawReserveReceived
      ) = withdrawProxy1.getState();

      assertEq(withdrawRatio, 700000000000224132, "withdrawRatio incorrect");

      assertEq(expected, 50000000000128075396, "Expected value incorrect");

      assertEq(
        finalAuctionEnd,
        expectedFinalAuctionEnd,
        "finalAuctionEnd not as expected"
      );

      assertEq(withdrawReserveReceived, 0, "withdrawReserveReceived incorrect");

      assertEq(
        WETH9.balanceOf(address(withdrawProxy1)),
        (executionPrice - liquidatorFee + 25 ether) -
          uint256(amountOwedAtEpoch0 + 10 ether).mulDivDown(
            uint256(50 ether).mulDivDown(1e18, uint256(85 ether)),
            1e18
          ),
        "WithdrawProxy[1] has incorrect WETH balance"
      );
    }

    assertEq(
      PublicVault(payable(publicVault)).getYIntercept(),
      15000000000027216018,
      "PublicVault yIntercept divergent"
    );

    vm.warp(expectedFinalAuctionEnd);
    withdrawProxy1.claim();

    assertEq(
      // adding 1 due to division rounding
      PublicVault(payable(publicVault)).getYIntercept() + 1,
      WETH9.balanceOf(publicVault),
      "PublicVault yIntercept divergent"
    );

    vm.startPrank(address(2));
    withdrawProxy1.redeem(
      withdrawProxy1.balanceOf(address(2)),
      address(2),
      address(2)
    );
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(address(2)),
      12949999999966791714,
      "WETH balance for lender2 incorrect"
    );

    vm.startPrank(address(1));
    withdrawProxy0.redeem(
      withdrawProxy0.balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(address(1)),
      50000000000053364679,
      "WETH balance for lender1 incorrect"
    );

    assertEq(
      PublicVault(payable(publicVault)).totalSupply(),
      PublicVault(payable(publicVault)).balanceOf(address(3)),
      "Lender3 balance not the same as the totalSupply"
    );
  }

  function testFullWithdrawsOverbid() public {
    TestNFT nft = new TestNFT(2);
    _mintNoDepositApproveRouter(address(nft), 5);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    vm.label(publicVault, "publicVault");

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );
    vm.label(address(1), "lender 1");
    _signalWithdrawAtFutureEpoch(address(1), payable(publicVault), 0);

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days; // payee will be set to WithdrawProxy at liquidation
    lien1.maxAmount = 50 ether;
    lien1.rate = 1;
    (uint256 liens, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 50 ether
    });

    _warpToEpochEnd(publicVault);
    PublicVault(payable(publicVault)).processEpoch();

    _warpToEpochEnd(publicVault);
    uint256 collateralId = tokenContract.computeId(tokenId);
    OrderParameters memory listedOrder = _liquidate(stack);
    _bid(Bidder(bidder, bidderPK), listedOrder, 100 ether, stack);

    PublicVault(payable(publicVault)).transferWithdrawReserve();

    PublicVault(payable(publicVault)).processEpoch();

    _warpToEpochEnd(publicVault);
    address withdrawProxy = address(
      PublicVault(payable(publicVault)).getWithdrawProxy(0)
    );

    vm.startPrank(address(1));
    IWithdrawProxy(withdrawProxy).redeem(
      IERC20(withdrawProxy).balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(address(1)),
      50000000000060480050,
      "Incorrect LP 1 WETH balance"
    );
  }

  function testFullWithdrawsUnderbid() public {
    TestNFT nft = new TestNFT(2);
    _mintNoDepositApproveRouter(address(nft), 5);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    vm.label(publicVault, "publicVault");

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );
    vm.label(address(1), "lender 1");
    _signalWithdrawAtFutureEpoch(address(1), payable(publicVault), 0);

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days; // payee will be set to WithdrawProxy at liquidation
    lien1.maxAmount = 50 ether;
    lien1.rate = 1;
    (uint256 liens, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 50 ether
    });

    _warpToEpochEnd(publicVault);
    PublicVault(payable(publicVault)).processEpoch();

    _warpToEpochEnd(publicVault);
    uint256 amountOwed = LIEN_TOKEN.getOwed(stack);

    uint256 expectedFinalAuctionEnd = block.timestamp + 3 days;
    uint256 collateralId = tokenContract.computeId(tokenId);
    OrderParameters memory listedOrder = _liquidate(stack);
    uint256 executionPrice = _bid(
      Bidder(bidder, bidderPK),
      listedOrder,
      25 ether,
      stack
    );

    IWithdrawProxy withdrawProxy1 = PublicVault(payable(publicVault))
      .getWithdrawProxy(1);

    {
      (
        uint256 withdrawRatio,
        uint256 expected,
        uint40 finalAuctionEnd,
        uint256 withdrawReserveReceived
      ) = withdrawProxy1.getState();

      assertEq(withdrawRatio, 0, "withdrawRatio incorrect");

      assertEq(expected, amountOwed, "Expected value incorrect");

      assertEq(
        finalAuctionEnd,
        expectedFinalAuctionEnd,
        "finalAuctionEnd not as expected"
      );

      assertEq(withdrawReserveReceived, 0, "withdrawReserveReceived incorrect");
    }

    assertEq(
      WETH9.balanceOf(address(withdrawProxy1)),
      executionPrice - ASTARIA_ROUTER.getLiquidatorFee(executionPrice),
      "WithdrawProxy[1] balance incorrect"
    );

    PublicVault(payable(publicVault)).transferWithdrawReserve();

    IWithdrawProxy withdrawProxy0 = PublicVault(payable(publicVault))
      .getWithdrawProxy(0);
    {
      (
        uint256 withdrawRatio,
        uint256 expected,
        uint40 finalAuctionEnd,
        uint256 withdrawReserveReceived
      ) = withdrawProxy0.getState();

      assertEq(withdrawRatio, 1e18, "withdrawRatio incorrect");

      assertEq(expected, 0, "Expected value incorrect");

      assertEq(finalAuctionEnd, 0, "finalAuctionEnd not as expected");

      assertEq(
        withdrawReserveReceived,
        executionPrice - ASTARIA_ROUTER.getLiquidatorFee(executionPrice),
        "withdrawReserveReceived incorrect"
      );
    }
    assertEq(
      WETH9.balanceOf(address(withdrawProxy0)),
      executionPrice - ASTARIA_ROUTER.getLiquidatorFee(executionPrice),
      "WithdrawProxy[0] balance incorrect"
    );

    address withdrawProxy = address(
      PublicVault(payable(publicVault)).getWithdrawProxy(0)
    );

    vm.startPrank(address(1));
    IWithdrawProxy(withdrawProxy).redeem(
      IERC20(withdrawProxy).balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.stopPrank();
    assertEq(
      WETH9.balanceOf(address(1)),
      executionPrice - ASTARIA_ROUTER.getLiquidatorFee(executionPrice),
      "Incorrect LP 1 WETH balance"
    );

    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidVaultState.selector,
        IPublicVault.InvalidVaultStates.WITHDRAW_RESERVE_NOT_ZERO
      )
    );
    PublicVault(payable(publicVault)).processEpoch();

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      payable(publicVault)
    );
    PublicVault(payable(publicVault)).transferWithdrawReserve();
    PublicVault(payable(publicVault)).processEpoch();
  }

  function testBlockingLiquidationsProcessEpoch() public {
    TestNFT nft = new TestNFT(2);
    _mintNoDepositApproveRouter(address(nft), 5);
    _mintNoDepositApproveRouter(address(nft), 2);
    address tokenContract = address(nft);
    uint256 tokenId1 = uint256(1);
    uint256 tokenId2 = uint256(2);
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );
    _signalWithdrawAtFutureEpoch(address(1), payable(publicVault), 0);
    uint256[] memory liens = new uint256[](2);
    ILienToken.Stack[] memory stacks = new ILienToken.Stack[](2);

    (liens[0], stacks[0]) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId1,
      lienDetails: standardLienDetails,
      amount: 10 ether
    });

    (liens[1], stacks[1]) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId2,
      lienDetails: standardLienDetails,
      amount: 10 ether
    });

    _warpToEpochEnd(publicVault);

    uint256 collateralId1 = tokenContract.computeId(tokenId1);
    OrderParameters memory listedOrder1 = _liquidate(stacks[0]);

    _bid(Bidder(bidder, bidderPK), listedOrder1, 10000 ether, stacks[0]);

    IWithdrawProxy withdrawProxy = PublicVault(payable(publicVault))
      .getWithdrawProxy(0);

    vm.expectRevert(
      abi.encodeWithSelector(
        WithdrawProxy.InvalidState.selector,
        WithdrawProxy.InvalidStates.PROCESS_EPOCH_NOT_COMPLETE
      )
    );
    withdrawProxy.claim();

    uint256 collateralId2 = tokenContract.computeId(tokenId2);
    OrderParameters memory listedOrder2 = _liquidate(stacks[1]);
    _bid(Bidder(bidder, bidderPK), listedOrder2, 10000 ether, stacks[1]);

    vm.expectRevert(
      abi.encodeWithSelector(
        WithdrawProxy.InvalidState.selector,
        WithdrawProxy.InvalidStates.PROCESS_EPOCH_NOT_COMPLETE
      )
    );
    withdrawProxy.claim();

    skip(withdrawProxy.getFinalAuctionEnd());
    PublicVault(payable(publicVault)).processEpoch();

    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope after epoch 0 should be 0"
    );
    assertEq(
      PublicVault(payable(publicVault)).getWithdrawReserve(),
      30 ether,
      "Incorrect PublicVault withdrawReserve calculation after epoch 0"
    );
    assertEq(
      PublicVault(payable(publicVault)).getLiquidationWithdrawRatio(),
      1e18,
      "Incorrect PublicVault withdrawRatio calculation after epoch 0"
    );

    withdrawProxy.claim();
    PublicVault(payable(publicVault)).transferWithdrawReserve();

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
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );
    uint256 initialVaultSupply = PublicVault(payable(publicVault))
      .totalSupply();
    _signalWithdrawAtFutureEpoch(address(1), payable(publicVault), 0);
    uint256[] memory liens = new uint256[](2);
    ILienToken.Stack[] memory stacks = new ILienToken.Stack[](2);
    (liens[0], stacks[0]) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId1,
      lienDetails: standardLienDetails,
      amount: 10 ether
    });

    _repay(stacks[0], 10 ether, address(this));

    _warpToEpochEnd(publicVault);

    PublicVault(payable(publicVault)).processEpoch();

    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope should be 0 after epoch 0"
    );
    assertEq(
      PublicVault(payable(publicVault)).totalSupply(),
      0,
      "VaultToken balance should have been burned after epoch 0"
    );
    assertEq(
      PublicVault(payable(publicVault)).getWithdrawReserve(),
      50 ether,
      "PublicVault withdrawReserve calculation after epoch 0 incorrect"
    );
    assertEq(
      PublicVault(payable(publicVault)).getYIntercept(),
      0,
      "PublicVault yIntercept after epoch 0 should be 0"
    );

    PublicVault(payable(publicVault)).transferWithdrawReserve();
    IWithdrawProxy withdrawProxy1 = PublicVault(payable(publicVault))
      .getWithdrawProxy(0);

    withdrawProxy1.redeem(
      withdrawProxy1.balanceOf(address(1)),
      address(1),
      address(1)
    );
    assertEq(WETH9.balanceOf(address(1)), 50 ether, "LP 1 balance incorrect");

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      payable(publicVault)
    );

    _signalWithdrawAtFutureEpoch(address(2), payable(publicVault), 1);

    ILienToken.Details memory lien2 = standardLienDetails;
    lien2.duration = 14 days; // payee will be set to WithdrawProxy at liquidation

    (liens[1], stacks[1]) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId2,
      lienDetails: lien2,
      amount: 10 ether
    });

    vm.warp(
      PublicVault(payable(publicVault)).getEpochEnd(
        PublicVault(payable(publicVault)).getCurrentEpoch()
      ) - 1
    );

    _repay(stacks[1], 10575342465745600000, address(this)); // TODO update to precise val
    assertEq(
      initialVaultSupply,
      PublicVault(payable(publicVault)).totalSupply(),
      "VaultToken supplies unequal"
    );
    assertEq(
      PublicVault(payable(publicVault)).getYIntercept(),
      50575341514451840500,
      "incorrect PublicVault yIntercept calculation after lien 2 repayment"
    );
    assertEq(
      PublicVault(payable(publicVault)).totalAssets(),
      50575341514451840500,
      "incorrect PublicVault totalAssets() after lien 2 repayment"
    );
    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope should be 0 after second lien repayment"
    );
    assertEq(
      PublicVault(payable(publicVault)).getLiquidationWithdrawRatio(),
      1e18,
      "PublicVault liquidationWithdrawRatio should be 0"
    );

    _warpToEpochEnd(publicVault);
    PublicVault(payable(publicVault)).processEpoch();

    assertEq(
      PublicVault(payable(publicVault)).getWithdrawReserve(),
      50575341514451840500,
      "Incorrect PublicVault withdrawReserve calculation after epoch 1"
    );
    PublicVault(payable(publicVault)).transferWithdrawReserve();
    IWithdrawProxy withdrawProxy2 = PublicVault(payable(publicVault))
      .getWithdrawProxy(1);

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
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );

    ILienToken.Details memory details = standardLienDetails;
    details.duration = 13 days;

    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details,
      amount: 10 ether
    });

    vm.warp(block.timestamp + 13 days);
    uint256 collateralId = tokenContract.computeId(tokenId);
    assertEq(
      LIEN_TOKEN.getOwed(stack),
      uint192(10534246575335200000),
      "Incorrect lien interest"
    );

    OrderParameters memory listedOrder = _liquidate(stack);

    uint256 executionPrice = _bid(
      Bidder(bidder, bidderPK),
      listedOrder,
      6.96 ether,
      stack
    );
    IWithdrawProxy withdrawProxy = PublicVault(payable(publicVault))
      .getWithdrawProxy(0);

    vm.warp(withdrawProxy.getFinalAuctionEnd());
    PublicVault(payable(publicVault)).processEpoch();

    vm.warp(block.timestamp + 4 days);

    withdrawProxy.claim();

    assertEq(
      WETH9.balanceOf(publicVault),
      40 ether +
        executionPrice -
        ASTARIA_ROUTER.getLiquidatorFee(executionPrice),
      "Incorrect PublicVault balance"
    );
    assertEq(
      PublicVault(payable(publicVault)).getYIntercept(),
      40 ether +
        executionPrice -
        ASTARIA_ROUTER.getLiquidatorFee(executionPrice),
      "Incorrect PublicVault YIntercept"
    );
    assertEq(
      PublicVault(payable(publicVault)).totalAssets(),
      40 ether +
        executionPrice -
        ASTARIA_ROUTER.getLiquidatorFee(executionPrice),
      "Incorrect PublicVault totalAssets()"
    );
    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "Incorrect PublicVault slope"
    );
  }
}
