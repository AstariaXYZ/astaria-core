// pragma solidity ^0.8.13;

// import "forge-std/Test.sol";

// import {Authority} from "solmate/auth/Auth.sol";
// import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
// import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
// import {IERC1155Receiver} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
// import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
// import {Strings} from "openzeppelin/utils/Strings.sol";
// import {CollateralVault, IFlashAction} from "../CollateralVault.sol";
// import {LienToken} from "../LienToken.sol";
// import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
// import {ILienToken} from "../interfaces/ILienToken.sol";
// import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
// import {IBrokerRouter, BrokerRouter} from "../BrokerRouter.sol";
// import {AuctionHouse} from "gpl/AuctionHouse.sol";
// import {Strings2} from "./utils/Strings2.sol";
// import {BrokerImplementation} from "../BrokerImplementation.sol";
// import {IBroker, SoloBroker, BrokerImplementation} from "../BrokerImplementation.sol";
// import {BrokerVault} from "../BrokerVault.sol";
// import {TransferProxy} from "../TransferProxy.sol";
// import {BeaconProxy} from "openzeppelin/proxy/beacon/BeaconProxy.sol";
// import {UpgradeableBeacon} from "openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
// import {SeaportInterface, Order} from "seaport/interfaces/SeaportInterface.sol";
// import {ConsiderationInterface} from "seaport/interfaces/ConsiderationInterface.sol";
// import {TestHelpers, Dummy721, IWETH9} from "./TestHelpers.t.sol";
// import {Consideration} from "seaport/lib/Consideration.sol";
// import {OfferItem, ConsiderationItem, OrderParameters, OrderComponents} from "seaport/lib/ConsiderationStructs.sol";
// import {OrderType, ItemType, BasicOrderType} from "seaport/lib/ConsiderationEnums.sol";
// import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";
// import {FulfillBasicOrderTest} from "../../lib/seaport/test/foundry/FulfillBasicOrderTest.t.sol";
// import {BaseOrderTest} from "../../lib/seaport/test/foundry/utils/BaseOrderTest.sol";

// import "../ValidatorAsset.sol";

// string constant weth9Artifact = "src/tests/WETH9.json";

// address constant AIRDROP_GRAPES_TOKEN = 0x025C6da5BD0e6A5dd1350fda9e3B6a614B205a1F;
// address constant APE_HOLDER = 0x8742fa292AFfB6e5eA88168539217f2e132294f9;
// address constant APE_ADDRESS = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D; // TODO check

// contract ApeCoinClaim is IFlashAction {
//     address vault;

//     constructor(address _vault) {
//         vault = _vault;
//     }

//     function onFlashAction(bytes calldata data) external returns (bytes32) {
//         AIRDROP_GRAPES_TOKEN.call(
//             abi.encodePacked(bytes4((keccak256("claimTokens()"))))
//         );
//         ERC721 ape = ERC721(APE_ADDRESS);
//         ape.transferFrom(address(this), vault, uint256(10));
//         return bytes32(keccak256("FlashAction.onFlashAction"));
//     }
// }

// contract ForkedTest is TestHelpers, BaseOrderTest {
//     function setUp() public override(TestHelpers, BaseOrderTest) {
//         TestHelpers.setUp();
//         // BaseOrderTest.setUp();
//     }

//     // 10,094 tokens
//     event AirDrop(
//         address indexed account,
//         uint256 indexed amount,
//         uint256 timestamp
//     );

//     function testListUnderlying() public {
//         Dummy721 loanTest = new Dummy721();
//         address tokenContract = address(loanTest);
//         uint256 tokenId = uint256(1);

