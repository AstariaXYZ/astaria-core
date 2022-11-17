//pragma solidity ^0.8.17;
//
//import {SeaportInterface, Order} from "seaport/interfaces/SeaportInterface.sol";
//import {
//  ConsiderationInterface
//} from "seaport/interfaces/ConsiderationInterface.sol";
//import {Consideration} from "seaport/lib/Consideration.sol";
//import {
//  OfferItem,
//  ConsiderationItem,
//  OrderParameters,
//  OrderComponents
//} from "seaport/lib/ConsiderationStructs.sol";
//import {
//  OrderType,
//  ItemType,
//  BasicOrderType
//} from "seaport/lib/ConsiderationEnums.sol";
//import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";
//
//contract LiquidationRouter {
//  function run() external {
//    OfferItem[] memory offer = new OfferItem[](1);
//    offer[0] = OfferItem(
//      ItemType.ERC721,
//      tokenContract,
//      tokenId,
//      minListingPrice,
//      minListingPrice
//    );
//    ConsiderationItem[] memory considerationItems = new ConsiderationItem[](3);
//
//    //setup validator asset
//    ValidatorAsset validator = new ValidatorAsset(address(COLLATERAL_TOKEN));
//
//    //ItemType itemType;
//    //    address token;
//    //    uint256 identifierOrCriteria;
//    //    uint256 startAmount;
//    //    uint256 endAmount;
//    //    address payable recipient;
//
//    //TODO: compute listing fee for opensea
//    //compute royalty fee for the asset if it exists
//    //validator
//    considerationItems[0] = ConsiderationItem(
//      ItemType.ERC20,
//      address(WETH9),
//      uint256(0),
//      listingFee,
//      listingFee,
//      payable(address(0x8De9C5A032463C561423387a9648c5C7BCC5BC90)) //opensea fees
//    );
//    considerationItems[1] = ConsiderationItem(
//      ItemType.ERC20,
//      address(WETH9),
//      uint256(0),
//      minListingPrice,
//      minListingPrice,
//      payable(address(COLLATERAL_TOKEN))
//    );
//    considerationItems[1] = ConsiderationItem(
//      ItemType.ERC1155,
//      address(validator),
//      collateralId,
//      minListingPrice,
//      minListingPrice,
//      payable(address(COLLATERAL_TOKEN))
//    );
//
//    emit Dummy();
//
//    // OrderParameters(
//    //         offerer,
//    //         address(0),
//    //         offerItems,
//    //         considerationItems,
//    //         orderType,
//    //         block.timestamp,
//    //         block.timestamp + 1,
//    //         bytes32(0),
//    //         globalSalt++,
//    //         bytes32(0),
//    //         considerationItems.length
//    //     );
//
//    // old andrew
//    //     OrderParameters({
//    //             offerer: address(COLLATERAL_TOKEN),
//    //             zone: address(COLLATERAL_TOKEN), // 0x20
//    //             offer: offer,
//    //             consideration: considerationItems,
//    //             orderType: OrderType.FULL_OPEN,
//    //             startTime: uint256(block.timestamp),
//    //             endTime: uint256(block.timestamp + 10 minutes),
//    //             zoneHash: bytes32(0),
//    //             salt: uint256(blockhash(block.number)),
//    //             conduitKey: Bytes32AddressLib.fillLast12Bytes(address(COLLATERAL_TOKEN)), // 0x120
//    //             totalOriginalConsiderationItems: uint256(3)
//    // }),
//
//    Consideration consideration = new Consideration(address(COLLATERAL_TOKEN));
//
//    OrderParameters memory orderParameters = OrderParameters({
//      offerer: address(COLLATERAL_TOKEN),
//      zone: address(0), // 0x20
//      offer: offer,
//      consideration: considerationItems,
//      orderType: OrderType.FULL_OPEN,
//      startTime: uint256(block.timestamp),
//      endTime: uint256(block.timestamp + 10 minutes),
//      zoneHash: bytes32(0),
//      salt: uint256(blockhash(block.number)),
//      conduitKey: bytes32(0), // 0x120
//      totalOriginalConsiderationItems: uint256(3)
//    });
//
//    uint256 nonce = consideration.getCounter(address(COLLATERAL_TOKEN));
//    OrderComponents memory orderComponents = OrderComponents(
//      orderParameters.offerer,
//      orderParameters.zone,
//      orderParameters.offer,
//      orderParameters.consideration,
//      orderParameters.orderType,
//      orderParameters.startTime,
//      orderParameters.endTime,
//      orderParameters.zoneHash,
//      orderParameters.salt,
//      orderParameters.conduitKey,
//      nonce
//    );
//
//    bytes32 orderHash = consideration.getOrderHash(orderComponents);
//
//    bytes memory signature = signOrder(
//      consideration,
//      appraiserTwoPK,
//      orderHash
//    );
//
//    // signOrder(consideration, alicePk, orderHash);
//
//    Order memory listingOffer = Order(orderParameters, signature);
//
//    // (Order memory listingOffer, , ) = _prepareOrder(tokenId, uint256(3));
//
//    COLLATERAL_TOKEN.listUnderlyingOnSeaport(collateralId, listingOffer);
//  }
//}
