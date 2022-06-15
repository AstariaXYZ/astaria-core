pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {CollateralVault, IFlashAction} from "../CollateralVault.sol";
import {LienToken} from "../LienToken.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {ILienToken} from "../interfaces/ILienToken.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {IBrokerRouter, BrokerRouter} from "../BrokerRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {Strings2} from "./utils/Strings2.sol";
import {BrokerImplementation} from "../BrokerImplementation.sol";
import {IBroker, SoloBroker, BrokerImplementation} from "../BrokerImplementation.sol";
import {BrokerVault} from "../BrokerVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {BeaconProxy} from "openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import {TestHelpers, Dummy721, IWETH9} from "./TestHelpers.sol";

string constant weth9Artifact = "src/tests/WETH9.json";

address constant airdropGrapesToken = 0x025C6da5BD0e6A5dd1350fda9e3B6a614B205a1F;
address constant apeHolder = 0x8742fa292AFfB6e5eA88168539217f2e132294f9;
address constant apeAddress = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D; // TODO check

contract ApeCoinClaim is IFlashAction {
    function onFlashAction(bytes calldata data) external returns (bytes32) {
        // claim ApeCoin 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D, claimTokens()
        airdropGrapesToken.call(
            abi.encodePacked(bytes4((keccak256("claimTokens()"))))
        );
    }
}

contract ForkedTest is TestHelpers {
    // 10,094 tokens
    event AirDrop(
        address indexed account,
        uint256 indexed amount,
        uint256 timestamp
    );

    // function testFlashAction() public {

    //     vm.startPrank(apeHolder);

    //     IFlashAction apeCoinClaim = new ApeCoinClaim();

    //     uint256 tokenId = uint256(8520);
    //     uint256 tokenId = uint256(10);

    //     uint256 collateralVault = uint256(keccak256(abi.encodePacked(apeAddress, tokenId)));

    //     vm.expectEmit(true, false, false, false);
    //     emit AirDrop(apeHolder, uint256(0), uint256(0));
    //     COLLATERAL_VAULT.flashAction(apeCoinClaim, collateralVault, "");
    //     vm.stopPrank();

    //     // vm.roll(9698885); // March 18, 2020
    // }
}