//         uint256 listingPrice = uint256(5 ether);
//         uint256 listingFee = ((listingPrice * 2e5) / 100e5);
//         uint256 minListingPrice = listingPrice + (listingFee * 2);
//         //        vm.expectEmit(true, true, false, true);
//         //        emit DepositERC721(address(this), tokenContract, tokenId);
//         (bytes32 vaultHash, IBrokerRouter.Terms memory terms) = _commitToLoan(
//             tokenContract,
//             tokenId,
//             defaultTerms
//         );
//         uint256 collateralVault = uint256(
//             keccak256(abi.encodePacked(tokenContract, tokenId))
//         );
//         //struct OrderParameters {
//         //    address offerer; // 0x00
//         //    address zone; // 0x20
//         //    OfferItem[] offer; // 0x40
//         //    ConsiderationItem[] consideration; // 0x60
//         //    OrderType orderType; // 0x80
//         //    uint256 startTime; // 0xa0
//         //    uint256 endTime; // 0xc0
//         //    bytes32 zoneHash; // 0xe0
//         //    uint256 salt; // 0x100
//         //    bytes32 conduitKey; // 0x120
//         //    uint256 totalOriginalConsiderationItems; // 0x140
//         //    // offer.length                          // 0x160
//         //}

//         OfferItem[] memory offer = new OfferItem[](1);
//         offer[0] = OfferItem(
//             ItemType.ERC721,
//             tokenContract,
//             tokenId,
//             minListingPrice,
//             minListingPrice
//         );
//         ConsiderationItem[] memory considerationItems = new ConsiderationItem[](
//             3
//         );

//         //setup validator asset
//         ValidatorAsset validator = new ValidatorAsset(
//             address(COLLATERAL_VAULT)
//         );

//         //ItemType itemType;
//         //    address token;
//         //    uint256 identifierOrCriteria;
//         //    uint256 startAmount;
//         //    uint256 endAmount;
//         //    address payable recipient;

//         //TODO: compute listing fee for opensea
//         //compute royalty fee for the asset if it exists
//         //validator
//         considerationItems[0] = ConsiderationItem(
//             ItemType.ERC20,
//             address(WETH9),
//             uint256(0),
//             listingFee,
//             listingFee,
//             payable(address(0x8De9C5A032463C561423387a9648c5C7BCC5BC90)) //opensea fees
//         );
//         considerationItems[1] = ConsiderationItem(
//             ItemType.ERC20,
//             address(WETH9),
//             uint256(0),
//             minListingPrice,
//             minListingPrice,
//             payable(address(COLLATERAL_VAULT))
//         );
//         considerationItems[1] = ConsiderationItem(
//             ItemType.ERC1155,
//             address(validator),
//             collateralVault,
//             minListingPrice,
//             minListingPrice,
//             payable(address(COLLATERAL_VAULT))
//         );

//         emit Dummy();

//         // OrderParameters(
//         //         offerer,
//         //         address(0),
//         //         offerItems,
//         //         considerationItems,
//         //         orderType,
//         //         block.timestamp,
//         //         block.timestamp + 1,
//         //         bytes32(0),
//         //         globalSalt++,
//         //         bytes32(0),
//         //         considerationItems.length
//         //     );

//         // old andrew
//         //     OrderParameters({
//         //             offerer: address(COLLATERAL_VAULT),
//         //             zone: address(COLLATERAL_VAULT), // 0x20
//         //             offer: offer,
//         //             consideration: considerationItems,
//         //             orderType: OrderType.FULL_OPEN,
//         //             startTime: uint256(block.timestamp),
//         //             endTime: uint256(block.timestamp + 10 minutes),
//         //             zoneHash: bytes32(0),
//         //             salt: uint256(blockhash(block.number)),
//         //             conduitKey: Bytes32AddressLib.fillLast12Bytes(address(COLLATERAL_VAULT)), // 0x120
//         //             totalOriginalConsiderationItems: uint256(3)
//         // }),

//         Consideration consideration = new Consideration(
//             address(COLLATERAL_VAULT)
//         );

//         OrderParameters memory orderParameters = OrderParameters({
//             offerer: address(COLLATERAL_VAULT),
//             zone: address(0), // 0x20
//             offer: offer,
//             consideration: considerationItems,
//             orderType: OrderType.FULL_OPEN,
//             startTime: uint256(block.timestamp),
//             endTime: uint256(block.timestamp + 10 minutes),
//             zoneHash: bytes32(0),
//             salt: uint256(blockhash(block.number)),
//             conduitKey: bytes32(0), // 0x120
//             totalOriginalConsiderationItems: uint256(3)
//         });

