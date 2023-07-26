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

    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );

    uint256 collateralId = tokenContract.computeId(tokenId);

    uint256 vaultTokenBalance = IERC20(publicVault).balanceOf(address(1));

    _signalWithdraw(address(1), publicVault);

    IWithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(
      PublicVault(publicVault).getCurrentEpoch()
    );

    assertEq(vaultTokenBalance, IERC20(withdrawProxy).balanceOf(address(1)));

    vm.warp(block.timestamp + 15 days);

    PublicVault(publicVault).processEpoch();

    vm.warp(block.timestamp + 13 days);
    PublicVault(publicVault).transferWithdrawReserve();

    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
    vm.startPrank(address(1));

    withdrawProxy.previewRedeem(vaultTokenBalance);
    withdrawProxy.approve(address(wk), vaultTokenBalance);
    wk.redeem(withdrawProxy, withdrawProxy.previewRedeem(vaultTokenBalance));
    vm.stopPrank();
    assertEq(address(1).balance, 50 ether);
  }

  function testWithdrawKitComplic() public {
    TestNFT nft = new TestNFT(3);
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

    uint256 collateralId = tokenContract.computeId(tokenId);

    uint256 vaultTokenBalance = IERC20(publicVault).balanceOf(address(1));

    _signalWithdraw(address(1), publicVault);

    IWithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(
      PublicVault(publicVault).getCurrentEpoch()
    );

    assertEq(vaultTokenBalance, IERC20(withdrawProxy).balanceOf(address(1)));

    vm.warp(block.timestamp + 15 days);

    PublicVault(publicVault).processEpoch();

    vm.warp(block.timestamp + 13 days);
    PublicVault(publicVault).transferWithdrawReserve();

    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
    vm.startPrank(address(1));

    withdrawProxy.previewRedeem(vaultTokenBalance);
    withdrawProxy.approve(address(wk), vaultTokenBalance);
    wk.redeem(withdrawProxy, withdrawProxy.previewRedeem(vaultTokenBalance));
    vm.stopPrank();
    assertEq(address(1).balance, 50 ether);
  }

  function testCompleteWithdrawAfterOneEpochWithdrawKit() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 7 days
    });
    _lendToVault(
      Lender({addr: address(1), amountToLend: 60 ether}),
      payable(publicVault)
    );

    //address payable vault, // address of deployed Vault
    //    address strategist,
    //    uint256 strategistPK,
    //    address tokenContract, // original NFT address
    //    uint256 tokenId, // original NFT id
    //    ILienToken.Details memory lienDetails, // loan information
    //    uint256 amount // requested amount
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether
    });

    vm.warp(block.timestamp + 3 days);

    _signalWithdraw(address(1), publicVault);
    _warpToEpochEnd(payable(publicVault));

    IWithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    emit log_named_string("withdrawProxy symbol", withdrawProxy.symbol());
    emit log_named_string("withdrawProxy name", withdrawProxy.name());
    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
    vm.startPrank(address(1));

    uint256 withdrawTokenBalance = withdrawProxy.balanceOf(address(1));
    withdrawProxy.approve(address(wk), withdrawTokenBalance);
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

    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 7 days
    });
    _lendToVault(
      Lender({addr: address(1), amountToLend: 60 ether}),
      payable(publicVault)
    );
    _signalWithdraw(address(1), publicVault);

    ILienToken.Details memory details = standardLienDetails;
    details.duration = 5 days;

    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details,
      amount: 10 ether
    });

    skip(6 days);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(stack);

    _warpToEpochEnd(payable(publicVault));

    skip(3 days);

    IWithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
    vm.startPrank(address(1));

    uint256 withdrawTokenBalance = withdrawProxy.balanceOf(address(1));
    withdrawProxy.approve(address(wk), withdrawTokenBalance);
    wk.redeem(withdrawProxy, withdrawProxy.previewRedeem(withdrawTokenBalance));
    vm.stopPrank();

    assertEq(
      address(1).balance,
      50 ether,
      "LP did not receive all WETH not lent out"
    );
  }

  function testDrainWithdrawKit() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 7 days
    });
    _lendToVault(
      Lender({addr: address(1), amountToLend: 60 ether}),
      payable(publicVault)
    );
    _signalWithdraw(address(1), publicVault);

    ILienToken.Details memory details = standardLienDetails;
    details.duration = 13 days;

    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details,
      amount: 10 ether
    });

    skip(13 days);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(stack);

    _bid(Bidder(bidder, bidderPK), listedOrder, 10 ether, stack);

    IWithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);
    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
    vm.startPrank(address(1));

    uint256 withdrawTokenBalance = withdrawProxy.balanceOf(address(1));

    withdrawProxy.approve(address(wk), withdrawTokenBalance);
    vm.expectRevert(
      abi.encodeWithSelector(
        WithdrawKit.WithdrawReserveNotZero.selector,
        1,
        1834246575335199147
      )
    );
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();
  }

  function testWithdrawKitAbandonedVault() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 7 days
    });
    _lendToVault(
      Lender({addr: address(1), amountToLend: 60 ether}),
      payable(publicVault)
    );
    _signalWithdraw(address(1), publicVault);

    ILienToken.Details memory details = standardLienDetails;

    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details,
      amount: 10 ether
    });

    skip(5 days);
    _repay(stack, 100 ether, address(this));

    skip(10 weeks);
    IWithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);
    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
    vm.startPrank(address(1));

    uint256 withdrawTokenBalance = withdrawProxy.balanceOf(address(1));

    withdrawProxy.approve(address(wk), withdrawTokenBalance);
    wk.redeem(withdrawProxy, withdrawProxy.previewRedeem(withdrawTokenBalance));
    vm.stopPrank();

    assertEq(
      address(1).balance,
      60205479452052000000,
      "LP did not receive all WETH not lent out"
    );
  }

  function testWithdrawKitWithEmptyLiquidation() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    // create a PublicVault with a 14-day epoch
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 30 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
    _signalWithdraw(address(1), publicVault);
    ILienToken.Details memory lien = standardLienDetails;
    lien.duration = 1 days;

    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien,
      amount: 50 ether
    });
    skip(1 days);

    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(stack);

    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));

    IWithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);
    _warpToEpochEnd(payable(publicVault));
    vm.startPrank(address(1));
    withdrawProxy.approve(address(wk), LP1Balance);
    vm.expectRevert(); // ZERO_ASSETS
    wk.redeem(withdrawProxy, LP1Balance);
    vm.stopPrank();
  }

  function testWithdrawKitEvenLiquidation() public {
    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
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

    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      payable(publicVault)
    );
    uint256 LP2Balance = ERC20(publicVault).balanceOf(address(2));

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

    _signalWithdraw(address(1), publicVault);

    IWithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(
      PublicVault(publicVault).getCurrentEpoch()
    );

    skip(14 days);

    OrderParameters memory listedOrder1 = ASTARIA_ROUTER.liquidate(stack1);
    OrderParameters memory listedOrder2 = ASTARIA_ROUTER.liquidate(stack2);

    _bid(Bidder(bidder, bidderPK), listedOrder2, 20 ether, stack2);
    vm.warp(withdrawProxy.getFinalAuctionEnd());

    vm.startPrank(address(1));
    withdrawProxy.approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy, withdrawProxy.previewRedeem(LP1Balance));
    vm.stopPrank();

    _warpToEpochEnd(payable(publicVault));
    PublicVault(publicVault).processEpoch();

    _warpToEpochEnd(payable(publicVault));
    _signalWithdraw(address(2), publicVault);
    withdrawProxy = PublicVault(publicVault).getWithdrawProxy(2);
    PublicVault(publicVault).processEpoch();

    vm.startPrank(address(2));
    withdrawProxy.approve(address(wk), LP2Balance);
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
    assertEq(address(1).balance, address(2).balance, "Unequal amounts of WETH");
  }

  function testWithdrawKitAuctionBoundaryEpochOrdering() public {
    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
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

    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));

    _signalWithdrawAtFutureEpoch(address(1), payable(publicVault), 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      payable(publicVault)
    );

    uint256 LP2Balance = ERC20(publicVault).balanceOf(address(2));

    _signalWithdrawAtFutureEpoch(address(2), payable(publicVault), 1);

    //    ILienToken.Details memory lien1 = standardLienDetails;
    //    lien1.duration = 13 days; // will set payee to WithdrawProxy
    ILienToken.Stack[] memory stacks = new ILienToken.Stack[](2);
    uint256[] memory liens = new uint256[](2);

    (liens[0], stacks[0]) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId1,
      lienDetails: standardLienDetails13Days,
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

    _warpToEpochEnd(payable(publicVault));

    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidVaultState.selector,
        IPublicVault.InvalidVaultStates.LIENS_OPEN_FOR_EPOCH_NOT_ZERO
      )
    );
    PublicVault(publicVault).processEpoch();

    OrderParameters memory listedOrder1 = ASTARIA_ROUTER.liquidate(stacks[0]);

    IWithdrawProxy withdrawProxy1 = PublicVault(publicVault).getWithdrawProxy(
      0
    );

    assertEq(
      LIEN_TOKEN.ownerOf(liens[0]),
      address(withdrawProxy1),
      "First lien not pointing to first WithdrawProxy"
    );

    _bid(Bidder(bidder, bidderPK), listedOrder1, 200 ether, stacks[0]);

    vm.warp(withdrawProxy1.getFinalAuctionEnd());
    PublicVault(publicVault).processEpoch(); // epoch 0 processing

    vm.warp(block.timestamp + 14 days);

    OrderParameters memory listedOrder2 = ASTARIA_ROUTER.liquidate(stacks[1]);

    _bid(Bidder(bidderTwo, bidderTwoPK), listedOrder2, 200 ether, stacks[1]);
    //
    vm.startPrank(address(1));
    withdrawProxy1.approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy1, 0);
    vm.stopPrank();

    withdrawProxy1 = PublicVault(publicVault).getWithdrawProxy(1);
    vm.warp(withdrawProxy1.getFinalAuctionEnd());

    vm.startPrank(address(2));
    withdrawProxy1.approve(address(wk), LP2Balance);
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
      address(1).balance,
      50636986777008079750,
      "LPs have different amounts"
    );

    assertEq(
      address(2).balance,
      51212329242753679750,
      "LPs have different amounts"
    );
  }

  function testWithdrawKitFutureLiquidationWithBlockingWithdrawReserve()
    public
  {
    TestNFT nft = new TestNFT(2);
    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
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
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
    _signalWithdrawAtFutureEpoch(address(1), payable(publicVault), 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 25 ether}),
      payable(publicVault)
    );
    vm.label(address(2), "lender 2");
    uint256 LP2Balance = ERC20(publicVault).balanceOf(address(2));
    _signalWithdrawAtFutureEpoch(address(2), publicVault, 0);

    _lendToVault(
      Lender({addr: address(3), amountToLend: 50 ether}),
      payable(publicVault)
    );
    vm.label(address(3), "lender 3");
    uint256 LP3Balance = ERC20(publicVault).balanceOf(address(3));
    _signalWithdrawAtFutureEpoch(address(3), publicVault, 1);

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days;
    lien1.maxAmount = 100 ether;
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 100 ether
    });

    assertEq(
      PublicVault(publicVault).getSlope(),
      4756468797500,
      "incorrect PublicVault slope calc"
    );

    _warpToEpochEnd(payable(publicVault));

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

    _warpToEpochEnd(payable(publicVault));

    uint256 collateralId = tokenContract.computeId(tokenId);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(stack);
    _bid(Bidder(bidder, bidderPK), listedOrder, 150 ether, stack);

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

    IWithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);
    vm.startPrank(address(1));
    withdrawProxy.approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();

    vm.startPrank(address(2));
    withdrawProxy.approve(address(wk), LP2Balance);
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();

    IWithdrawProxy withdrawProxy2 = PublicVault(publicVault).getWithdrawProxy(
      1
    );
    vm.startPrank(address(3));
    withdrawProxy2.approve(address(wk), LP3Balance);
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
      address(1).balance,
      26438357353481199375,
      "LP 1 WETH balance incorrect"
    );
    assertEq(
      address(2).balance,
      26438357353481199375,
      "LP 2 WETH balance incorrect"
    );

    assertEq(
      address(3).balance,
      58630139364418398750,
      "LP 3 WETH balance incorrect"
    );

    assertEq(WETH9.balanceOf(publicVault), 0, "PUBLICVAULT STILL HAS ASSETS");
    assertEq(WETH9.balanceOf(publicVault), 0, "PublicVault still has assets");
  }

  function testMultipleWithdrawsLiquidationOverbid() public {
    TestNFT nft = new TestNFT(2);
    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
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
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
    _signalWithdrawAtFutureEpoch(address(1), payable(publicVault), 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 35 ether}),
      payable(publicVault)
    );
    uint256 LP2Balance = ERC20(publicVault).balanceOf(address(2));
    vm.label(address(2), "lender 2");

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days; // payee will be set to WithdrawProxy at liquidation
    lien1.maxAmount = 75 ether;
    lien1.rate = 1;
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 75 ether
    });

    _warpToEpochEnd(payable(publicVault));
    PublicVault(publicVault).processEpoch();

    _signalWithdrawAtFutureEpoch(address(2), payable(publicVault), 1);

    _lendToVault(
      Lender({addr: address(3), amountToLend: 15 ether}),
      payable(publicVault)
    );
    uint256 LP3Balance = ERC20(publicVault).balanceOf(address(3));
    vm.label(address(3), "lender 3");

    _warpToEpochEnd(payable(publicVault));
    uint256 collateralId = tokenContract.computeId(tokenId);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(stack);
    _bid(Bidder(bidder, bidderPK), listedOrder, 100 ether, stack);

    PublicVault(publicVault).transferWithdrawReserve();

    PublicVault(publicVault).processEpoch();

    _warpToEpochEnd(payable(publicVault));
    IWithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    vm.startPrank(address(1));
    withdrawProxy.approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();

    assertEq(
      address(1).balance,
      50000000000053364679,
      "Incorrect LP 1 WETH balance"
    );

    IWithdrawProxy withdrawProxy2 = PublicVault(publicVault).getWithdrawProxy(
      1
    );
    vm.startPrank(address(2));
    withdrawProxy2.approve(address(wk), LP2Balance);
    wk.redeem(withdrawProxy2, 0);
    vm.stopPrank();

    assertEq(
      address(2).balance,
      35000000000100859377,
      "Incorrect LP 2 WETH balance"
    );
  }

  function testWithdrawKitInsufficientLiquidationRecovery() public {
    TestNFT nft = new TestNFT(2);
    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
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
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
    vm.label(address(1), "lender 1");
    _signalWithdrawAtFutureEpoch(address(1), payable(publicVault), 0);

    _lendToVault(
      Lender({addr: address(2), amountToLend: 35 ether}),
      payable(publicVault)
    );
    uint256 LP2Balance = ERC20(publicVault).balanceOf(address(2));
    vm.label(address(2), "lender 2");

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days; // payee will be set to WithdrawProxy at liquidation
    lien1.maxAmount = 75 ether;
    lien1.rate = 1;
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 75 ether
    });

    _warpToEpochEnd(payable(publicVault));
    PublicVault(publicVault).processEpoch();

    _signalWithdrawAtFutureEpoch(address(2), payable(publicVault), 1);

    _lendToVault(
      Lender({addr: address(3), amountToLend: 15 ether}),
      payable(publicVault)
    );
    vm.label(address(3), "lender 3");

    _warpToEpochEnd(payable(publicVault));
    uint256 collateralId = tokenContract.computeId(tokenId);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(stack);
    _bid(Bidder(bidder, bidderPK), listedOrder, 50 ether, stack);

    IWithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);
    IWithdrawProxy withdrawProxy2 = PublicVault(publicVault).getWithdrawProxy(
      1
    );

    skip(5 days);

    vm.startPrank(address(1));
    withdrawProxy.approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();

    vm.startPrank(address(2));
    withdrawProxy2.approve(address(wk), LP2Balance);
    wk.redeem(withdrawProxy2, 0);
    vm.stopPrank();
    assertEq(
      address(1).balance,
      50000000000053364679,
      "Incorrect LP 1 WETH balance"
    );

    assertEq(
      address(2).balance,
      12949999999966791714,
      "Incorrect LP 2 WETH balance"
    );
  }

  function testWithdrawKitCompleteWithdrawalsSufficientLiquidationRecovery()
    public
  {
    TestNFT nft = new TestNFT(2);
    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
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
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
    _signalWithdrawAtFutureEpoch(address(1), payable(publicVault), 0);

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days;
    lien1.maxAmount = 50 ether;
    lien1.rate = 1;
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 50 ether
    });

    _warpToEpochEnd(payable(publicVault));
    PublicVault(publicVault).processEpoch();

    _warpToEpochEnd(payable(publicVault));
    uint256 collateralId = tokenContract.computeId(tokenId);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(stack);
    _bid(Bidder(bidder, bidderPK), listedOrder, 100 ether, stack);

    skip(10 days);

    IWithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    vm.startPrank(address(1));
    withdrawProxy.approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();

    assertEq(
      address(1).balance,
      50000000000060480050,
      "Incorrect LP 1 WETH balance"
    );
  }

  function testWithdrawKitCompleteWithdrawalsUnderbid() public {
    TestNFT nft = new TestNFT(2);
    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
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
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
    _signalWithdrawAtFutureEpoch(address(1), payable(publicVault), 0);

    ILienToken.Details memory lien1 = standardLienDetails;
    lien1.duration = 28 days;
    lien1.maxAmount = 50 ether;
    lien1.rate = 1;
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien1,
      amount: 50 ether
    });

    _warpToEpochEnd(payable(publicVault));
    PublicVault(publicVault).transferWithdrawReserve();
    PublicVault(publicVault).processEpoch();

    _warpToEpochEnd(payable(publicVault));
    uint256 collateralId = tokenContract.computeId(tokenId);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(stack);
    _bid(Bidder(bidder, bidderPK), listedOrder, 25 ether, stack);

    IWithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    vm.startPrank(address(1));
    withdrawProxy.approve(address(wk), LP1Balance);
    vm.expectRevert(
      abi.encodeWithSelector(
        WithdrawKit.WithdrawReserveNotZero.selector,
        1,
        28250000000060479223
      )
    );
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();
  }

  function testWithdrawKitAfterBlockingLiquidations() public {
    TestNFT nft = new TestNFT(2);
    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
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
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
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

    _warpToEpochEnd(payable(publicVault));

    uint256 collateralId1 = tokenContract.computeId(tokenId1);
    OrderParameters memory listedOrder1 = ASTARIA_ROUTER.liquidate(stacks[0]);

    _bid(Bidder(bidder, bidderPK), listedOrder1, 10000 ether, stacks[0]);

    IWithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    vm.expectRevert(
      abi.encodeWithSelector(
        WithdrawProxy.InvalidState.selector,
        WithdrawProxy.InvalidStates.PROCESS_EPOCH_NOT_COMPLETE
      )
    );
    withdrawProxy.claim();

    uint256 collateralId2 = tokenContract.computeId(tokenId2);
    OrderParameters memory listedOrder2 = ASTARIA_ROUTER.liquidate(stacks[1]);
    _bid(Bidder(bidder, bidderPK), listedOrder2, 10000 ether, stacks[1]);

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
    withdrawProxy.approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy, 0);
    vm.stopPrank();

    assertEq(WETH9.balanceOf(publicVault), 0, "PublicVault balance not 0");

    assertEq(
      address(1).balance,
      51150685882784959500,
      "Incorrect LP 1 balance"
    );
  }

  function testWithdrawKitWithZeroizedVault() public {
    TestNFT nft = new TestNFT(2);
    WithdrawKit wk = new WithdrawKit(IWETH9(address(WETH9)));
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
    uint256 LP1Balance = ERC20(publicVault).balanceOf(address(1));
    uint256 initialVaultSupply = PublicVault(publicVault).totalSupply();
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

    _warpToEpochEnd(payable(publicVault));

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

    IWithdrawProxy withdrawProxy1 = PublicVault(publicVault).getWithdrawProxy(
      0
    );
    vm.startPrank(address(1));
    withdrawProxy1.approve(address(wk), LP1Balance);
    wk.redeem(withdrawProxy1, 0);
    vm.stopPrank();
    assertEq(address(1).balance, 50 ether, "LP 1 balance incorrect");

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      payable(publicVault)
    );
    uint256 LP2Balance = ERC20(publicVault).balanceOf(address(2));

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
      PublicVault(publicVault).getEpochEnd(
        PublicVault(publicVault).getCurrentEpoch()
      ) - 1
    );

    _repay(stacks[1], 10575342465745600000, address(this)); // TODO update to precise val
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

    _warpToEpochEnd(payable(publicVault));

    IWithdrawProxy withdrawProxy2 = PublicVault(publicVault).getWithdrawProxy(
      1
    );
    vm.startPrank(address(2));
    withdrawProxy2.approve(address(wk), LP2Balance);
    wk.redeem(withdrawProxy2, 0);
    vm.stopPrank();
    assertEq(
      address(2).balance,
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
