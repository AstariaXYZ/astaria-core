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
import {ERC20} from "solmate/tokens/ERC20.sol";

import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {VaultImplementation} from "../VaultImplementation.sol";
import {PublicVault} from "../PublicVault.sol";
import {Receiver, TransferProxy} from "../TransferProxy.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";
import {OrderParameters} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {
  Create2ClonesWithImmutableArgs
} from "create2-clones-with-immutable-args/Create2ClonesWithImmutableArgs.sol";

contract LienTokenScenarioTest is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeCastLib for uint256;

  // Scenario 1: commitToLien -> makePayment
  function testScenario1() public {
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

    // lend 10 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 10 ether}),
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

    uint256 collateralId = tokenContract.computeId(tokenId);

    vm.warp(block.timestamp + 9 days);

    _repay(stack, 50 ether, address(this));

    // all assetions for this test are made in the TestHelpers
  }

  // Scenario 2: commitToLien -> liquidate w/o WithdrawProxy -> overbid
  function testScenario2() public {
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

    uint256 vaultShares = PublicVault(payable(publicVault)).totalSupply();

    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: ILienToken.Details({
        maxAmount: 50 ether,
        rate: (uint256(1e16) * 150) / (365 days),
        duration: 10 days,
        maxPotentialDebt: 0 ether,
        liquidationInitialAsk: 100 ether
      }),
      amount: 10 ether
    });

    uint256 collateralId = tokenContract.computeId(tokenId);

    // verify the strategist has no shares minted
    assertEq(
      PublicVault(payable(publicVault)).balanceOf(strategistOne),
      0,
      "Strategist has incorrect share balance"
    );

    // verify that the borrower has the CollateralToken
    assertEq(
      COLLATERAL_TOKEN.ownerOf(collateralId),
      address(this),
      "CollateralToken not minted to borrower"
    );

    vm.warp(block.timestamp + 10 days);
    OrderParameters memory listedOrder = _liquidate(stack);

    // validate the slope is reset at liquidation initialization
    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope divergent"
    );

    uint256 amountOwed = LIEN_TOKEN.getOwed(stack);

    // calculate strategist reward shares
    uint256 strategistSharesOwed = PublicVault(payable(publicVault))
      .convertToShares((amountOwed - 10 ether).mulDivDown(1e17, 1e18));
    _bid(Bidder(bidder, bidderPK), listedOrder, 20 ether, stack);
    skip(3 days);

    // validate that strategist fees were minted
    assertEq(
      PublicVault(payable(publicVault)).balanceOf(strategistOne),
      strategistSharesOwed,
      "Strategist fee incorrect"
    );

    // assert that the bidder received the NFT
    assertEq(nft.ownerOf(0), bidder, "Bidder did not receive nft after bid");

    // ensure that the CollateralToken has been burned
    vm.expectRevert(bytes("NOT_MINTED"));
    COLLATERAL_TOKEN.ownerOf(collateralId);

    // validate that the yIntercept matches the WETH balance
    assertEq(
      WETH9.balanceOf(publicVault),
      PublicVault(payable(publicVault)).getYIntercept(),
      "PublicVault yIntercept divergent from WETH balance"
    );

    // Validate that the yIntercept matches teh amoutnOwed
    assertEq(
      PublicVault(payable(publicVault)).getYIntercept(),
      amountOwed,
      "PublicVault yIntercept divergent"
    );

    // validate that the slope is reset after payment
    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope divergent"
    );
  }

  // Scenario 3: commitToLien -> liquidate w/o WithdrawProxy -> underbid
  function testScenario3() public {
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

    uint256 vaultShares = PublicVault(payable(publicVault)).totalSupply();

    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: ILienToken.Details({
        maxAmount: 50 ether,
        rate: (uint256(1e16) * 150) / (365 days),
        duration: 10 days,
        maxPotentialDebt: 0 ether,
        liquidationInitialAsk: 100 ether
      }),
      amount: 10 ether
    });

    uint256 collateralId = tokenContract.computeId(tokenId);

    // verify the strategist has no shares minted
    assertEq(
      PublicVault(payable(publicVault)).balanceOf(strategistOne),
      0,
      "Strategist has incorrect share balance"
    );

    // verify that the borrower has the CollateralToken
    assertEq(
      COLLATERAL_TOKEN.ownerOf(collateralId),
      address(this),
      "CollateralToken not minted to borrower"
    );

    vm.warp(block.timestamp + 10 days);
    OrderParameters memory listedOrder = _liquidate(stack);

    // validate the slope is reset at liquidation initialization
    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope divergent"
    );

    uint256 amountOwed = LIEN_TOKEN.getOwed(stack);

    uint256 yInterceptBefore = PublicVault(payable(publicVault))
      .getYIntercept();

    // underbid
    uint256 executionPrice = _bid(
      Bidder(bidder, bidderPK),
      listedOrder,
      5 ether,
      stack
    );
    skip(3 days);

    // uint256 liquidatorFee = ASTARIA_ROUTER.getLiquidatorFee(executionPrice);

    uint256 decreaseInYintercept = amountOwed -
      (executionPrice - ASTARIA_ROUTER.getLiquidatorFee(executionPrice));

    // validate that strategist fees were not minted
    assertEq(
      PublicVault(payable(publicVault)).balanceOf(strategistOne),
      0,
      "Strategist fee incorrect"
    );

    // assert that the bidder received the NFT
    assertEq(nft.ownerOf(0), bidder, "Bidder did not receive nft after bid");

    // ensure that the CollateralToken has been burned
    vm.expectRevert(bytes("NOT_MINTED"));
    COLLATERAL_TOKEN.ownerOf(collateralId);

    // validate that the yIntercept matches the WETH balance
    assertEq(
      WETH9.balanceOf(publicVault),
      PublicVault(payable(publicVault)).getYIntercept(),
      "PublicVault yIntercept divergent from WETH balance"
    );

    // Validate that the yIntercept matches the amountOwed
    assertEq(
      PublicVault(payable(publicVault)).getYIntercept(),
      yInterceptBefore - decreaseInYintercept,
      "PublicVault yIntercept divergent"
    );

    // validate that the slope is reset after payment
    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope divergent"
    );
  }

  // Scenario 4: commitToLien -> liquidate w/o WithdrawProxy -> no bid
  function testScenario4() public {
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

    uint256 vaultShares = PublicVault(payable(publicVault)).totalSupply();

    // borrow 10 eth against the dummy NFT
    (, ILienToken.Stack memory stack) = _commitToLien({
      vault: payable(publicVault),
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: ILienToken.Details({
        maxAmount: 50 ether,
        rate: (uint256(1e16) * 150) / (365 days),
        duration: 10 days,
        maxPotentialDebt: 0 ether,
        liquidationInitialAsk: 100 ether
      }),
      amount: 10 ether
    });

    uint256 collateralId = tokenContract.computeId(tokenId);

    // verify the strategist has no shares minted
    assertEq(
      PublicVault(payable(publicVault)).balanceOf(strategistOne),
      0,
      "Strategist has incorrect share balance"
    );

    // verify that the borrower has the CollateralToken
    assertEq(
      COLLATERAL_TOKEN.ownerOf(collateralId),
      address(this),
      "CollateralToken not minted to borrower"
    );

    vm.warp(block.timestamp + 10 days);
    OrderParameters memory listedOrder = _liquidate(stack);

    // validate the slope is reset at liquidation initialization
    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope divergent"
    );

    uint256 amountOwed = LIEN_TOKEN.getOwed(stack);

    uint256 yInterceptBefore = PublicVault(payable(publicVault))
      .getYIntercept();

    // nobid
    // uint256 executionPrice = _bid(Bidder(bidder, bidderPK), listedOrder, 5 ether, stack);
    skip(3 days);

    // uint256 liquidatorFee = ASTARIA_ROUTER.getLiquidatorFee(executionPrice);
    COLLATERAL_TOKEN.liquidatorNFTClaim(stack, listedOrder, 0);

    uint256 decreaseInYintercept = amountOwed;

    // validate that strategist fees were not minted
    assertEq(
      PublicVault(payable(publicVault)).balanceOf(strategistOne),
      0,
      "Strategist fee incorrect"
    );

    // assert that the bidder received the NFT
    assertEq(
      nft.ownerOf(0),
      address(this),
      "liquidator did not receive nft after auction failure"
    );

    // ensure that the CollateralToken has been burned
    vm.expectRevert(bytes("NOT_MINTED"));
    COLLATERAL_TOKEN.ownerOf(collateralId);

    // validate that the yIntercept matches the WETH balance
    assertEq(
      WETH9.balanceOf(publicVault),
      PublicVault(payable(publicVault)).getYIntercept(),
      "PublicVault yIntercept divergent from WETH balance"
    );

    // Validate that the yIntercept matches yInterceptBefore minus the decreaseInYintercept
    assertEq(
      PublicVault(payable(publicVault)).getYIntercept(),
      yInterceptBefore - decreaseInYintercept,
      "PublicVault yIntercept divergent"
    );

    // validate that the slope is reset after payment
    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope divergent"
    );
  }

  // Scenario 5: commitToLien -> liquidate w/ WithdrawProxy -> overbid
  function testScenario5() public {
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

    uint256 vaultShares = PublicVault(payable(publicVault)).totalSupply();

    // borrow 10 eth against the dummy NFT
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
      amount: 10 ether
    });

    uint256 collateralId = tokenContract.computeId(tokenId);

    // verify the strategist has no shares minted
    assertEq(
      PublicVault(payable(publicVault)).balanceOf(strategistOne),
      0,
      "Strategist has incorrect share balance"
    );

    // verify that the borrower has the CollateralToken
    assertEq(
      COLLATERAL_TOKEN.ownerOf(collateralId),
      address(this),
      "CollateralToken not minted to borrower"
    );

    assertEq(
      address(PublicVault(payable(publicVault)).getWithdrawProxy(0)),
      address(0),
      "WithdrawProxy already deployed for epoch 0"
    );

    vm.warp(block.timestamp + 14 days);
    OrderParameters memory listedOrder = _liquidate(stack);

    assertTrue(
      address(PublicVault(payable(publicVault)).getWithdrawProxy(0)) !=
        address(0),
      "WithdrawProxy not deployed"
    );

    // validate the slope is reset at liquidation initialization
    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope divergent"
    );

    uint256 amountOwed = LIEN_TOKEN.getOwed(stack);

    // calculate strategist reward shares
    // uint256 strategistSharesOwed = PublicVault(payable(publicVault)).convertToShares((amountOwed - 10 ether).mulDivDown(1e17, 1e18));
    uint256 expectedFinalAuctionEnd = block.timestamp + 3 days;
    _bid(Bidder(bidder, bidderPK), listedOrder, 20 ether, stack);
    vm.warp(expectedFinalAuctionEnd);

    IWithdrawProxy withdrawProxy = PublicVault(payable(publicVault))
      .getWithdrawProxy(0);
    {
      (
        uint256 withdrawRatio,
        uint256 expected,
        uint40 finalAuctionEnd,
        uint256 withdrawReserveReceived
      ) = withdrawProxy.getState();

      assertEq(withdrawRatio, 0, "withdrawRatio incorrect");

      assertEq(expected, amountOwed, "Expected value incorrect");

      assertEq(
        finalAuctionEnd,
        expectedFinalAuctionEnd,
        "finalAuctionEnd not as expected"
      );

      assertEq(withdrawReserveReceived, 0, "withdrawReserveReceived incorrect");
    }

    // assert that the bidder received the NFT
    assertEq(nft.ownerOf(0), bidder, "Bidder did not receive nft after bid");

    // ensure that the CollateralToken has been burned
    vm.expectRevert(bytes("NOT_MINTED"));
    COLLATERAL_TOKEN.ownerOf(collateralId);

    // validate that the yIntercept matches the WETH balance
    assertEq(
      WETH9.balanceOf(
        address(PublicVault(payable(publicVault)).getWithdrawProxy(0))
      ),
      amountOwed,
      "WithdrawProxy expected balance divergent from WETH balance"
    );

    // Validate that the yIntercept matches teh amoutnOwed
    assertEq(
      PublicVault(payable(publicVault)).getYIntercept(),
      amountOwed,
      "PublicVault yIntercept divergent"
    );

    // validate that the slope is reset after payment
    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope divergent"
    );

    PublicVault(payable(publicVault)).processEpoch();
    withdrawProxy.claim();

    assertEq(
      WETH9.balanceOf(publicVault),
      PublicVault(payable(publicVault)).getYIntercept(),
      "PublicVault yIntercept divergent from WETH balance"
    );

    assertTrue(
      WETH9.balanceOf(publicVault) != 0,
      "PublicVault balance is incorrect"
    );

    {
      (, , uint40 finalAuctionEnd, ) = withdrawProxy.getState();

      assertEq(finalAuctionEnd, 0, "finalAuctionEnd not reset after claim");
    }
  }

  // Scenario 6: commitToLien -> liquidate w/ WithdrawProxy -> underbid
  function testScenario6() public {
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

    PublicVault(payable(publicVault)).totalSupply();

    // borrow 10 eth against the dummy NFT
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
      amount: 10 ether
    });

    uint256 collateralId = tokenContract.computeId(tokenId);

    // verify the strategist has no shares minted
    assertEq(
      PublicVault(payable(publicVault)).balanceOf(strategistOne),
      0,
      "Strategist has incorrect share balance"
    );

    // verify that the borrower has the CollateralToken
    assertEq(
      COLLATERAL_TOKEN.ownerOf(collateralId),
      address(this),
      "CollateralToken not minted to borrower"
    );

    vm.warp(block.timestamp + 14 days);
    OrderParameters memory listedOrder = _liquidate(stack);

    // validate the slope is reset at liquidation initialization
    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope divergent"
    );

    uint256 amountOwed = LIEN_TOKEN.getOwed(stack);

    uint256 expectedFinalAuctionEnd = block.timestamp + 3 days;
    // underbid
    uint256 executionPrice = _bid(
      Bidder(bidder, bidderPK),
      listedOrder,
      5 ether,
      stack
    );
    vm.warp(expectedFinalAuctionEnd);

    uint256 liquidatorFee = ASTARIA_ROUTER.getLiquidatorFee(executionPrice);

    uint256 decreaseInYintercept = amountOwed -
      (executionPrice - liquidatorFee);

    IWithdrawProxy withdrawProxy = PublicVault(payable(publicVault))
      .getWithdrawProxy(0);
    {
      (
        uint256 withdrawRatio,
        uint256 expected,
        uint40 finalAuctionEnd,
        uint256 withdrawReserveReceived
      ) = withdrawProxy.getState();

      assertEq(withdrawRatio, 0, "withdrawRatio incorrect");

      assertEq(expected, amountOwed, "Expected value incorrect");

      assertEq(
        finalAuctionEnd,
        expectedFinalAuctionEnd,
        "finalAuctionEnd not as expected"
      );

      assertEq(withdrawReserveReceived, 0, "withdrawReserveReceived incorrect");
    }
    // validate that strategist fees were not minted
    assertEq(
      PublicVault(payable(publicVault)).balanceOf(strategistOne),
      0,
      "Strategist fee incorrect"
    );

    // assert that the bidder received the NFT
    assertEq(nft.ownerOf(0), bidder, "Bidder did not receive nft after bid");

    // ensure that the CollateralToken has been burned
    vm.expectRevert(bytes("NOT_MINTED"));
    COLLATERAL_TOKEN.ownerOf(collateralId);

    // validate that the yIntercept matches the WETH balance
    assertEq(
      WETH9.balanceOf(address(withdrawProxy)),
      amountOwed - decreaseInYintercept,
      "WithdrawProxy expected balance divergent from WETH balance"
    );

    // Validate that the yIntercept matches teh amoutnOwed
    assertEq(
      PublicVault(payable(publicVault)).getYIntercept(),
      amountOwed,
      "PublicVault yIntercept divergent"
    );

    // validate that the slope is reset after payment
    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope divergent"
    );

    PublicVault(payable(publicVault)).processEpoch();
    withdrawProxy.claim();

    assertEq(
      WETH9.balanceOf(publicVault),
      PublicVault(payable(publicVault)).getYIntercept(),
      "PublicVault yIntercept divergent from WETH balance"
    );

    assertTrue(
      WETH9.balanceOf(publicVault) != 0,
      "PublicVault balance is incorrect"
    );

    {
      (, , uint40 finalAuctionEnd, ) = withdrawProxy.getState();

      assertEq(finalAuctionEnd, 0, "finalAuctionEnd not reset after claim");
    }
  }

  // Scenario 7: commitToLien -> liquidate w/ WithdrawProxy -> no bid
  function testScenario7() public {
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

    PublicVault(payable(publicVault)).totalSupply();

    // borrow 10 eth against the dummy NFT
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
      amount: 10 ether
    });

    uint256 collateralId = tokenContract.computeId(tokenId);

    // verify the strategist has no shares minted
    assertEq(
      PublicVault(payable(publicVault)).balanceOf(strategistOne),
      0,
      "Strategist has incorrect share balance"
    );

    // verify that the borrower has the CollateralToken
    assertEq(
      COLLATERAL_TOKEN.ownerOf(collateralId),
      address(this),
      "CollateralToken not minted to borrower"
    );

    vm.warp(block.timestamp + 14 days);
    OrderParameters memory listedOrder = _liquidate(stack);

    // validate the slope is reset at liquidation initialization
    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope divergent"
    );

    uint256 amountOwed = LIEN_TOKEN.getOwed(stack);

    uint256 expectedFinalAuctionEnd = block.timestamp + 3 days;

    vm.warp(expectedFinalAuctionEnd);
    // no bid
    COLLATERAL_TOKEN.liquidatorNFTClaim(stack, listedOrder, 0);

    uint256 decreaseInYintercept = amountOwed;

    IWithdrawProxy withdrawProxy = PublicVault(payable(publicVault))
      .getWithdrawProxy(0);
    {
      (
        uint256 withdrawRatio,
        uint256 expected,
        uint40 finalAuctionEnd,
        uint256 withdrawReserveReceived
      ) = withdrawProxy.getState();

      assertEq(withdrawRatio, 0, "withdrawRatio incorrect");

      assertEq(expected, amountOwed, "Expected value incorrect");

      assertEq(
        finalAuctionEnd,
        expectedFinalAuctionEnd,
        "finalAuctionEnd not as expected"
      );

      assertEq(
        listedOrder.endTime,
        finalAuctionEnd,
        "finalAuctionEnd and auction endTime mismatched"
      );

      assertEq(withdrawReserveReceived, 0, "withdrawReserveReceived incorrect");
    }
    // validate that strategist fees were not minted
    assertEq(
      PublicVault(payable(publicVault)).balanceOf(strategistOne),
      0,
      "Strategist fee incorrect"
    );

    // assert that the liquidator received the NFT
    assertEq(
      nft.ownerOf(0),
      address(this),
      "LIquidator did not receive nft after bid"
    );

    // ensure that the CollateralToken has been burned
    vm.expectRevert(bytes("NOT_MINTED"));
    COLLATERAL_TOKEN.ownerOf(collateralId);

    // validate that the yIntercept matches the WETH balance
    assertEq(
      WETH9.balanceOf(address(withdrawProxy)),
      amountOwed - decreaseInYintercept,
      "WithdrawProxy expected balance divergent from WETH balance"
    );

    // Validate that the yIntercept matches teh amoutnOwed
    assertEq(
      PublicVault(payable(publicVault)).getYIntercept(),
      amountOwed,
      "PublicVault yIntercept divergent"
    );

    // validate that the slope is reset after payment
    assertEq(
      PublicVault(payable(publicVault)).getSlope(),
      0,
      "PublicVault slope divergent"
    );

    PublicVault(payable(publicVault)).processEpoch();
    withdrawProxy.claim();

    assertEq(
      WETH9.balanceOf(publicVault),
      PublicVault(payable(publicVault)).getYIntercept(),
      "PublicVault yIntercept divergent from WETH balance"
    );

    assertTrue(
      WETH9.balanceOf(publicVault) == 0,
      "PublicVault balance is incorrect"
    );

    {
      (, , uint40 finalAuctionEnd, ) = withdrawProxy.getState();

      assertEq(finalAuctionEnd, 0, "finalAuctionEnd not reset after claim");
    }
  }
}
