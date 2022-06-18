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

address constant AIRDROP_GRAPES_TOKEN = 0x025C6da5BD0e6A5dd1350fda9e3B6a614B205a1F;
address constant APE_HOLDER = 0x8742fa292AFfB6e5eA88168539217f2e132294f9;
address constant APE_ADDRESS = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D; // TODO check

contract ApeCoinClaim is IFlashAction {
    address vault;

    constructor(address _vault) {
        vault = _vault;
    }

    function onFlashAction(bytes calldata data) external returns (bytes32) {
        AIRDROP_GRAPES_TOKEN.call(
            abi.encodePacked(bytes4((keccak256("claimTokens()"))))
        );
        ERC721 ape = ERC721(APE_ADDRESS);
        ape.transferFrom(address(this), vault, uint(10));
        return bytes32(keccak256("FlashAction.onFlashAction"));
    }
}

contract ForkedTest is TestHelpers {
    // 10,094 tokens
    event AirDrop(
        address indexed account,
        uint256 indexed amount,
        uint256 timestamp
    );

    function testFlashApeClaim() public {
        uint256 tokenId = uint256(10);
        
        _hijackNFT(APE_ADDRESS, tokenId);

        vm.roll(9699885); // March 18, 2020
        // vm.roll(14404760);

        address tokenContract = APE_ADDRESS;
        
        // uint256 maxAmount = uint256(100000000000000000000);
        // uint256 interestRate = uint256(50000000000000000000);
        // uint256 duration = uint256(block.timestamp + 10 minutes);
        // uint256 amount = uint256(1 ether);
        // uint8 lienPosition = uint8(0);
        // uint256 schedule = uint256(50);

        //balance of WETH before loan

        (bytes32 vaultHash, ) = _commitToLoan(
            APE_ADDRESS,
            tokenId,
            defaultTerms
        );

        uint256 collateralVault = uint256(keccak256(abi.encodePacked(APE_ADDRESS, tokenId)));

        IFlashAction apeCoinClaim = new ApeCoinClaim(address(COLLATERAL_VAULT));

        // vm.expectEmit(false, false, false, false);
        // emit AirDrop(APE_HOLDER, uint256(0), uint256(0));
        COLLATERAL_VAULT.flashAction(apeCoinClaim, collateralVault, "");
  

    }

}
