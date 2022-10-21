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

    IAstariaRouter.LienDetails memory lien = standardLien;
    lien.duration = 1 days;

    // borrow 10 eth against the dummy NFT
    _commitToLien({
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

    ASTARIA_ROUTER.liquidate(collateralId, 0);

    // _bid(address(2), collateralId, 1 ether);

    vm.warp(block.timestamp + 2 days); // end of auction

    AUCTION_HOUSE.endAuction(0);

    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();
    PublicVault(publicVault).transferWithdrawReserve();

    address withdrawProxy = PublicVault(publicVault).withdrawProxies(0);

    assertEq(
      WithdrawProxy(withdrawProxy).previewRedeem(
        ERC20(withdrawProxy).balanceOf(address(1))
      ),
      0
    );
  }

  event Num(uint256);
  function testLiquidationAccountant5050Split() public {
    Dummy721 nft = new Dummy721();
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

    uint256 initialSupply = PublicVault(publicVault).totalSupply();

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      publicVault
    );

    assertEq(initialSupply * 2, PublicVault(publicVault).totalSupply(), "1");

    assertEq(ERC20(publicVault).balanceOf(address(1)), ERC20(publicVault).balanceOf(address(2)), "minted supply to LPs not equal");
    

    _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLien,
      amount: 10 ether,
      isFirstLien: true
    });

    

    uint256 collateralId = tokenContract.computeId(tokenId);

    _signalWithdraw(address(1), publicVault);

    

    address withdrawProxy = PublicVault(publicVault).withdrawProxies(
      PublicVault(publicVault).getCurrentEpoch()
    );

    assertEq(ERC20(withdrawProxy).balanceOf(address(1)), ERC20(publicVault).balanceOf(address(2)), "minted supply to LPs not equal");

    vm.warp(block.timestamp + 10 days);
    ASTARIA_ROUTER.liquidate(collateralId, uint256(0));
    _bid(address(3), collateralId, 20 ether);
    vm.warp(block.timestamp + 4 days); // end of loan

    

    

    address liquidationAccountant = PublicVault(publicVault)
      .liquidationAccountants(0);

    // assertTrue(
    //   liquidationAccountant != address(0),
    //   "LiquidationAccountant not deployed"
    // );

    

    

    _warpToEpochEnd(publicVault); // epoch boundary

    assertEq(ERC20(withdrawProxy).balanceOf(address(1)), ERC20(publicVault).balanceOf(address(2)), "minted supply to LPs not equal");

    assertEq(PublicVault(publicVault).totalSupply(), ERC20(publicVault).balanceOf(publicVault) + ERC20(publicVault).balanceOf(address(2)), "2");
    PublicVault(publicVault).processEpoch();


    vm.warp(block.timestamp + 13 days);
    assertTrue(
      liquidationAccountant != address(0),
      "LiquidationAccountant not deployed"
    );
    PublicVault(publicVault).transferWithdrawReserve();
    emit Num(WETH9.balanceOf(publicVault));
    // LiquidationAccountant(liquidationAccountant).claim();

    

    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy).redeem(
      IERC20(withdrawProxy).balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.stopPrank();
    emit Num(WETH9.balanceOf(publicVault));

    // assertEq(WETH9.balanceOf(address(1)), 50410958904104000000);

    _signalWithdraw(address(2), publicVault);
    withdrawProxy = PublicVault(publicVault).withdrawProxies(
      PublicVault(publicVault).getCurrentEpoch()
    );

    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();
    emit Num(PublicVault(publicVault).withdrawReserve());
    emit Num(WETH9.balanceOf(publicVault));
    PublicVault(publicVault).transferWithdrawReserve();
    vm.startPrank(address(2));
    WithdrawProxy(withdrawProxy).redeem(IERC20(withdrawProxy).balanceOf(address(2)), address(2), address(2));
    vm.stopPrank();

    assertEq(WETH9.balanceOf(publicVault), 0, "booo publicvault should be 0");
    assertEq(WETH9.balanceOf(PublicVault(publicVault).liquidationAccountants(0)), 0, "booo liquidationAccountant should be 0");
    assertEq(WETH9.balanceOf(address(1)), WETH9.balanceOf(address(2)), "Unequal amounts of WETH");
    
  }
}
