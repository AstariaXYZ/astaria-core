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

contract AstariaTest is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeCastLib for uint256;

  function testBasicPublicVaultLoan() public {
    // Dummy721 nft = new Dummy721();
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

    // make sure the borrow was successful
    assertEq(WETH9.balanceOf(address(this)), initialBalance + 10 ether);

    vm.warp(block.timestamp + 9 days);

    _repay(collateralId, 10 ether, address(this));
  }

  function testBasicPrivateVaultLoan() public {
    Dummy721 nft = new Dummy721();
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
      lienDetails: standardLien,
      amount: 10 ether,
      isFirstLien: true
    });

    assertEq(WETH9.balanceOf(address(this)), initialBalance + 10 ether);
  }

  function testWithdrawProxy() public {
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

    uint256 collateralId = tokenContract.computeId(tokenId);

    uint256 vaultTokenBalance = IERC20(publicVault).balanceOf(address(1));

    // _signalWithdrawAtFutureEpoch(address(1), publicVault, uint64(1));
    _signalWithdraw(address(1), publicVault);

    address withdrawProxy = PublicVault(publicVault).withdrawProxies(
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
      ERC20(PublicVault(publicVault).underlying()).balanceOf(address(1)),
      50 ether
    );
  }

  function testLiquidationAccountant() public {
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

    uint256 vaultTokenBalance = IERC20(publicVault).balanceOf(address(1));

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

    assertEq(vaultTokenBalance, IERC20(withdrawProxy).balanceOf(address(1)));

    vm.warp(block.timestamp + 14 days); // end of loan

    ASTARIA_ROUTER.liquidate(collateralId, uint256(0));

    address liquidationAccountant = PublicVault(publicVault)
      .liquidationAccountants(0);

    assertTrue(
      liquidationAccountant != address(0),
      "LiquidationAccountant not deployed"
    );

    _bid(address(2), collateralId, 20 ether);

    vm.warp(block.timestamp + 1 days); // epoch boundary

    PublicVault(publicVault).processEpoch();

    vm.warp(block.timestamp + 13 days);
    LiquidationAccountant(liquidationAccountant).claim();

    PublicVault(publicVault).transferWithdrawReserve();

    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy).redeem(
      vaultTokenBalance,
      address(1),
      address(1)
    );
    vm.stopPrank();
    assertEq(WETH9.balanceOf(address(1)), 50410958904104000000);
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

    // make sure the borrow was successful
    assertEq(WETH9.balanceOf(address(this)), initialBalance + 10 ether);

    vm.warp(block.timestamp + 9 days);

    _repay(collateralId, 50 ether, address(this));

    COLLATERAL_TOKEN.releaseToAddress(collateralId, address(this));

    assertEq(ERC721(tokenContract).ownerOf(tokenId), address(this));
  }

  function testCollateralTokenFileSetup() public {
    bytes memory astariaRouterAddr = abi.encode(address(0));
    COLLATERAL_TOKEN.file(bytes32("setAstariaRouter"), astariaRouterAddr);
    assert(COLLATERAL_TOKEN.ASTARIA_ROUTER() == IAstariaRouter(address(0)));

    bytes memory auctionHouseAddr = abi.encode(address(0));
    COLLATERAL_TOKEN.file(bytes32("setAuctionHouse"), auctionHouseAddr);
    assert(COLLATERAL_TOKEN.AUCTION_HOUSE() == IAuctionHouse(address(0)));

    bytes memory securityHook = abi.encode(address(0), address(0));
    COLLATERAL_TOKEN.file(bytes32("setSecurityHook"), securityHook);
    assert(COLLATERAL_TOKEN.securityHooks(address(0)) == address(0));

    vm.expectRevert("unsupported/file");
    COLLATERAL_TOKEN.file(bytes32("Andrew Redden"), "");
  }

  function testLienTokenFileSetup() public {
    bytes memory auctionHouseAddr = abi.encode(address(0));
    LIEN_TOKEN.file(bytes32("setAuctionHouse"), auctionHouseAddr);
    assert(LIEN_TOKEN.AUCTION_HOUSE() == IAuctionHouse(address(0)));

    bytes memory collateralIdAddr = abi.encode(address(0));
    LIEN_TOKEN.file(bytes32("setCollateralToken"), collateralIdAddr);
    assert(LIEN_TOKEN.COLLATERAL_TOKEN() == ICollateralToken(address(0)));

    vm.expectRevert("unsupported/file");
    COLLATERAL_TOKEN.file(bytes32("Justin Bram"), "");
  }

  function _warpToEpochEnd(address vault) internal {
    //warps to the first second after the epoch end
    vm.warp(
      PublicVault(vault).getEpochEnd(PublicVault(vault).getCurrentEpoch()) + 1
    );
  }

  function mintAndDeposit(address tokenContract, uint256 tokenId) internal {
    TestNFT(tokenContract).mint(address(this), tokenId);
    ERC721(tokenContract).safeTransferFrom(
      address(this),
      address(COLLATERAL_TOKEN),
      tokenId,
      ""
    );
  }

  function testEpochProcessionMultipleActors() public {
    address alice = address(1);
    address bob = address(2);
    address charlie = address(3);
    address devon = address(4);
    address edgar = address(5);

    TestNFT nft = new TestNFT(2);
    mintAndDeposit(address(nft), 5);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(Lender({addr: bob, amountToLend: 50 ether}), publicVault);
    _lendToVault(Lender({addr: alice, amountToLend: 50 ether}), publicVault);

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

    vm.warp(block.timestamp + 9 days);
    _repay(collateralId, 100 ether, address(this));
    _warpToEpochEnd(publicVault);
    //after epoch end
    uint256 balance = ERC20(PublicVault(publicVault).underlying()).balanceOf(
      publicVault
    );
    PublicVault(publicVault).processEpoch();
    _lendToVault(Lender({addr: bob, amountToLend: 50 ether}), publicVault);
    _warpToEpochEnd(publicVault);

    _lendToVault(Lender({addr: alice, amountToLend: 50 ether}), publicVault);
    _warpToEpochEnd(publicVault);
    _signalWithdraw(alice, publicVault);

    _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: uint256(5),
      lienDetails: standardLien,
      amount: 10 ether,
      isFirstLien: false
    });
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

  function run() public {
    testBasicPublicVaultLoan();
  }
}
