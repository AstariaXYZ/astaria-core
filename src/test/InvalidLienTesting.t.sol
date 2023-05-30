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

import {
  IERC1155Receiver
} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

import {ERC721} from "gpl/ERC721.sol";

import {ICollateralToken} from "../interfaces/ICollateralToken.sol";
import {ILienToken} from "../interfaces/ILienToken.sol";
import {IPublicVault} from "../interfaces/IPublicVault.sol";
import {CollateralToken, IFlashAction} from "../CollateralToken.sol";
import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {VaultImplementation} from "../VaultImplementation.sol";
import {IVaultImplementation} from "../interfaces/IVaultImplementation.sol";
import {LienToken} from "../LienToken.sol";
import {PublicVault} from "../PublicVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";
import {
  Create2ClonesWithImmutableArgs
} from "create2-clones-with-immutable-args/Create2ClonesWithImmutableArgs.sol";

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";

contract InvalidLienTesting is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;

  // InvalidBuyoutDetails(maxAmount, buyout)
  // Raised if buyout amount (principal + interest fee if any) > new loan terms maxAmount
  function testInvalidBuyoutDetails() public {
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

    skip(7 days);

    uint256 accruedInterest = uint256(LIEN_TOKEN.getOwed(stack[0]));
    uint256 tenthOfRemaining = (uint256(
      LIEN_TOKEN.getOwed(stack[0], block.timestamp + 3 days)
    ) - accruedInterest).mulDivDown(1, 10);

    uint256 buyoutFee = _locateCurrentAmount({
      startAmount: tenthOfRemaining,
      endAmount: 0,
      startTime: 1,
      endTime: 1 + standardLienDetails.duration.mulDivDown(900, 1000),
      roundUp: true
    });

    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    ILienToken.Details memory details = refinanceLienDetails;
    details.maxAmount =
      buyoutFee +
      LIEN_TOKEN.getOwed(stack[0], block.timestamp) -
      1;
    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details,
      amount: 10 ether,
      stack: stack
    });

    _lendToPrivateVault(
      PrivateLender({
        addr: strategistOne,
        token: address(WETH9),
        amountToLend: 50 ether
      }),
      privateVault
    );
    vm.startPrank(strategistTwo);
    vm.expectRevert(
      abi.encodeWithSelector(
        ILienToken.InvalidBuyoutDetails.selector,
        10290410958900159999,
        10290410958900160000
      )
    );
    VaultImplementation(privateVault).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );
    vm.stopPrank();
  }

  // Raised on a refinance if the buyout amount (owed + interest fee if applicable) exceeds the new term's maxAmount
  function testInvalidRefinance() public {
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

    vm.warp(block.timestamp + 9 days);

    uint256 owed = uint256(LIEN_TOKEN.getOwed(stack[0]));

    address publicVault2 = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      publicVault2
    );

    ILienToken.Details memory invalidRefinance = standardLienDetails;
    invalidRefinance.rate = ((uint256(1e16) * 150) / (365 days)) + 1;
    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: publicVault2,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: invalidRefinance,
      amount: 10 ether,
      stack: stack
    });

    vm.expectRevert(
      abi.encodeWithSelector(ILienToken.InvalidRefinance.selector)
    );
    VaultImplementation(publicVault2).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );
  }

  function testFailInvalidLoanState() public {
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

    skip(10 days);

    // ILienToken.InvalidLoanState()
    _repay(stack, 0, 10 ether, address(this));
  }

  function testInvalidStatesEmptyState() public {
    TestNFT nft = new TestNFT(3);

    address tokenContract = address(nft);
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
      tokenId: 0,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: 1, // Different tokenId
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: false,
      stack: stack,
      revertMessage: abi.encodeWithSelector(
        ILienToken.InvalidLienState.selector,
        ILienToken.InvalidLienStates.EMPTY_STATE
      )
    });
  }

  // Attempting lien action after lien has expired
  function testFailInvalidLoanStateAfterExpiredLien() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

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

    // make sure the borrow was successful
    assertEq(WETH9.balanceOf(address(this)), initialBalance + 10 ether);

    skip(15 days);

    // InvalidLoanState() (error thrown inside helper transaction, so can't expectRevert
    _repay(stack, 0, 10 ether, address(this));
  }

  function testFailDebtLimit() public {
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
    ILienToken.Stack[] memory stack;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: false
    });

    vm.warp(block.timestamp + 9 days);

    uint256 owed = uint256(LIEN_TOKEN.getOwed(stack[0]));

    address publicVault2 = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    ILienToken.Details
      memory insufficientPotentialDebtRefinance = refinanceLienDetails;
    insufficientPotentialDebtRefinance.maxPotentialDebt = 1000 ether;

    IAstariaRouter.Commitment memory refinanceTerms3 = _generateValidTerms({
      vault: publicVault2,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: insufficientPotentialDebtRefinance,
      amount: 10 ether,
      stack: stack
    });

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      publicVault2
    );

    vm.expectRevert(); // INVALID_HASH, but similar conditional fail to DEBT_LIMIT
    VaultImplementation(publicVault2).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms3
    );
  }

  function testMaxLiens() public {
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
      Lender({addr: address(1), amountToLend: 1000 ether}),
      publicVault
    );

    // borrow 10 eth against the dummy NFT
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

    ILienToken.Details memory details2 = standardLienDetails;
    details2.maxPotentialDebt = 100 ether;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details2,
      amount: 1,
      isFirstLien: false,
      stack: stack
    });

    ILienToken.Details memory details3 = standardLienDetails;
    details3.maxPotentialDebt = 101 ether;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details3,
      amount: 1,
      isFirstLien: false,
      stack: stack
    });

    ILienToken.Details memory details4 = standardLienDetails;
    details4.maxPotentialDebt = 102 ether;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details4,
      amount: 1,
      isFirstLien: false,
      stack: stack
    });

    ILienToken.Details memory details5 = standardLienDetails;
    details5.maxPotentialDebt = 103 ether;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details5,
      amount: 1,
      isFirstLien: false,
      stack: stack
    });

    ILienToken.Details memory details6 = standardLienDetails;
    details6.maxPotentialDebt = 104 ether;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details6,
      amount: 1,
      isFirstLien: false,
      stack: stack,
      revertMessage: abi.encodeWithSelector(
        ILienToken.InvalidLienState.selector,
        ILienToken.InvalidLienStates.MAX_LIENS
      )
    });
  }

  function testInvalidLiquidationInitialAsk() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    ILienToken.Details memory details = standardLienDetails;
    details.liquidationInitialAsk = 10 ether - 1;
    ILienToken.Stack[] memory stack;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details,
      amount: 10 ether,
      isFirstLien: true,
      stack: stack,
      revertMessage: abi.encodeWithSelector(
        ILienToken.InvalidLienState.selector,
        ILienToken.InvalidLienStates.INVALID_LIQUIDATION_INITIAL_ASK
      )
    });
  }

  function testLiquidationInitialAskExceeded() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    ILienToken.Details memory details = standardLienDetails;
    details.liquidationInitialAsk = 20 ether;
    ILienToken.Stack[] memory stack;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details,
      amount: 10 ether,
      isFirstLien: true,
      stack: stack
    });

    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails,
      amount: 10 ether,
      isFirstLien: true,
      stack: stack,
      revertMessage: abi.encodeWithSelector(
        ILienToken.InvalidLienState.selector,
        ILienToken.InvalidLienStates.INITIAL_ASK_EXCEEDED
      )
    });
  }
}
