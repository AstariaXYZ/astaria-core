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
import "../WithdrawKit.sol";

contract WithdrawKitTesting is TestHelpers {
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
    wk.redeem(withdrawProxy, withdrawProxy.previewRedeem(withdrawTokenBalance));
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(address(1)),
      50 ether,
      "LP did not receive all WETH not lent out"
    );
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
    wk.redeem(withdrawProxy, withdrawProxy.previewRedeem(withdrawTokenBalance));
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(address(1)),
        57021759259259260116,
      "LP did not recover correct WETH amount"
    );

    assertEq(WETH9.balanceOf(publicVault), 0, "PublicVault incorrectly still has funds");
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
      60 ether,
      "LP did not receive all WETH not lent out"
    );
  }
}
