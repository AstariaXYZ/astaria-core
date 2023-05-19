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

contract PartialRepaymentTesting is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeCastLib for uint256;

  function testEarlyAndPartialRepayments() public {
    TestNFT nft = new TestNFT(1);

    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    ILienToken.Stack[] memory stack;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 50 ether,
      isFirstLien: true
    });

    skip(2 days);

    stack = _repay({
      stack: stack,
      position: 0,
      amount: 30 ether,
      payer: address(this)
    });

    skip(2 days);

    stack = _repay({
      stack: stack,
      position: 0,
      amount: 15 ether,
      payer: address(this)
    });

    skip(2 days);

    stack = _repay({
      stack: stack,
      position: 0,
      amount: 40 ether,
      payer: address(this)
    });

    vm.expectRevert();
    LIEN_TOKEN.getOwed(stack[0]); // if doesn't exist anymore, was correctly paid back
  }

  function testPartialRepaymentAndWithdraw() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 7 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );
    _signalWithdraw(address(1), publicVault);

    ILienToken.Stack[] memory stack;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 50 ether,
      isFirstLien: true
    });

    skip(2 days);

    stack = _repay({
      stack: stack,
      position: 0,
      amount: 20 ether,
      payer: address(this)
    });

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();
    PublicVault(publicVault).transferWithdrawReserve();

    vm.startPrank(address(1));

    WithdrawProxy(withdrawProxy).redeem(
      IERC20(withdrawProxy).balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.stopPrank();
    assertEq(
      WETH9.balanceOf(address(1)),
      20 ether,
      "LP did not receive all of partial repayment"
    );
  }

  function testPartialRepaymentThenDefaultWithoutWithdrawProxy() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 7 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );
    _signalWithdraw(address(1), publicVault);

    ILienToken.Stack[] memory stack;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 50 ether,
      isFirstLien: true
    });

    skip(2 days);

    stack = _repay({
      stack: stack,
      position: 0,
      amount: 20 ether,
      payer: address(this)
    });

    _warpToEpochEnd(publicVault);

    PublicVault(publicVault).processEpoch();

    skip(3 days);

    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(
      stack,
      uint8(0)
    );

    _bid(Bidder(bidder, bidderPK), listedOrder, 50 ether);

    PublicVault(publicVault).transferWithdrawReserve();

    vm.startPrank(address(1));

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    WithdrawProxy(withdrawProxy).redeem(
      IERC20(withdrawProxy).balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.stopPrank();
    assertEq(
      WETH9.balanceOf(address(1)),
      51035843067790779294,
      "LP did not receive all of partial repayment and auction"
    );
  }

  function testPartialRepaymentThenDefaultWithWithdrawProxy() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 7 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );
    _signalWithdraw(address(1), publicVault);

    ILienToken.Details memory details = standardLienDetails;
    details.duration = 6 days;

    ILienToken.Stack[] memory stack;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details,
      amount: 50 ether,
      isFirstLien: true
    });

    skip(2 days);

    stack = _repay({
      stack: stack,
      position: 0,
      amount: 20 ether,
      payer: address(this)
    });

    skip(4 days);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(
      stack,
      uint8(0)
    );
    _bid(Bidder(bidder, bidderPK), listedOrder, 50 ether);

    PublicVault(publicVault).processEpoch();

    skip(3 days);
    PublicVault(publicVault).transferWithdrawReserve();
    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);
    withdrawProxy.claim();

    vm.startPrank(address(1));
    WithdrawProxy(withdrawProxy).redeem(
      IERC20(withdrawProxy).balanceOf(address(1)),
      address(1),
      address(1)
    );
    vm.stopPrank();
//    assertEq(
//      WETH9.balanceOf(address(1)),
//      50910865077863206400,
//      "LP did not receive all of partial repayment and auction"
//    );
  }
}