//         uint256 nonce = consideration.getCounter(address(COLLATERAL_VAULT));
//         OrderComponents memory orderComponents = OrderComponents(
//             orderParameters.offerer,
//             orderParameters.zone,
//             orderParameters.offer,
//             orderParameters.consideration,
//             orderParameters.orderType,
//             orderParameters.startTime,
//             orderParameters.endTime,
//             orderParameters.zoneHash,
//             orderParameters.salt,
//             orderParameters.conduitKey,
//             nonce
//         );

//         bytes32 orderHash = consideration.getOrderHash(orderComponents);

//         bytes memory signature = signOrder(
//             consideration,
//             appraiserTwoPK,
//             orderHash
//         );

//         // signOrder(consideration, alicePk, orderHash);

//         Order memory listingOffer = Order(orderParameters, signature);

//         // (Order memory listingOffer, , ) = _prepareOrder(tokenId, uint256(3));

//         COLLATERAL_VAULT.listUnderlyingOnSeaport(collateralVault, listingOffer);
//     }

//     // from seaport
//     // function signOrder(
//     //     ConsiderationInterface _consideration,
//     //     uint256 _pkOfSigner,
//     //     bytes32 _orderHash
//     // ) internal returns (bytes memory) {
//     //     (bytes32 r, bytes32 s, uint8 v) = getSignatureComponents(
//     //         _consideration,
//     //         _pkOfSigner,
//     //         _orderHash
//     //     );
//     //     return abi.encodePacked(r, s, v);
//     // }

//     // function testFlashApeClaim() public {
//     //     uint256 tokenId = uint256(10);

//     //     _hijackNFT(APE_ADDRESS, tokenId);

//     //     vm.roll(9699885); // March 18, 2020
//     //     // vm.roll(14404760);

//     //     address tokenContract = APE_ADDRESS;

//     //     // uint256 maxAmount = uint256(100000000000000000000);
//     //     // uint256 interestRate = uint256(50000000000000000000);
//     //     // uint256 duration = uint256(block.timestamp + 10 minutes);
//     //     // uint256 amount = uint256(1 ether);
//     //     // uint8 lienPosition = uint8(0);
//     //     // uint256 schedule = uint256(50);

//     //     //balance of WETH before loan

//     //     (bytes32 vaultHash, ) = _commitToLoan(
//     //         APE_ADDRESS,
//     //         tokenId,
//     //         defaultTerms
//     //     );

//     //     uint256 collateralVault = uint256(
//     //         keccak256(abi.encodePacked(APE_ADDRESS, tokenId))
//     //     );

//     //     IFlashAction apeCoinClaim = new ApeCoinClaim(address(COLLATERAL_VAULT));

//     //     // vm.expectEmit(false, false, false, false);
//     //     // emit AirDrop(APE_HOLDER, uint256(0), uint256(0));
//     //     COLLATERAL_VAULT.flashAction(apeCoinClaim, collateralVault, "");
//     // }

//     function testFlashApeClaim() public {
//         uint256 tokenId = uint256(10);

//         _hijackNFT(APE_ADDRESS, tokenId);

//         vm.roll(9699885); // March 18, 2020
//         // vm.roll(14404760);

//         address tokenContract = APE_ADDRESS;

//         // uint256 maxAmount = uint256(100000000000000000000);
//         // uint256 interestRate = uint256(50000000000000000000);
//         // uint256 duration = uint256(block.timestamp + 10 minutes);
//         // uint256 amount = uint256(1 ether);
//         // uint8 lienPosition = uint8(0);
//         // uint256 schedule = uint256(50);

//         //balance of WETH before loan

//         (bytes32 vaultHash, ) = _commitToLoan(
//             APE_ADDRESS,
//             tokenId,
//             defaultTerms
//         );

//         uint256 collateralVault = uint256(
//             keccak256(abi.encodePacked(APE_ADDRESS, tokenId))
//         );

// //         IFlashAction apeCoinClaim = new ApeCoinClaim(address(COLLATERAL_VAULT));

// //         // vm.expectEmit(false, false, false, false);
// //         // emit AirDrop(APE_HOLDER, uint256(0), uint256(0));
// //         COLLATERAL_VAULT.flashAction(apeCoinClaim, collateralVault, "");
// //     }
// // }
