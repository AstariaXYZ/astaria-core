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

import {
  IERC1155Receiver
} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

import {ERC721} from "gpl/ERC721.sol";
import {IV3PositionManager} from "core/interfaces/IV3PositionManager.sol";

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
import {ClaimFees} from "../actions/UNIV3/ClaimFees.sol";
import {ValidatorAsset} from "core/ValidatorAsset.sol";

contract ForkedTesting is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;

  address constant V3_NFT_ADDRESS =
    address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88); // todo get real nft address

  function _hijackNFT(address nft, uint256 tokenId) internal {
    address holder = ERC721(nft).ownerOf(tokenId);
    vm.startPrank(holder);
    ERC721(nft).transferFrom(holder, address(this), tokenId);
    vm.stopPrank();
  }

  //run with blocknumber 15919113
  //matic weth pair
  function testClaimFeesAgainstV3Liquidity() public {
    address tokenContract = V3_NFT_ADDRESS;
    // fork mainnet on this block 15934974
    uint256 tokenId = uint256(349999);
    _hijackNFT(tokenContract, tokenId);

    ClaimFees claimFees = new ClaimFees(V3_NFT_ADDRESS);

    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    _lendToVault(
      Lender({addr: strategistOne, amountToLend: 50 ether}),
      privateVault
    );
    address[] memory assets;
    {
      (
        ,
        ,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        ,
        ,
        uint128 tokensOwed0,
        uint128 tokensOwed1
      ) = IV3PositionManager(tokenContract).positions(tokenId);

      assets = new address[](2);
      assets[0] = token0;
      assets[1] = token1;
      _commitToV3Lien({
        params: V3LienParams({
          assets: assets,
          fee: fee,
          borrower: address(0),
          tickLower: tickLower,
          tickUpper: tickUpper,
          liquidity: liquidity,
          strategist: strategistOne,
          strategistPK: strategistOnePK,
          tokenContract: tokenContract,
          amount0Min: tokensOwed0,
          amount1Min: tokensOwed1,
          tokenId: tokenId,
          details: standardLienDetails
        }),
        vault: privateVault,
        amount: 10 ether,
        stack: new ILienToken.Stack[](0),
        isFirstLien: true
      });
    }

    COLLATERAL_TOKEN.file(
      ICollateralToken.File(
        ICollateralToken.FileType.FlashEnabled,
        abi.encode(V3_NFT_ADDRESS, true)
      )
    );

    uint256 balance0Before = IERC20(assets[0]).balanceOf(address(this));
    uint256 balance1Before = IERC20(assets[1]).balanceOf(address(this));

    COLLATERAL_TOKEN.flashAction(
      IFlashAction(claimFees),
      tokenContract.computeId(tokenId),
      abi.encode(address(this))
    );
    assert(IERC20(assets[0]).balanceOf(address(this)) > balance0Before);
    assert(IERC20(assets[1]).balanceOf(address(this)) > balance1Before);
  }

  //    function testSeaportAuction() public {
  //      TestNFT loanTest = new TestNFT();
  //      address tokenContract = address(loanTest);
  //      uint256 tokenId = uint256(1);
  //
  //      uint256 listingPrice = uint256(5 ether);
  //      uint256 listingFee = ((listingPrice * 2e5) / 100e5);
  //      uint256 minListingPrice = listingPrice + (listingFee * 2);
  //
  //      OfferItem[] memory offer = new OfferItem[](1);
  //      offer[0] = OfferItem(
  //        ItemType.ERC721,
  //        tokenContract,
  //        tokenId,
  //        minListingPrice,
  //        minListingPrice
  //      );
  //      ConsiderationItem[] memory considerationItems = new ConsiderationItem[](3);
  //
  //      //setup validator asset
  //      ValidatorAsset validator = new ValidatorAsset(address(COLLATERAL_TOKEN));
  //
  //      //ItemType itemType;
  //      //    address token;
  //      //    uint256 identifierOrCriteria;
  //      //    uint256 startAmount;
  //      //    uint256 endAmount;
  //      //    address payable recipient;
  //
  //      //TODO: compute listing fee for opensea
  //      //compute royalty fee for the asset if it exists
  //      //validator
  //      considerationItems[0] = ConsiderationItem(
  //        ItemType.ERC20,
  //        address(WETH9),
  //        uint256(0),
  //        listingFee,
  //        listingFee,
  //        payable(address(0x8De9C5A032463C561423387a9648c5C7BCC5BC90)) //opensea fees
  //      );
  //      considerationItems[1] = ConsiderationItem(
  //        ItemType.ERC20,
  //        address(WETH9),
  //        uint256(0),
  //        minListingPrice,
  //        minListingPrice,
  //        payable(address(COLLATERAL_TOKEN))
  //      );
  //      considerationItems[1] = ConsiderationItem(
  //        ItemType.ERC1155,
  //        address(validator),
  //        collateralId,
  //        minListingPrice,
  //        minListingPrice,
  //        payable(address(COLLATERAL_TOKEN))
  //      );
  //
  //      emit Dummy();
  //
  //      // OrderParameters(
  //      //         offerer,
  //      //         address(0),
  //      //         offerItems,
  //      //         considerationItems,
  //      //         orderType,
  //      //         block.timestamp,
  //      //         block.timestamp + 1,
  //      //         bytes32(0),
  //      //         globalSalt++,
  //      //         bytes32(0),
  //      //         considerationItems.length
  //      //     );
  //
  //      // old andrew
  //      //     OrderParameters({
  //      //             offerer: address(COLLATERAL_TOKEN),
  //      //             zone: address(COLLATERAL_TOKEN), // 0x20
  //      //             offer: offer,
  //      //             consideration: considerationItems,
  //      //             orderType: OrderType.FULL_OPEN,
  //      //             startTime: uint256(block.timestamp),
  //      //             endTime: uint256(block.timestamp + 10 minutes),
  //      //             zoneHash: bytes32(0),
  //      //             salt: uint256(blockhash(block.number)),
  //      //             conduitKey: Bytes32AddressLib.fillLast12Bytes(address(COLLATERAL_TOKEN)), // 0x120
  //      //             totalOriginalConsiderationItems: uint256(3)
  //      // }),
  //
  //      Consideration consideration = new Consideration(address(COLLATERAL_TOKEN));
  //
  //      OrderParameters memory orderParameters = OrderParameters({
  //        offerer: address(COLLATERAL_TOKEN),
  //        zone: address(0), // 0x20
  //        offer: offer,
  //        consideration: considerationItems,
  //        orderType: OrderType.FULL_OPEN,
  //        startTime: uint256(block.timestamp),
  //        endTime: uint256(block.timestamp + 10 minutes),
  //        zoneHash: bytes32(0),
  //        salt: uint256(blockhash(block.number)),
  //        conduitKey: bytes32(0), // 0x120
  //        totalOriginalConsiderationItems: uint256(3)
  //      });
  //
  //      uint256 nonce = consideration.getCounter(address(COLLATERAL_TOKEN));
  //      OrderComponents memory orderComponents = OrderComponents(
  //        orderParameters.offerer,
  //        orderParameters.zone,
  //        orderParameters.offer,
  //        orderParameters.consideration,
  //        orderParameters.orderType,
  //        orderParameters.startTime,
  //        orderParameters.endTime,
  //        orderParameters.zoneHash,
  //        orderParameters.salt,
  //        orderParameters.conduitKey,
  //        nonce
  //      );
  //
  //      bytes32 orderHash = consideration.getOrderHash(orderComponents);
  //
  //      bytes memory signature = signOrder(
  //        consideration,
  //        appraiserTwoPK,
  //        orderHash
  //      );
  //
  //      // signOrder(consideration, alicePk, orderHash);
  //
  //      Order memory listingOffer = Order(orderParameters, signature);
  //
  //      // (Order memory listingOffer, , ) = _prepareOrder(tokenId, uint256(3));
  //
  //      COLLATERAL_TOKEN.listUnderlyingOnSeaport(collateralId, listingOffer);
  //  //  }
  //}
}
