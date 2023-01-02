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

pragma solidity ^0.8.17;
import {Script} from "forge-std/Script.sol";
import "core/test/TestHelpers.t.sol";
import {
  AdvancedOrder,
  CriteriaResolver,
  OfferItem,
  ConsiderationItem,
  ItemType,
  OrderParameters,
  OrderComponents,
  OrderType,
  Order
} from "seaport/lib/ConsiderationStructs.sol";
import {Consideration} from "seaport/lib/Consideration.sol";

import {Auth, Authority} from "solmate/auth/Auth.sol";

//contract SimpleSaleTest is Auth {
//  constructor(address creator) Auth(creator, Authority(address(0))) {}
//
//  function isValidSignature(bytes32, bytes memory)
//    external
//    pure
//    returns (bytes4)
//  {
//    return 0x1626ba7e;
//  }
//
//  function run(uint256 tokenId) public requiresAuth {}
//}

contract GoerliSetup is TestHelpers {
  function setUp() public override(TestHelpers) {}

  function run() public override {
    TestNFT nft = TestNFT(address(0xd6eF92fA2eF2Cb702f0bFfF54b111b076aC0237D));

    Consideration SEAPORT = Consideration(
      address(0x00000000006c3852cbEf3e08E8dF289169EdE581)
    );
    nft.setApprovalForAll(address(SEAPORT), true);

    // 0x160

    ConsiderationItem[] memory considerations = new ConsiderationItem[](2);
    uint256 basePayment = 50e18;
    uint256 basePaymentEnd = 10e18;
    uint256 seaFee = basePayment / 40;
    uint256 seaFeeEnd = basePaymentEnd / 40;
    considerations[0] = ConsiderationItem(
      ItemType.NATIVE,
      address(0),
      uint256(0),
      basePayment - seaFee,
      basePaymentEnd - seaFeeEnd,
      payable(address(this))
    );
    considerations[1] = ConsiderationItem(
      ItemType.NATIVE,
      address(0),
      uint256(0),
      seaFee,
      seaFeeEnd,
      payable(0x0000a26b00c1F0DF003000390027140000fAa719)
    );

    OfferItem[] memory offerItems = new OfferItem[](1);
    offerItems[0] = OfferItem({
      itemType: ItemType.ERC721,
      token: address(nft),
      identifierOrCriteria: 2,
      startAmount: 1,
      endAmount: 1
    });

    //uint256 startTime; // 0xa0
    //    uint256 endTime; // 0xc0
    //    bytes32 zoneHash; // 0xe0
    //    uint256 salt; // 0x100
    //    bytes32 conduitKey; // 0x120
    //    uint256 totalOriginalConsiderationItems; // 0x140
    //    // offer.length

    //address offerer; // 0x00
    //    address zone; // 0x20
    //    OfferItem[] offer; // 0x40
    //    ConsiderationItem[] consideration; // 0x60
    //    OrderType orderType; // 0x80
    //    uint256 startTime; // 0xa0
    //    uint256 endTime; // 0xc0
    //    bytes32 zoneHash; // 0xe0
    //    uint256 salt; // 0x100
    //    bytes32 conduitKey; // 0x120
    //    uint256 totalOriginalConsiderationItems; // 0x140
    OrderParameters memory orderParams = OrderParameters(
      address(0x11f287ef1684373e2579Df129012C1cc02F214Fe),
      address(0),
      offerItems,
      considerations,
      OrderType.FULL_OPEN,
      block.timestamp,
      block.timestamp + 3 days,
      bytes32(0),
      uint256(blockhash(block.number - 1)),
      bytes32(0),
      2
    );

    OrderComponents memory components = getOrderComponents(
      orderParams,
      consideration.getCounter(
        address(0x11f287ef1684373e2579Df129012C1cc02F214Fe)
      )
    );

    bytes memory orderSig = signOrder(
      SEAPORT,
      uint256(0x12),
      consideration.getOrderHash(components)
    );

    Order memory newOrder = Order(orderParams, orderSig);
    Order[] memory orders = new Order[](1);
    orders[0] = newOrder;
    vm.startBroadcast();

    SEAPORT.validate(orders);
    vm.stopBroadcast();
  }
}
