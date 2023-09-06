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

  function testCannotLeaveWithdrawReserveUnderCollateralized() public {
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
    _signalWithdraw(bob, payable(publicVault));

    skip(PublicVault(payable(publicVault)).timeToEpochEnd());

    PublicVault(publicVault).processEpoch();
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: blueChipDetails,
      amount: 50 ether,
      revertMessage: abi.encodeWithSelector(
        IPublicVault.InvalidVaultState.selector,
        IPublicVault.InvalidVaultStates.WITHDRAW_RESERVE_UNDER_COLLATERALIZED
      )
    });
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

  function testCannotLiquidateTwice() public {
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

    skip(15 days);
    OrderParameters memory listedOrder = _liquidate(stack);

    listedOrder = _liquidate(
      stack,
      abi.encodeWithSelector(
        ILienToken.InvalidLienState.selector,
        ILienToken.InvalidLienStates.COLLATERAL_LIQUIDATED
      )
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

  function testCannotSettleAuctionWithInvalidStack() public {
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

    OrderParameters memory listedOrder = _liquidate(stack);
    stack.lien.collateralId = uint256(5);
    _bid(
      Bidder(bidder, bidderPK),
      listedOrder,
      100 ether,
      stack,
      abi.encodeWithSelector(ICollateralToken.InvalidOrder.selector)
    );
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

    uint256 balanceOfBefore = ERC20(address(WETH9)).balanceOf(address(this));
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
    address payable publicVault = _createPublicVault({
      strategist: strategistTwo,
      delegate: strategistTwo,
      epochLength: epochLength
    });
  }

  function testCannotBorrowFromShutdownVault() public {
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
    vm.startPrank(strategistOne);
    VaultImplementation(payable(privateVault)).shutdown();
    vm.stopPrank();
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(privateVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      revertMessage: abi.encodeWithSelector(
        IAstariaRouter.InvalidVaultState.selector,
        IAstariaRouter.VaultState.SHUTDOWN
      )
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

  function testCannotMismatchMinMaxEpochLength() public {
    {
      vm.expectRevert(
        abi.encodeWithSelector(IAstariaRouter.InvalidFileData.selector)
      );
      ASTARIA_ROUTER.file(
        IAstariaRouter.File({
          what: IAstariaRouter.FileType.MinEpochLength,
          data: abi.encode(uint256(46 days))
        })
      );
    }
    {
      vm.expectRevert(
        abi.encodeWithSelector(IAstariaRouter.InvalidFileData.selector)
      );
      ASTARIA_ROUTER.file(
        IAstariaRouter.File({
          what: IAstariaRouter.FileType.MaxEpochLength,
          data: abi.encode(uint256(6 days))
        })
      );
    }
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

  // testDonationWithUnderbid: commitToLien -> liquidate w/ WithdrawProxy -> underbid
  // instead of depositing, there is a donation
  // we should revert on a newloan that exceeds the yIntercept
  function testDonationWithUnderbid() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    // create a PublicVault with a 14-day epoch
    address publicVault = _createPublicVault(
      strategistOne,
      strategistTwo,
      14 days,
      1e17
    );

    // lend 10 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 10 ether}),
      payable(publicVault)
    );

    // Donated a fraction of assets into the vault
    WETH9.deposit{value: 20 ether}();
    WETH9.transfer(publicVault, 20 ether);

    PublicVault(payable(publicVault)).totalSupply();

    // borrow 20 eth against the dummy NFT
    // will revert because the loan amount > yIntercept of the PublicVault
    // if we do not disallow new loans of the donated amount, and the loan is liquated to a withdrawProxy, the WithdrawProxy.claim() can possibly underflow as well as the difference in the WithdrawProxy.expected will be reduced from the yIntercept
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: ILienToken.Details({
        maxAmount: 50 ether,
        rate: (uint256(1e16) * 150) / (365 days),
        duration: 14 days,
        maxPotentialDebt: 0 ether,
        liquidationInitialAsk: 100 ether
      }),
      amount: 20 ether,
      revertMessage: abi.encodeWithSelector(
        IPublicVault.InvalidVaultState.selector,
        IPublicVault.InvalidVaultStates.LOAN_GREATER_THAN_VIRTUAL_BALANCE
      )
    });
  }
}
