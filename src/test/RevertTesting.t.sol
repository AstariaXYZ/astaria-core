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

  function testCannotDeployUnderlyingWithNoCode() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        IAstariaRouter.InvalidUnderlying.selector,
        address(3)
      )
    );
    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      token: address(3)
    });
  }

  function testFullExitWithLiquidation() public {
    address alice = address(1);
    address bob = address(2);
    TestNFT nft = new TestNFT(6);
    uint256 tokenId = uint256(5);
    address tokenContract = address(nft);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(Lender({addr: bob, amountToLend: 50 ether}), publicVault);
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: blueChipDetails,
      amount: 50 ether,
      isFirstLien: true
    });

    _signalWithdraw(bob, publicVault);

    WithdrawProxy withdrawProxy = WithdrawProxy(
      PublicVault(publicVault).getWithdrawProxy(0)
    );
    assertEq(
      PublicVault(publicVault).getWithdrawReserve(),
      withdrawProxy.getExpected()
    );
    uint256 collateralId = tokenContract.computeId(tokenId);
    vm.warp(block.timestamp + 11 days);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(
      stack,
      uint8(0)
    );
    _bid(Bidder(bidder, bidderPK), listedOrder, 100 ether);

    skip(PublicVault(publicVault).timeToEpochEnd());

    PublicVault(publicVault).processEpoch();

    vm.warp(block.timestamp + 13 days);
    PublicVault(publicVault).transferWithdrawReserve();

    vm.startPrank(bob);

    uint256 vaultTokenBalance = withdrawProxy.balanceOf(bob);

    withdrawProxy.redeem(vaultTokenBalance, bob, bob);

    assertEq(WETH9.balanceOf(bob), uint(52260273972572000000));
    vm.stopPrank();
  }

  function testCannotEndAuctionWithWrongToken() public {
    address alice = address(1);
    address bob = address(2);
    TestNFT nft = new TestNFT(6);
    uint256 tokenId = uint256(5);
    address tokenContract = address(nft);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(Lender({addr: bob, amountToLend: 150 ether}), publicVault);
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: blueChipDetails,
      amount: 100 ether,
      isFirstLien: true
    });

    uint256 collateralId = tokenContract.computeId(tokenId);
    vm.warp(block.timestamp + 11 days);
    OrderParameters memory listedOrder = ASTARIA_ROUTER.liquidate(
      stack,
      uint8(0)
    );

    erc20s[0].mint(address(this), 1000 ether);
    ClearingHouse clearingHouse = ClearingHouse(
      COLLATERAL_TOKEN.getClearingHouse(collateralId)
    );
    erc20s[0].transfer(address(clearingHouse), 1000 ether);
    _deployBidderConduit(bidder);
    vm.startPrank(address(bidderConduits[bidder].conduit));

    vm.expectRevert(
      abi.encodeWithSelector(
        ClearingHouse.InvalidRequest.selector,
        ClearingHouse.InvalidRequestReason.NOT_ENOUGH_FUNDS_RECEIVED
      )
    );
    clearingHouse.safeTransferFrom(
      address(this),
      address(this),
      uint256(uint160(address(erc20s[0]))),
      1000 ether,
      "0x"
    );
  }

  function testCannotSettleAuctionIfNoneRunning() public {
    address alice = address(1);
    address bob = address(2);
    TestNFT nft = new TestNFT(6);
    uint256 tokenId = uint256(5);
    address tokenContract = address(nft);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(Lender({addr: bob, amountToLend: 150 ether}), publicVault);
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: blueChipDetails,
      amount: 100 ether,
      isFirstLien: true
    });

    uint256 collateralId = tokenContract.computeId(tokenId);
    vm.warp(block.timestamp + 11 days);

    ClearingHouse clearingHouse = ClearingHouse(
      COLLATERAL_TOKEN.getClearingHouse(collateralId)
    );
    deal(address(WETH9), address(clearingHouse), 1000 ether);
    _deployBidderConduit(bidder);
    vm.startPrank(address(bidderConduits[bidder].conduit));

    vm.expectRevert(
      abi.encodeWithSelector(
        ClearingHouse.InvalidRequest.selector,
        ClearingHouse.InvalidRequestReason.NO_AUCTION
      )
    );
    clearingHouse.safeTransferFrom(
      address(this),
      address(this),
      uint256(uint160(address(erc20s[0]))),
      1000 ether,
      "0x"
    );
  }

  //https://github.com/code-423n4/2023-01-astaria-findings/issues/488
  function testFailsToMintSharesFromPublicVaultUsingRouterWhenSharePriceIsBiggerThanOne()
    public
  {
    uint256 amountIn = 50 ether;
    address alice = address(1);
    address bob = address(2);
    vm.deal(bob, amountIn);

    TestNFT nft = new TestNFT(2);
    _mintNoDepositApproveRouter(address(nft), 5);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // after alice deposits 50 ether WETH in publicVault, publicVault's share price becomes 1
    _lendToVault(Lender({addr: alice, amountToLend: amountIn}), publicVault);

    // the borrower borrows 10 ether WETH from publicVault
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
    uint256 collateralId = tokenContract.computeId(tokenId);

    // the borrower repays for the lien after 9 days, and publicVault's share price becomes bigger than 1
    vm.warp(block.timestamp + 9 days);
    _repay(stack1, 0, 100 ether, address(this));

    vm.startPrank(bob);

    // bob owns 50 ether WETH
    WETH9.deposit{value: amountIn}();
    WETH9.transfer(address(ASTARIA_ROUTER), amountIn);

    // bob wants to mint 1 ether shares from publicVault using the router but fails
    vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
    ASTARIA_ROUTER.mint(IERC4626(publicVault), bob, 1 ether, type(uint256).max);

    vm.stopPrank();
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

  function testCannotCorruptVaults() public {
    TestNFT nft = new TestNFT(3);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);
    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    _lendToPrivateVault(
      PrivateLender({
        addr: strategistOne,
        token: address(WETH9),
        amountToLend: 50 ether
      }),
      privateVault
    );

    IAstariaRouter.Commitment memory terms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
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

    uint256 balanceOfBefore = ERC20(WETH9).balanceOf(address(this));
    (uint256 lienId, ) = VaultImplementation(privateVault).commitToLien(terms);

    address underlying = address(WETH9);
    uint256 epochLength = 10 days;
    uint256 vaultFee = 0;
    emit log_named_uint("block number", block.number);
    address attackTarget = Create2ClonesWithImmutableArgs.deriveAddress(
      address(ASTARIA_ROUTER),
      ASTARIA_ROUTER.BEACON_PROXY_IMPLEMENTATION(),
      abi.encodePacked(
        address(ASTARIA_ROUTER),
        uint8(IAstariaRouter.ImplementationType.PublicVault),
        strategistTwo,
        underlying,
        block.timestamp,
        epochLength,
        vaultFee
      ),
      keccak256(abi.encodePacked(strategistTwo, blockhash(block.number - 1)))
    );

    vm.startPrank(strategistOne);
    LIEN_TOKEN.transferFrom(strategistOne, attackTarget, lienId);
    vm.stopPrank();

    vm.expectRevert(
      abi.encodeWithSelector(
        IAstariaRouter.InvalidVaultState.selector,
        IAstariaRouter.VaultState.CORRUPTED
      )
    );
    address publicVault = _createPublicVault({
      strategist: strategistTwo,
      delegate: strategistTwo,
      epochLength: epochLength
    });
  }

  function testInvalidFileData() public {
    vm.expectRevert(
      abi.encodeWithSelector(IAstariaRouter.InvalidFileData.selector)
    );
    ASTARIA_ROUTER.file(
      IAstariaRouter.File({
        what: IAstariaRouter.FileType.ProtocolFee,
        data: abi.encode(uint256(11), uint256(10))
      })
    );
  }

  function testFailDepositWhenProtocolPaused() public {
    address privateVault = _createPrivateVault({
      delegate: strategistOne,
      strategist: strategistTwo
    });
    ASTARIA_ROUTER.__emergencyPause();

    _lendToPrivateVault(
      PrivateLender({
        addr: strategistTwo,
        token: address(WETH9),
        amountToLend: 50 ether
      }),
      privateVault
    );
  }

  function testInvalidVaultRequest() public {
    TestNFT nft = new TestNFT(2);
    address tokenContract = address(nft);
    uint256 initialBalance = WETH9.balanceOf(address(this));

    // Create a private vault with WETH asset
    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: address(0),
      token: address(WETH9)
    });

    _lendToPrivateVault(
      PrivateLender({
        addr: strategistOne,
        token: address(WETH9),
        amountToLend: 500 ether
      }),
      privateVault
    );

    // Send the NFT to Collateral contract and receive Collateral token
    ERC721(tokenContract).safeTransferFrom(
      address(this),
      address(COLLATERAL_TOKEN),
      1,
      ""
    );

    // generate valid terms
    uint256 amount = 50 ether; // amount to borrow
    IAstariaRouter.Commitment memory c = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: 1,
      lienDetails: standardLienDetails,
      amount: amount,
      stack: new ILienToken.Stack[](0)
    });

    // Attack starts here
    // The borrower an asset which has no value in the market
    MockERC20 FakeToken = new MockERC20("USDC", "FakeAsset", 18); // this could be any ERC token created by the attacker
    FakeToken.mint(address(this), 500 ether);
    // The borrower creates a private vault with his/her asset
    address privateVaultOfBorrower = _createPrivateVault({
      strategist: address(this),
      delegate: address(0),
      token: address(FakeToken)
    });

    c.lienRequest.strategy.vault = privateVaultOfBorrower;
    vm.expectRevert(
      abi.encodeWithSelector(
        IVaultImplementation.InvalidRequest.selector,
        IVaultImplementation.InvalidRequestReason.INVALID_VAULT
      )
    );
    IVaultImplementation(privateVault).commitToLien(c);
  }

  function testCannotCommitWithInvalidSignature() public {
    TestNFT nft = new TestNFT(3);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);
    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    _lendToPrivateVault(
      PrivateLender({
        addr: strategistOne,
        token: address(WETH9),
        amountToLend: 50 ether
      }),
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

    vm.expectRevert(
      abi.encodeWithSelector(
        IVaultImplementation.InvalidRequest.selector,
        IVaultImplementation.InvalidRequestReason.INVALID_SIGNATURE
      )
    );
    VaultImplementation(privateVault).commitToLien(terms);
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

  function testCannotCommitToLienAfterStrategyDeadline() public {
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

    uint256 balanceBefore = WETH9.balanceOf(address(this));
    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true,
      stack: new ILienToken.Stack[](0),
      revertMessage: abi.encodeWithSelector(
        IVaultImplementation.InvalidRequest.selector,
        IVaultImplementation.InvalidRequestReason.EXPIRED
      ),
      beforeExecution: this._skip11DaysToFailStrategyDeadlineCheck
    });
  }

  function _skip11DaysToFailStrategyDeadlineCheck() public {
    skip(11 days);
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

  function testCannotSelfLiquidateBeforeExpiration() public {
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

    vm.expectRevert(
      abi.encodeWithSelector(
        IAstariaRouter.InvalidLienState.selector,
        IAstariaRouter.LienState.HEALTHY
      )
    );
    ASTARIA_ROUTER.liquidate(stack, uint8(0));
  }

    function testSmallRepaymentDebtCompound() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);
    ASTARIA_ROUTER.file(
      IAstariaRouter.File({
        what: IAstariaRouter.FileType.MaxEpochLength,
        data: abi.encode(365 days)
      })
    );

    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 365 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 500 ether}),
      publicVault
    );

    ILienToken.Details memory details1 = standardLienDetails;
    details1.rate = (uint256(1e16) * 200) / (365 days) - 1; // max rate
    details1.duration = 365 days;
    ILienToken.Stack[] memory stack;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details1,
      amount: 10 ether,
      isFirstLien: true
    });

    ILienToken.Details memory details2 = standardLienDetails;
    details2.maxPotentialDebt = 29999999999517760000;
    details2.duration = 365 days;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details2,
      amount: 10 ether,
      isFirstLien: false,
      stack: stack
    });

    ILienToken.Details memory details3 = standardLienDetails;
    details3.maxPotentialDebt = 500 ether;
    details3.duration = 365 days;
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details3,
      amount: 10 ether,
      isFirstLien: false,
      stack: stack
    });

    skip(100 days);
    stack = _pay({stack: stack, position: 0, amount: 1, payer: address(this)});

    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });
    _lendToPrivateVault(
      PrivateLender({
        addr: strategistOne,
        token: address(WETH9),
        amountToLend: 50 ether
      }),
      privateVault
    );

    ILienToken.Details memory details4 = standardLienDetails;
    details4.duration = 365 days + 105 days;
    details4.maxPotentialDebt = 10000 ether;
    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details4,
      amount: 0,
      stack: stack
    });

    vm.expectRevert(
      abi.encodeWithSelector(
        ILienToken.InvalidState.selector,
        ILienToken.InvalidStates.DEBT_LIMIT
      )
    );
    vm.startPrank(strategistTwo);
    VaultImplementation(privateVault).buyoutLien(
      stack,
      uint8(2),
      refinanceTerms
    );
    vm.stopPrank();
  }
}
