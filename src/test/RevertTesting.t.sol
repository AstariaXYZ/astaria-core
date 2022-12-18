// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
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

import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";

contract RevertTesting is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;

  enum InvalidStates {
    NO_AUTHORITY,
    NOT_ENOUGH_FUNDS,
    INVALID_LIEN_ID,
    COLLATERAL_AUCTION,
    COLLATERAL_NOT_DEPOSITED,
    LIEN_NO_DEBT,
    EXPIRED_LIEN,
    DEBT_LIMIT,
    MAX_LIENS
  }

  function testCannotRandomAccountIncrementNonce() public {
    address privateVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 10 days
    });

    vm.expectRevert(
      abi.encodeWithSelector(
        IVaultImplementation.InvalidRequest.selector,
        IVaultImplementation.InvalidRequestReason.NO_AUTHORITY
      )
    );
    VaultImplementation(privateVault).incrementNonce();
    assertEq(
      VaultImplementation(privateVault).getStrategistNonce(),
      uint32(0),
      "vault was incremented, when it shouldn't be"
    );
  }

  function testFailInvalidSignature() public {
    TestNFT nft = new TestNFT(3);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);
    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    _lendToVault(
      Lender({addr: strategistOne, amountToLend: 50 ether}),
      privateVault
    );

    IAstariaRouter.Commitment memory terms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistRoguePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      stack: new ILienToken.Stack[](0)
    });

    ERC721(tokenContract).safeTransferFrom(
      address(this),
      address(COLLATERAL_TOKEN),
      tokenId,
      ""
    );

    COLLATERAL_TOKEN.setApprovalForAll(address(ASTARIA_ROUTER), true);

    uint256 balanceOfBefore = ERC20(privateVault).balanceOf(address(this));
    vm.expectRevert(abi.encodePacked("InvalidRequest(1)"));
    VaultImplementation(privateVault).commitToLien(terms, address(this));
    assertEq(
      balanceOfBefore,
      ERC20(privateVault).balanceOf(address(this)),
      "balance changed"
    );
  }

  // Only strategists for PrivateVaults can supply capital
  function testFailSoloLendNotAppraiser() public {
    TestNFT nft = new TestNFT(3);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      privateVault
    );
  }

  function testCannotBorrowMoreThanMaxAmount() public {
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

    ILienToken.Details memory details = standardLienDetails;
    details.maxAmount = 10 ether;

    ILienToken.Stack[] memory stack;
    // borrow 10 eth against the dummy NFT
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details,
      amount: 11 ether,
      isFirstLien: true,
      stack: stack,
      revertMessage: abi.encodeWithSelector(
        IAstariaRouter.InvalidCommitmentState.selector,
        IAstariaRouter.CommitmentState.INVALID_AMOUNT
      )
    });
  }

  // PublicVaults should not be able to progress to the next epoch unless all liens that are able to be liquidated have been liquidated
  function testCannotProcessEpochWithUnliquidatedLien() public {
    TestNFT nft = new TestNFT(3);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);

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
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    vm.warp(block.timestamp + 15 days);

    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidState.selector,
        IPublicVault.InvalidStates.LIENS_OPEN_FOR_EPOCH_NOT_ZERO
      )
    );
    PublicVault(publicVault).processEpoch();
  }

  function testCannotBorrowMoreThanMaxPotentialDebt() public {
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
      Lender({addr: address(1), amountToLend: 100 ether}),
      publicVault
    );

    ILienToken.Stack[] memory stack;

    // borrow 10 eth against the dummy NFT
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 50 ether,
      isFirstLien: true,
      stack: stack
    });

    _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails2,
      amount: 10 ether,
      isFirstLien: false,
      stack: stack,
      revertMessage: abi.encodeWithSelector(
        ILienToken.InvalidState.selector,
        ILienToken.InvalidStates.DEBT_LIMIT
      )
    });
  }

  function testCannotExceedMinMaxPublicVaultEpochLength() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidState.selector,
        IPublicVault.InvalidStates.EPOCH_TOO_LOW
      )
    );
    _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 0
    });
    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidState.selector,
        IPublicVault.InvalidStates.EPOCH_TOO_HIGH
      )
    );
    _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 80 days
    });
  }

  function testFailLienDurationZero() public {
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

    ILienToken.Details memory zeroDuration = standardLienDetails;
    zeroDuration.duration = 0;

    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: zeroDuration,
      amount: 10 ether,
      isFirstLien: true
    });
  }

  function testCannotLienRateZero() public {
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

    ILienToken.Details memory zeroRate = standardLienDetails;
    zeroRate.rate = 0;

    ILienToken.Stack[] memory stack;
    // borrow 10 eth against the dummy NFT
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: zeroRate,
      amount: 10 ether,
      isFirstLien: true,
      stack: stack,
      revertMessage: abi.encodeWithSelector(
        IAstariaRouter.InvalidCommitmentState.selector,
        IAstariaRouter.CommitmentState.INVALID_RATE
      )
    });
  }

  function testCannotLiquidationInitialAskExceedsAmountBorrowed() public {
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

    ILienToken.Details memory standardLien = standardLienDetails;
    standardLien.liquidationInitialAsk = 5 ether;
    standardLien.maxAmount = 10 ether;

    // borrow amount over liquidation initial ask
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLien,
      amount: 7.5 ether,
      isFirstLien: true,
      stack: new ILienToken.Stack[](0),
      revertMessage: abi.encodeWithSelector(
        ILienToken.InvalidState.selector,
        ILienToken.InvalidStates.INVALID_LIQUIDATION_INITIAL_ASK
      )
    });
  }

  function testCannotLiquidationInitialAsk0() public {
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

    ILienToken.Details memory zeroInitAsk = standardLienDetails;
    zeroInitAsk.liquidationInitialAsk = 0;

    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: zeroInitAsk,
      amount: 10 ether,
      isFirstLien: true,
      stack: new ILienToken.Stack[](0),
      revertMessage: abi.encodeWithSelector(
        ILienToken.InvalidState.selector,
        ILienToken.InvalidStates.INVALID_LIQUIDATION_INITIAL_ASK
      )
    });
  }

  function testFailPayLienAfterLiquidate() public {
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

    vm.warp(block.timestamp + 14 days);

    ASTARIA_ROUTER.liquidate(stack, uint8(0));

    _repay(stack, 0, 10 ether, address(this));
  }

  function testCannotCommitToLienPotentialDebtExceedsLiquidationInitialAsk()
    public
  {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 30 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 500 ether}),
      publicVault
    );

    ILienToken.Details memory details1 = standardLienDetails;
    details1.duration = 14 days;
    details1.liquidationInitialAsk = 100 ether;
    details1.maxPotentialDebt = 1000 ether;

    ILienToken.Details memory details2 = standardLienDetails;
    details2.duration = 25 days;
    details2.liquidationInitialAsk = 100 ether;
    details2.maxPotentialDebt = 1000 ether;

    IAstariaRouter.Commitment[]
      memory commitments = new IAstariaRouter.Commitment[](2);
    ILienToken.Stack[] memory stack;

    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details1,
      amount: 50 ether,
      isFirstLien: true,
      stack: stack
    });

    _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details2,
      amount: 50 ether,
      isFirstLien: false,
      stack: stack,
      revertMessage: abi.encodeWithSelector(
        ILienToken.InvalidState.selector,
        ILienToken.InvalidStates.INITIAL_ASK_EXCEEDED
      )
    });
  }
}
