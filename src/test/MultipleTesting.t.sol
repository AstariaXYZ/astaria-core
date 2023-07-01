//// SPDX-License-Identifier: BUSL-1.1

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
contract Placeholder {

}

//pragma solidity =0.8.17;
//
//import "forge-std/Test.sol";
//
//import {Authority} from "solmate/auth/Auth.sol";
//import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
//import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
//import {
//  MultiRolesAuthority
//} from "solmate/auth/authorities/MultiRolesAuthority.sol";
//
//import {ERC721} from "gpl/ERC721.sol";
//import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";
//
//import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
//import {VaultImplementation} from "../VaultImplementation.sol";
//import {PublicVault} from "../PublicVault.sol";
//import {TransferProxy} from "../TransferProxy.sol";
//import {WithdrawProxy} from "../WithdrawProxy.sol";
//
//import {Strings2} from "./utils/Strings2.sol";
//
//import "./TestHelpers.t.sol";
//
//contract MultipleTesting is TestHelpers {
//  using FixedPointMathLib for uint256;
//  using CollateralLookup for address;
//  using SafeCastLib for uint256;
//
//  function testRepaymentWithMultipleLiensAndVaults() public {
//    TestNFT nft = new TestNFT(3);
//
//    address tokenContract = address(nft);
//    uint256 tokenId = uint256(0);
//    address payable publicVault1 = _createPublicVault({
//      strategist: strategistOne,
//      delegate: strategistTwo,
//      epochLength: 14 days
//    });
//
//    address payable publicVault2 = _createPublicVault({
//      strategist: strategistOne,
//      delegate: strategistTwo,
//      epochLength: 10 days
//    });
//
//    _lendToVault(
//      Lender({addr: address(1), amountToLend: 50 ether}),
//      publicVault1
//    );
//
//    _lendToVault(
//      Lender({addr: address(2), amountToLend: 50 ether}),
//      publicVault2
//    );
//
//    ILienToken.Stack memory stack;
//    (, stack) = _commitToLien({
//      vault: payable(publicVault)1,
//      strategist: strategistOne,
//      strategistPK: strategistOnePK,
//      tokenContract: tokenContract,
//      tokenId: tokenId,
//      lienDetails: standardLienDetails,
//      amount: 50 ether,
//      isFirstLien: true
//    });
//
//    ILienToken.Details memory details2 = standardLienDetails;
//    details2.maxPotentialDebt = 100 ether;
//    (, stack) = _commitToLien({
//      vault: payable(publicVault)2,
//      strategist: strategistOne,
//      strategistPK: strategistOnePK,
//      tokenContract: tokenContract,
//      tokenId: tokenId,
//      lienDetails: details2,
//      amount: 50 ether,
//      isFirstLien: false,
//      stack: stack
//    });
//
//    skip(2 days);
//    stack = _repay({
//      stack: stack,
//      position: 0,
//      amount: 100 ether,
//      payer: address(this)
//    });
//
//    skip(2 days);
//
//    (, stack) = _commitToLien({
//      vault: payable(publicVault)1,
//      strategist: strategistOne,
//      strategistPK: strategistOnePK,
//      tokenContract: tokenContract,
//      tokenId: tokenId,
//      lienDetails: details2,
//      amount: 10 ether,
//      isFirstLien: false,
//      stack: stack
//    });
//
//    stack = _repay({
//      stack: stack,
//      position: 0,
//      amount: 100 ether,
//      payer: address(this)
//    });
//    stack = _repay({
//      stack: stack,
//      position: 0,
//      amount: 100 ether,
//      payer: address(this)
//    });
//  }
//
//  function testMultipleLoansNoStrategistFee() public {
//    TestNFT nft = new TestNFT(2);
//
//    address tokenContract = address(nft);
//    address payable publicVault = _createPublicVault({
//      strategist: strategistOne,
//      delegate: strategistTwo,
//      epochLength: 14 days,
//      vaultFee: 0
//    });
//
//    _lendToVault(
//      Lender({addr: address(1), amountToLend: 50 ether}),
//      publicVault
//    );
//
//    _lendToVault(
//      Lender({addr: address(2), amountToLend: 25 ether}),
//      publicVault
//    );
//
//    (, ILienToken.Stack memory stack1) = _commitToLien({
//      vault: payable(publicVault),
//      strategist: strategistOne,
//      strategistPK: strategistOnePK,
//      tokenContract: tokenContract,
//      tokenId: 0,
//      lienDetails: standardLienDetails,
//      amount: 10 ether,
//      isFirstLien: true
//    });
//
//    (, ILienToken.Stack memory stack2) = _commitToLien({
//      vault: payable(publicVault),
//      strategist: strategistOne,
//      strategistPK: strategistOnePK,
//      tokenContract: tokenContract,
//      tokenId: 1,
//      lienDetails: standardLienDetails,
//      amount: 10 ether,
//      isFirstLien: true
//    });
//
//    stack1 = _repay({
//      stack: stack1,
//      position: 0,
//      amount: 5 ether,
//      payer: address(this)
//    });
//
//    skip(1 days);
//    _repay({
//      stack: stack1,
//      position: 0,
//      amount: 100 ether,
//      payer: address(this)
//    });
//    _repay({
//      stack: stack2,
//      position: 0,
//      amount: 100 ether,
//      payer: address(this)
//    });
//
//    // vm.expectRevert();
//    vm.startPrank(strategistOne);
//    PublicVault(payable(publicVault)).claim();
//    vm.stopPrank();
//
//    assertEq(
//      ERC20(publicVault).balanceOf(strategistOne),
//      0,
//      "Strategist was incorrectly given VaultToken fees"
//    );
//  }
//
//  function testMultipleLoansMinStrategistFeeYieldsZero() public {
//    TestNFT nft = new TestNFT(2);
//
//    address tokenContract = address(nft);
//    ASTARIA_ROUTER.file(
//      IAstariaRouter.File({
//        what: IAstariaRouter.FileType.MaxStrategistFee,
//        data: abi.encode(5e17)
//      })
//    );
//    address payable publicVault = _createPublicVault({
//      strategist: strategistOne,
//      delegate: strategistTwo,
//      epochLength: 14 days,
//      vaultFee: 1
//    });
//
//    _lendToVault(
//      Lender({addr: address(1), amountToLend: 50 ether}),
//      publicVault
//    );
//
//    _lendToVault(
//      Lender({addr: address(2), amountToLend: 25 ether}),
//      publicVault
//    );
//
//    (, ILienToken.Stack memory stack1) = _commitToLien({
//      vault: payable(publicVault),
//      strategist: strategistOne,
//      strategistPK: strategistOnePK,
//      tokenContract: tokenContract,
//      tokenId: 0,
//      lienDetails: standardLienDetails,
//      amount: 10 ether,
//      isFirstLien: true
//    });
//
//    (, ILienToken.Stack memory stack2) = _commitToLien({
//      vault: payable(publicVault),
//      strategist: strategistOne,
//      strategistPK: strategistOnePK,
//      tokenContract: tokenContract,
//      tokenId: 1,
//      lienDetails: standardLienDetails,
//      amount: 10 ether,
//      isFirstLien: true
//    });
//
//    stack1 = _repay({
//      stack: stack1,
//      position: 0,
//      amount: 5 ether,
//      payer: address(this)
//    });
//
//    skip(1 days);
//    _repay({
//      stack: stack1,
//      position: 0,
//      amount: 100 ether,
//      payer: address(this)
//    });
//    _repay({
//      stack: stack2,
//      position: 0,
//      amount: 100 ether,
//      payer: address(this)
//    });
//
//    vm.startPrank(strategistOne);
//    PublicVault(payable(publicVault)).claim();
//    vm.stopPrank();
//
//    assertEq(
//      ERC20(publicVault).balanceOf(strategistOne),
//      0,
//      "Strategist received incorrect fee amount"
//    );
//  }
//
//  function testMultipleLoansHighPrecisionSmallStrategistFee() public {
//    TestNFT nft = new TestNFT(2);
//
//    address tokenContract = address(nft);
//    ASTARIA_ROUTER.file(
//      IAstariaRouter.File({
//        what: IAstariaRouter.FileType.MaxStrategistFee,
//        data: abi.encode(5e17)
//      })
//    );
//    address payable publicVault = _createPublicVault({
//      strategist: strategistOne,
//      delegate: strategistTwo,
//      epochLength: 14 days,
//      vaultFee: 1e14
//    });
//
//    _lendToVault(
//      Lender({addr: address(1), amountToLend: 50 ether}),
//      publicVault
//    );
//
//    _lendToVault(
//      Lender({addr: address(2), amountToLend: 25 ether}),
//      publicVault
//    );
//
//    (, ILienToken.Stack memory stack1) = _commitToLien({
//      vault: payable(publicVault),
//      strategist: strategistOne,
//      strategistPK: strategistOnePK,
//      tokenContract: tokenContract,
//      tokenId: 0,
//      lienDetails: standardLienDetails,
//      amount: 10 ether,
//      isFirstLien: true
//    });
//
//    (, ILienToken.Stack memory stack2) = _commitToLien({
//      vault: payable(publicVault),
//      strategist: strategistOne,
//      strategistPK: strategistOnePK,
//      tokenContract: tokenContract,
//      tokenId: 1,
//      lienDetails: standardLienDetails,
//      amount: 10 ether,
//      isFirstLien: true
//    });
//
//    stack1 = _repay({
//      stack: stack1,
//      position: 0,
//      amount: 5 ether,
//      payer: address(this)
//    });
//
//    skip(1 days);
//    _repay({
//      stack: stack1,
//      position: 0,
//      amount: 100 ether,
//      payer: address(this)
//    });
//    _repay({
//      stack: stack2,
//      position: 0,
//      amount: 100 ether,
//      payer: address(this)
//    });
//
//    vm.startPrank(strategistOne);
//    PublicVault(payable(publicVault)).claim();
//    vm.stopPrank();
//
//    assertEq(
//      ERC20(publicVault).balanceOf(strategistOne),
//      6159321218262,
//      "Strategist received incorrect fee amount"
//    );
//  }
//
//  function testMultipleLoans001StrategistFee() public {
//    TestNFT nft = new TestNFT(2);
//
//    address tokenContract = address(nft);
//    ASTARIA_ROUTER.file(
//      IAstariaRouter.File({
//        what: IAstariaRouter.FileType.MaxStrategistFee,
//        data: abi.encode(5e17)
//      })
//    );
//    address payable publicVault = _createPublicVault({
//      strategist: strategistOne,
//      delegate: strategistTwo,
//      epochLength: 14 days,
//      vaultFee: 1e15 // .001 (0.1%) (1e15/1e18) 10 / 10_000
//    });
//
//    _lendToVault(
//      Lender({addr: address(1), amountToLend: 50 ether}),
//      publicVault
//    );
//
//    _lendToVault(
//      Lender({addr: address(2), amountToLend: 25 ether}),
//      publicVault
//    );
//
//    (, ILienToken.Stack memory stack1) = _commitToLien({
//      vault: payable(publicVault),
//      strategist: strategistOne,
//      strategistPK: strategistOnePK,
//      tokenContract: tokenContract,
//      tokenId: 0,
//      lienDetails: standardLienDetails,
//      amount: 10 ether,
//      isFirstLien: true
//    });
//
//    (, ILienToken.Stack memory stack2) = _commitToLien({
//      vault: payable(publicVault),
//      strategist: strategistOne,
//      strategistPK: strategistOnePK,
//      tokenContract: tokenContract,
//      tokenId: 1,
//      lienDetails: standardLienDetails,
//      amount: 10 ether,
//      isFirstLien: true
//    });
//
//    stack1 = _repay({
//      stack: stack1,
//      position: 0,
//      amount: 5 ether,
//      payer: address(this)
//    });
//
//    skip(1 days);
//    _repay({
//      stack: stack1,
//      position: 0,
//      amount: 100 ether,
//      payer: address(this)
//    });
//    _repay({
//      stack: stack2,
//      position: 0,
//      amount: 100 ether,
//      payer: address(this)
//    });
//
//    vm.startPrank(strategistOne);
//    PublicVault(payable(publicVault)).claim();
//    vm.stopPrank();
//
//    emit log_named_uint(
//      "strategistOne",
//      ERC20(publicVault).balanceOf(strategistOne)
//    );
//    assertEq(
//      ERC20(publicVault).balanceOf(strategistOne),
//      61593222299228,
//      "Strategist received incorrect fee amount"
//    );
//  }
//
//  function testMultipleLoans10StrategistFee() public {
//    TestNFT nft = new TestNFT(2);
//
//    address tokenContract = address(nft);
//    ASTARIA_ROUTER.file(
//      IAstariaRouter.File({
//        what: IAstariaRouter.FileType.MaxStrategistFee,
//        data: abi.encode(5e17)
//      })
//    );
//    address payable publicVault = _createPublicVault({
//      strategist: strategistOne,
//      delegate: strategistTwo,
//      epochLength: 14 days,
//      vaultFee: 1e17 // 10%
//    });
//
//    _lendToVault(
//      Lender({addr: address(1), amountToLend: 50 ether}),
//      publicVault
//    );
//
//    _lendToVault(
//      Lender({addr: address(2), amountToLend: 25 ether}),
//      publicVault
//    );
//
//    (, ILienToken.Stack memory stack1) = _commitToLien({
//      vault: payable(publicVault),
//      strategist: strategistOne,
//      strategistPK: strategistOnePK,
//      tokenContract: tokenContract,
//      tokenId: 0,
//      lienDetails: standardLienDetails,
//      amount: 10 ether,
//      isFirstLien: true
//    });
//
//    (, ILienToken.Stack memory stack2) = _commitToLien({
//      vault: payable(publicVault),
//      strategist: strategistOne,
//      strategistPK: strategistOnePK,
//      tokenContract: tokenContract,
//      tokenId: 1,
//      lienDetails: standardLienDetails,
//      amount: 10 ether,
//      isFirstLien: true
//    });
//
//    stack1 = _repay({
//      stack: stack1,
//      position: 0,
//      amount: 5 ether,
//      payer: address(this)
//    });
//
//    skip(1 days);
//    _repay({
//      stack: stack1,
//      position: 0,
//      amount: 100 ether,
//      payer: address(this)
//    });
//    _repay({
//      stack: stack2,
//      position: 0,
//      amount: 100 ether,
//      payer: address(this)
//    });
//
//    vm.startPrank(strategistOne);
//    PublicVault(payable(publicVault)).claim();
//    vm.stopPrank();
//
//    assertEq(
//      ERC20(publicVault).balanceOf(strategistOne),
//      6159433512483246,
//      "Strategist received incorrect fee amount"
//    );
//  }
//}
