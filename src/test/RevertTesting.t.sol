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
import {IAstariaRouter} from "../interfaces/IAstariaRouter.sol";
import {CollateralToken} from "../CollateralToken.sol";
import {AstariaRouter} from "../AstariaRouter.sol";
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
import {
  ProxyAdmin
} from "lib/seaport/lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {
  TransparentUpgradeableProxy
} from "lib/seaport/lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract RevertTesting is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;

  enum InvalidStates {
    NO_AUTHORITY,
    INVALID_LIEN_ID,
    COLLATERAL_AUCTION,
    COLLATERAL_NOT_DEPOSITED,
    EXPIRED_LIEN
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
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: bob, amountToLend: 50 ether}),
      payable(publicVault)
    );
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: blueChipDetails,
      amount: 50 ether
    });

    _signalWithdraw(bob, payable(publicVault));

    IWithdrawProxy withdrawProxy = IWithdrawProxy(
      PublicVault(payable(publicVault)).getWithdrawProxy(0)
    );
    assertEq(
      PublicVault(payable(publicVault)).getWithdrawReserve(),
      withdrawProxy.getExpected()
    );
    uint256 collateralId = tokenContract.computeId(tokenId);
    vm.warp(block.timestamp + 11 days);
    OrderParameters memory listedOrder = _liquidate(stack);
    _bid(Bidder(bidder, bidderPK), listedOrder, 100 ether, stack);

    skip(PublicVault(payable(publicVault)).timeToEpochEnd());

    PublicVault(payable(publicVault)).processEpoch();

    vm.warp(block.timestamp + 13 days);
    PublicVault(payable(publicVault)).transferWithdrawReserve();

    vm.startPrank(bob);

    uint256 vaultTokenBalance = withdrawProxy.balanceOf(bob);

    withdrawProxy.redeem(vaultTokenBalance, bob, bob);

    assertEq(WETH9.balanceOf(bob), uint(52260273972572000000));
    vm.stopPrank();
  }

  //  function testCannotEndAuctionWithWrongToken() public {
  //    address alice = address(1);
  //    address bob = address(2);
  //    TestNFT nft = new TestNFT(6);
  //    uint256 tokenId = uint256(5);
  //    address tokenContract = address(nft);
  //    address payable publicVault = _createPublicVault({
  //      strategist: strategistOne,
  //      delegate: strategistTwo,
  //      epochLength: 14 days
  //    });
  //
  //    _lendToVault(Lender({addr: bob, amountToLend: 150 ether}), payable(publicVault));
  //    (, ILienToken.Stack memory stack) = _commitToLien({
  //      vault: payable(publicVault),
  //      strategist: strategistOne,
  //      strategistPK: strategistOnePK,
  //      tokenContract: tokenContract,
  //      tokenId: tokenId,
  //      lienDetails: blueChipDetails,
  //      amount: 100 ether
  //    });
  //
  //    uint256 collateralId = tokenContract.computeId(tokenId);
  //    vm.warp(block.timestamp + 11 days);
  //    OrderParameters memory listedOrder = _liquidate(stack);
  //
  //    erc20s[0].mint(address(this), 1000 ether);
  //    ClearingHouse clearingHouse = ClearingHouse(
  //      COLLATERAL_TOKEN.getClearingHouse(collateralId)
  //    );
  //    erc20s[0].transfer(address(clearingHouse), 1000 ether);
  //    _deployBidderConduit(bidder);
  //    vm.startPrank(address(bidderConduits[bidder].conduit));
  //
  //    vm.expectRevert(
  //      abi.encodeWithSelector(
  //        ClearingHouse.InvalidRequest.selector,
  //        ClearingHouse.InvalidRequestReason.NOT_ENOUGH_FUNDS_RECEIVED
  //      )
  //    );
  //    clearingHouse.safeTransferFrom(
  //      address(this),
  //      address(this),
  //      uint256(uint160(address(erc20s[0]))),
  //      1000 ether,
  //      "0x"
  //    );
  //  }

  //  function testCannotSettleAuctionIfNoneRunning() public {
  //    address alice = address(1);
  //    address bob = address(2);
  //    TestNFT nft = new TestNFT(6);
  //    uint256 tokenId = uint256(5);
  //    address tokenContract = address(nft);
  //    address payable publicVault = _createPublicVault({
  //      strategist: strategistOne,
  //      delegate: strategistTwo,
  //      epochLength: 14 days
  //    });
  //
  //    _lendToVault(Lender({addr: bob, amountToLend: 150 ether}), payable(publicVault));
  //    (, ILienToken.Stack memory stack) = _commitToLien({
  //      vault: payable(publicVault),
  //      strategist: strategistOne,
  //      strategistPK: strategistOnePK,
  //      tokenContract: tokenContract,
  //      tokenId: tokenId,
  //      lienDetails: blueChipDetails,
  //      amount: 100 ether
  //    });
  //
  //    uint256 collateralId = tokenContract.computeId(tokenId);
  //    vm.warp(block.timestamp + 11 days);
  //
  //    ClearingHouse clearingHouse = ClearingHouse(
  //      COLLATERAL_TOKEN.getClearingHouse(collateralId)
  //    );
  //    deal(address(WETH9), address(clearingHouse), 1000 ether);
  //    _deployBidderConduit(bidder);
  //    vm.startPrank(address(bidderConduits[bidder].conduit));
  //
  //    vm.expectRevert(
  //      abi.encodeWithSelector(
  //        ClearingHouse.InvalidRequest.selector,
  //        ClearingHouse.InvalidRequestReason.NO_AUCTION
  //      )
  //    );
  //    clearingHouse.safeTransferFrom(
  //      address(this),
  //      address(this),
  //      uint256(uint160(address(erc20s[0]))),
  //      1000 ether,
  //      "0x"
  //    );
  //  }

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

    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // after alice deposits 50 ether WETH in publicVault, payable(publicVault)'s share price becomes 1
    _lendToVault(
      Lender({addr: alice, amountToLend: amountIn}),
      payable(publicVault)
    );

    // the borrower borrows 10 ether WETH from publicVault
    (, ILienToken.Stack memory stack1) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether
    });
    uint256 collateralId = tokenContract.computeId(tokenId);

    // the borrower repays for the lien after 9 days, and publicVault's share price becomes bigger than 1
    vm.warp(block.timestamp + 9 days);
    _repay(stack1, 100 ether, address(this));

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
    VaultImplementation(payable(privateVault)).incrementNonce();
    assertEq(
      VaultImplementation(payable(privateVault)).getStrategistNonce(),
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
      payable(privateVault)
    );

    IAstariaRouter.Commitment memory terms = _generateValidTerms({
      vault: payable(privateVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether
    });

    ERC721(tokenContract).setApprovalForAll(address(ASTARIA_ROUTER), true);

    uint256 balanceOfBefore = ERC20(WETH9).balanceOf(address(this));
    (uint256 lienId, ) = ASTARIA_ROUTER.commitToLien(terms);

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
        vaultFee,
        address(WETH9)
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
    address payable publicVault = _createPublicVault({
      strategist: strategistTwo,
      delegate: strategistTwo,
      epochLength: epochLength
    });
  }

  function testInvalidVaultFee() public {
    ASTARIA_ROUTER.file(
      IAstariaRouter.File({
        what: IAstariaRouter.FileType.MaxStrategistFee,
        data: abi.encode(uint256(5e17))
      })
    );
    vm.startPrank(strategistOne);
    //bps
    vm.expectRevert(
      abi.encodeWithSelector(IAstariaRouter.InvalidVaultFee.selector)
    );
    ASTARIA_ROUTER.newPublicVault(
      uint(7 days),
      strategistOne,
      address(WETH9),
      uint256(5e18),
      false,
      new address[](0),
      uint256(0)
    );
    vm.stopPrank();
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
      payable(privateVault)
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
      payable(privateVault)
    );

    // Send the NFT to Collateral contract and receive Collateral token
    ERC721(tokenContract).setApprovalForAll(address(ASTARIA_ROUTER), true);

    // generate valid terms
    uint256 amount = 50 ether; // amount to borrow
    IAstariaRouter.Commitment memory c = _generateValidTerms({
      vault: payable(privateVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: 1,
      lienDetails: standardLienDetails,
      amount: amount
    });

    // Attack starts here
    // The borrower an asset which has no value in the market
    MockERC20 FakeToken = new MockERC20("USDC", "FakeAsset", 18); // this could be any ERC token created by the attacker
    FakeToken.mint(address(this), 500 ether);
    // The borrower creates a private vault with his/her asset
    //    address privateVaultOfBorrower = _createPrivateVault({
    //      strategist: address(this),
    //      delegate: address(0),
    //      token: address(FakeToken)
    //    });

    c.lienRequest.strategy.vault = payable(this);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAstariaRouter.InvalidVault.selector,
        address(this)
      )
    );
    ASTARIA_ROUTER.commitToLien(c);
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
      payable(privateVault)
    );

    IAstariaRouter.Commitment memory terms = _generateValidTerms({
      vault: payable(privateVault),
      strategist: strategistOne,
      strategistPK: strategistRoguePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether
    });

    ERC721(tokenContract).setApprovalForAll(address(ASTARIA_ROUTER), true);

    vm.expectRevert(
      abi.encodeWithSelector(
        IVaultImplementation.InvalidRequest.selector,
        IVaultImplementation.InvalidRequestReason.INVALID_SIGNATURE
      )
    );
    ASTARIA_ROUTER.commitToLien(terms);
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
      payable(privateVault)
    );
  }

  function testCannotBorrowMoreThanMaxAmount() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

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
    details.maxAmount = 10 ether;

    ILienToken.Stack memory stack;
    // borrow 10 eth against the dummy NFT
    (, stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: details,
      amount: 11 ether,
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

    // borrow 10 eth against the dummy NFT
    _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether
    });

    vm.warp(block.timestamp + 15 days);

    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidVaultState.selector,
        IPublicVault.InvalidVaultStates.LIENS_OPEN_FOR_EPOCH_NOT_ZERO
      )
    );
    PublicVault(payable(publicVault)).processEpoch();
  }

  function testCannotExceedMinMaxPublicVaultEpochLength() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidVaultState.selector,
        IPublicVault.InvalidVaultStates.EPOCH_TOO_LOW
      )
    );
    _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 0
    });
    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidVaultState.selector,
        IPublicVault.InvalidVaultStates.EPOCH_TOO_HIGH
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

    ILienToken.Details memory zeroDuration = standardLienDetails;
    zeroDuration.duration = 0;

    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: zeroDuration,
      amount: 10 ether
    });
  }

  function testCannotLienRateZero() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

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

    ILienToken.Details memory zeroRate = standardLienDetails;
    zeroRate.rate = 0;

    ILienToken.Stack memory stack;
    // borrow 10 eth against the dummy NFT
    (, stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: zeroRate,
      amount: 10 ether,
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

    ILienToken.Details memory standardLien = standardLienDetails;
    standardLien.liquidationInitialAsk = 5 ether;
    standardLien.maxAmount = 10 ether;

    // borrow amount over liquidation initial ask
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLien,
      amount: 7.5 ether,
      revertMessage: abi.encodeWithSelector(
        ILienToken.InvalidLienState.selector,
        ILienToken.InvalidLienStates.INVALID_LIQUIDATION_INITIAL_ASK
      )
    });
  }

  function testCannotLiquidationInitialAsk0() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

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

    ILienToken.Details memory zeroInitAsk = standardLienDetails;
    zeroInitAsk.liquidationInitialAsk = 0;

    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: zeroInitAsk,
      amount: 10 ether,
      revertMessage: abi.encodeWithSelector(
        ILienToken.InvalidLienState.selector,
        ILienToken.InvalidLienStates.INVALID_LIQUIDATION_INITIAL_ASK
      )
    });
  }

  function testCannotCommitToLienAfterStrategyDeadline() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );

    uint256 balanceBefore = WETH9.balanceOf(address(this));
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      revertMessage: abi.encodeWithSelector(
        IAstariaRouter.StrategyExpired.selector
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
    address payable publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );

    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether
    });

    uint256 collateralId = tokenContract.computeId(tokenId);

    vm.warp(block.timestamp + 14 days);

    _liquidate(stack);

    _repay(stack, 10 ether, address(this));
  }

  function testRevertMinDurationNotMet() public {
    TestNFT nft = new TestNFT(2);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(1);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    _lendToPrivateVault(
      PrivateLender({
        token: address(WETH9),
        addr: strategistOne,
        amountToLend: 50 ether
      }),
      payable(privateVault)
    );
    standardLienDetails.duration = 30 minutes;
    _commitToLien({
      vault: payable(privateVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      revertMessage: abi.encodeWithSelector(
        ILienToken.InvalidLienState.selector,
        ILienToken.InvalidLienStates.MIN_DURATION_NOT_MET
      )
    });
  }

  //  function testRevertInstantLiquidateAttack() public {
  //    //    IVaultImplementation victimVault = IVaultImplementation(
  //    //      0xE5149D099B992E3dC897F3F4c88824EAC2a6A59D
  //    //    );
  //    //    IAstariaRouter router = IAstariaRouter(
  //    //      0x197Bb6Cd6cC9E9ABBFdaBff23DE7435c51d1B7BE
  //    //    );
  //    //    ICollateralToken ct = ICollateralToken(
  //    //      0x455AD0f677628ed40E7397Fb41818f474e0E5afE
  //    //    );
  //
  //    //    ERC20 weth = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  //    uint256 forkedBlock = 17338696 - 1;
  //    vm.createSelectFork("https://eth.llamarpc.com", forkedBlock);
  //    // `victimVault` will have their WETH stolen
  //
  //    //    uint256 initialVaultBalance = weth.balanceOf(address(victimVault));
  //
  //    // The attacker
  //    // `adversaryKey` is not used in this script, but was used to sign two messages that will be used later.
  //    // One message is for the strategies for a new created vault.
  //    // One message is for fullfilling OpenSea orders.
  //    //    PublicVaultFixed newPV = new PublicVaultFixed();
  //    LienToken lienToken = new LienToken();
  //    (address adversary, uint256 adversaryKey) = makeAddrAndKey("adversary");
  //    deal(
  //      address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), // weth
  //      address(adversary),
  //      0.1 ether
  //    );
  //
  //    //upgrade the router to the new implementation and then try
  //
  //    {
  //      vm.startPrank(address(0x369d7114Ab316Cb37826c0871520BDB2C58D410E));
  //
  //      // make an array of IAstariaRouter.File
  //
  //      //ProxyManager upgrade
  //
  //      ProxyAdmin(0xf28289fAdc53942C8E0175A8a3DaeE79a2593BF9).upgrade(
  //        TransparentUpgradeableProxy(
  //          payable(0x0B77C649A7AD34f1e4c6be68E523B35716a69fB1)
  //        ),
  //        address(lienToken)
  //      );
  //      vm.stopPrank();
  //    }
  //
  //    //    log_bytes(address(targetAddr).code);
  //    // Vaults accept specific NFTs to use as collateral
  //    // The strategist/delegate of the vault signs a message with a merkle proof for each one
  //
  //    // To demonstrate the attack: Acquire one of the NFTs that can be used as collateral
  //    // Use the strategist/delegate signature for this NFT. This signature is generated off-chain
  //    // The signature is valid for any borrower as `borrower == address(0)`
  //    // Taken from: https://etherscan.io/tx/0x6b1e184b606994ab011faf1d4a533fc6fdf9ef1b44a337a273364f588791c262
  //    address originalOwner = address(0x86d3ee9ff0983Bc33b93cc8983371a500f873446);
  //
  //    bytes
  //      memory originalCommitmentsBytes = hex"0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000005af0d9827e0c53e4799bb226655a1de152a425a500000000000000000000000000000000000000000000000000000000000020de0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000646fcf97000000000000000000000000e5149d099b992e3dc897f3f4c88824eac2a6a59d0000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000002a000000000000000000000000000000000000000000000000025bda02e2fc77c30000000000000000000000000000000000000000000000000000000000000001cc2f3afc064e9193a5cd232daa210422418b0544aa93abbd1ace226c7ec84bc7f5c4ff5551165e2bbda8e39dec1faa2bf2f8b4bbf1bd41605632d9a4aff2b38540000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000000010000000000000000000000005af0d9827e0c53e4799bb226655a1de152a425a500000000000000000000000000000000000000000000000000000000000020de000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000025bda02e2fc77c300000000000000000000000000000000000000000000000000000000273dff9c1000000000000000000000000000000000000000000000000000000000023988000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003ac5be0fdfc780006780d074988bff96e3027f75266c43b79f89f94bfc900baf67545cccd501f633000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000118577e12415e0340f6864b50e43c9225030de210e01fdd67ee2ac5a8ea2a5bd0059eb3dda37191d96e2babff0f128a2eb2b42644646cec5e76fa66059cded6a9348767bc9b91cca521a6ffa385c07325e7d0d9f847691810e69ad27b2b8f4236504247026092c83b82a449484cdfcd61008bba99bbce26c0f8136a941744eee5b7dffe19a4b48495a9b220df8cc11413ae6b454cabc9071701ba60c7069d30b6046def5adbe306d1f2263c473640dc7cba16e18af04b68601ee68d48285c09277a5781fb8a04982f3b380ac0de7076e52f5df10906f354aa757a39a262d9ec83e8604396b389fd6ca93d84dc61c03b9dcee29b950de7c85eaa7a9ab5a1515d163bbd4b060e7f077c36080e003443949e59191d7b9515b12a164ab7343e076192b580a16536ab788a9260a7bf66e26c5b299785b7b7d6e4ae0e868922f70693d65387432b59525a23279ddeabbbb0aac40486c37fd08184e33854957580b1f95cecefde8670a951a6d05ed668dc9cc43379bddc912e58114b5a2081cb6c35a1a1883c6d21c65225d6dcd3fd0e45fbe64b423427e4a137d465651a8ca8c4d2d12df0525d3f2ce5df47c0223bfbf7fcd6b8129282fcf7e346105f3ee9f2989d87f7e22d291638325d702ff4ce1fd56493432f137e671d744880708000e22df40a754e77101e9cf2112bf04940471bb7bed02aaa56845f39e8aedea6d2a94a683698a878452ac976573bff58a18a7133d262b9a475d9bf7e2552b9cb715e3362cb508";
  //    IAstariaRouter.Commitment[] memory originalCommitments = abi.decode(
  //      originalCommitmentsBytes,
  //      (IAstariaRouter.Commitment[])
  //    );
  //    IAstariaRouter.Commitment memory originalCommitment = originalCommitments[
  //      0
  //    ];
  //    address borrower = abi
  //      .decode(
  //        originalCommitment.lienRequest.nlrDetails,
  //        (IUniqueValidator.Details)
  //      )
  //      .borrower;
  //    assertEq(borrower, address(0)); // Any borrower is valid
  //
  //    vm.prank(originalOwner);
  //    ERC721(originalCommitment.tokenContract).safeTransferFrom(
  //      originalOwner,
  //      adversary,
  //      originalCommitment.tokenId
  //    );
  //
  //    // The signature has a deadline. In this case, it will expire after 756 seconds from the forked block/time.
  //    // For simplicity of the POC, only one signature will be used to demonstrate the attack.
  //
  //    // This will cap the max stolen assets on this proof, as at least one second has to pass for each attack iteration.
  //    // Note that this POC performs increments on a 1 second basis for demonstration (instead of 12 sec/block increments as on Ethereum)
  //    // Nevertheless if an attacker uses multiple NFTs as collateral in parallel, and/or obtains fresh signatures,
  //    //   the attack can continue until all funds are stolen.
  //    uint256 timeToDeadline = originalCommitment.lienRequest.strategy.deadline -
  //      block.timestamp;
  //    assertEq(timeToDeadline, 756);
  //
  //    // PERFORM THE ATTACK 750 times, each time 0.29 WETH will be stolen
  //    uint256 repeatAttack = 1;
  //    //    address token = originalCommitment.tokenContract;
  //    //    uint256 tokenId = originalCommitment.tokenId;
  //
  //    ConsiderationInterface consideration = ICollateralToken(
  //      0x455AD0f677628ed40E7397Fb41818f474e0E5afE
  //    ).SEAPORT();
  //    {
  //      bytes32 conduitKey = ICollateralToken(
  //        0x455AD0f677628ed40E7397Fb41818f474e0E5afE
  //      ).getConduitKey();
  //
  //      vm.startPrank(adversary);
  //
  //      ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2).approve(
  //        ICollateralToken(0x455AD0f677628ed40E7397Fb41818f474e0E5afE)
  //          .getConduit(),
  //        type(uint256).max
  //      );
  //    } // Aprove funds to be used to fullfill OpenSea orders
  //    {
  //      // Create a new vault with liens that will expiry after 1 second
  //      IVaultImplementation pocVault = IVaultImplementation(
  //        IAstariaRouter(0x197Bb6Cd6cC9E9ABBFdaBff23DE7435c51d1B7BE)
  //          .newPublicVault(
  //            14 days,
  //            adversary,
  //            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), // weth
  //            0,
  //            false,
  //            new address[](0),
  //            uint256(0)
  //          )
  //      );
  //
  //      // Commitment for a lien of `amount = 0` that will expire after 1 second, and a `liquidationInitialAsk` value slightly bigger than the original `amount`
  //      // This "empty" commitment is used to trick the system into liquidating the asset ASAP, paying the minimum interest
  //      //      IAstariaRouter.Commitment memory emptyCommitment = abi.decode(
  //      //        hex"00000000000000000000000000000000000000000000000000000000000000200000000000000000000000005af0d9827e0c53e4799bb226655a1de152a425a500000000000000000000000000000000000000000000000000000000000020de0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000647cfba30000000000000000000000005da5d251540c6723142b6a7df74ab4e346ffecd50000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000002a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001b81b74b124a06a188d9d00598159df1774492258e901f95e464fdf0033cb9b18c6a7a12c49359ccdc4f4be8fb2d1482797be75168ff797e5c6965f6cc43c6253f0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000000010000000000000000000000005af0d9827e0c53e4799bb226655a1de152a425a500000000000000000000000000000000000000000000000000000000000020de0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002b5e3af16b188000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000026b650cf3e0e7c3010cbb634d0a52d8ebf2f581eef3c722b9cfb32990e35a6bd4be137cbe04a463900000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000000",
  //      //        (IAstariaRouter.Commitment)
  //      //      );
  //
  //      // Perform the attack
  //      // 1. Transfer the NFT to the CollateralToken contract
  //      // 2. Create an "empty" commitment on the newly created vault (amount is zero and will default after one second)
  //      // 3. Add the commitment from the victim vault (WETH is transfered to the adversary)
  //      // 4. Wait 1 second for the loan to default
  //      // 5. Create an auction for the defaulted loan (via `liquidate()`), with the position `0` as it will bear the least interest
  //      // 6. Fullfill the OpenSea order on the same block
  //      // 7. Repeat
  //      // Liquidation fees are higher than the interest rate, so the `adversary` makes profit on each attack (around 0.29 WETH in this case)
  //      // As the loan is liquidated by the `adversary`, the NFT is recovered
  //      ILienToken.Stack memory stack;
  //      for (uint256 i; i < repeatAttack; i++) {
  //        ERC721(originalCommitment.tokenContract).safeTransferFrom(
  //          adversary,
  //          address(0x455AD0f677628ed40E7397Fb41818f474e0E5afE), //CT
  //          originalCommitment.tokenId
  //        );
  //
  //        vm.expectRevert(
  //          abi.encodeWithSelector(
  //            ILienToken.InvalidLienState.selector,
  //            ILienToken.InvalidLienStates.AMOUNT_ZERO
  //          )
  //        );
  //        //commit to empty commitment
  //        (, stack) = pocVault.commitToLien(
  //          abi.decode(
  //            hex"00000000000000000000000000000000000000000000000000000000000000200000000000000000000000005af0d9827e0c53e4799bb226655a1de152a425a500000000000000000000000000000000000000000000000000000000000020de0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000647cfba30000000000000000000000005da5d251540c6723142b6a7df74ab4e346ffecd50000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000002a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001b81b74b124a06a188d9d00598159df1774492258e901f95e464fdf0033cb9b18c6a7a12c49359ccdc4f4be8fb2d1482797be75168ff797e5c6965f6cc43c6253f0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000000010000000000000000000000005af0d9827e0c53e4799bb226655a1de152a425a500000000000000000000000000000000000000000000000000000000000020de0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002b5e3af16b188000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000026b650cf3e0e7c3010cbb634d0a52d8ebf2f581eef3c722b9cfb32990e35a6bd4be137cbe04a463900000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000000",
  //            (IAstariaRouter.Commitment)
  //          )
  //        );
  //
  //        //      since we block the rouge commit the rest doesnt run
  //        //
  //        //      originalCommitment.lienRequest.stack = stack;
  //        //      (, stack) = victimVault.commitToLien(originalCommitment);
  //        //      //block 1
  //        //      vm.warp(block.timestamp + 1);
  //        //      //amount != 0
  //        //      //block 2
  //        //      uint8 position = 0;
  //        //      OrderParameters memory listedOrder = router.liquidate(stack, position);
  //        //
  //        //      // Signed by the adversary to fulfill OpenSea orders. Can be reused.
  //        //      bytes
  //        //        memory adversaryFullfillSignature = hex"2adb5898f07650db8b646da138c5a2964c450e8cd381c49c79c5bf51e3657bd067b3288c62a36a6e0da6f025c1e69e4484092239fb2981d6bfb8ef4b2b369b1c1b";
  //        //
  //        //      consideration.fulfillAdvancedOrder(
  //        //        AdvancedOrder(listedOrder, 1, 1, adversaryFullfillSignature, ""),
  //        //        new CriteriaResolver[](0),
  //        //        conduitKey,
  //        //        address(0)
  //        //      );
  //      }
  //    }
  //
  //    //    uint256 amountStolenPerAttack = 0.2926357631301847 ether;
  //    //    uint256 amountStolen = amountStolenPerAttack * repeatAttack;
  //    //    assertGt(amountStolen, 136 ether); // 136 WETH will be stolen. (The total funds can be stolen with more NFTs and/or signatures)
  //    //
  //    //    // Funds are stolen from the `victimVault`
  //    //    assertEq(
  //    //      weth.balanceOf(address(victimVault)),
  //    //      initialVaultBalance - amountStolen
  //    //    );
  //    //
  //    //    // Funds are added to the `adversary`
  //    //    assertGt(weth.balanceOf(adversary), amountStolen);
  //    //
  //    //    // The `adversary` still owns the NFT
  //    //    address ownerOfNFT = ERC721(originalCommitment.tokenContract).ownerOf(
  //    //      originalCommitment.tokenId
  //    //    );
  //    //    assertEq(ownerOfNFT, adversary);
  //  }

  function testCannotSelfLiquidateBeforeExpiration() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

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

    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether
    });

    _liquidate(
      stack,
      abi.encodeWithSelector(
        IAstariaRouter.InvalidLienState.selector,
        IAstariaRouter.LienState.HEALTHY
      )
    );
  }
}
