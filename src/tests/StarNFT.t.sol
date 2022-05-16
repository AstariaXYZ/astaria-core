pragma solidity ^0.8.13;

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {StarNFT} from "../StarNFT.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {Strings2} from "./utils/Strings2.sol";
import {NFTBondController} from "../NFTBondController.sol";
import {AuctionHouse} from "auction/AuctionHouse.sol";

string constant weth9Artifact = "src/tests/WETH9.json";

contract Dummy721 is MockERC721 {
    constructor() MockERC721("TEST NFT", "TEST") {
        _mint(msg.sender, 1);
        _mint(msg.sender, 2);
    }
}

contract Test is DSTestPlus {
    function deployCode(string memory what) public returns (address addr) {
        bytes memory bytecode = hevm.getCode(what);
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
    }
}

contract StarNFTTest is Test {
    enum UserRoles {
        ADMIN,
        BOND_CONTROLLER,
        WRAPPER,
        AUCTION_HOUSE
    }

    using Strings2 for bytes;
    StarNFT wrapper;
    NFTBondController bondVault;
    Dummy721 testNFT;
    AuctionHouse AUCTION_HOUSE;
    bytes32 public whiteListRoot;
    bytes32[] public nftProof;

    address appraiser = hevm.addr(0x1339);

    function setUp() public {
        address liquidator = hevm.addr(0x1337);

        testNFT = new Dummy721();
        address WETH9 = deployCode(weth9Artifact);
        _createWhitelist(address(testNFT));
        MultiRolesAuthority MRA = new MultiRolesAuthority(
            address(this),
            Authority(address(0))
        );
        wrapper = new StarNFT(MRA, whiteListRoot, liquidator);

        bondVault = new NFTBondController("TEST URI", WETH9, address(wrapper));

        AUCTION_HOUSE = new AuctionHouse(
            WETH9,
            address(MRA),
            address(bondVault),
            address(wrapper)
        );

        wrapper.setBondController(address(bondVault));
        wrapper.setAuctionHouse(address(AUCTION_HOUSE));

        MRA.setUserRole(
            address(bondVault),
            uint8(UserRoles.BOND_CONTROLLER),
            true
        );
        MRA.setUserRole(address(wrapper), uint8(UserRoles.WRAPPER), true);
        MRA.setUserRole(
            address(AUCTION_HOUSE),
            uint8(UserRoles.AUCTION_HOUSE),
            true
        );
        testNFT.setApprovalForAll(address(wrapper), true);
    }

    function _createWhitelist(address newNFT) internal {
        string[] memory inputs = new string[](3);
        inputs[0] = "node";
        inputs[1] = "scripts/whitelistGenerator.js";
        inputs[2] = abi.encodePacked(newNFT).toHexString();

        bytes memory res = hevm.ffi(inputs);
        (bytes32 root, bytes32[] memory proof) = abi.decode(
            res,
            (bytes32, bytes32[])
        );
        whiteListRoot = root;
        nftProof = proof;
    }

    /**
        Ensure our deposit function emits the correct events
        Ensure that the token Id's are correct
     */
    function testNFTDeposit() public {
        wrapper.depositERC721(
            address(this),
            address(testNFT),
            uint256(1),
            nftProof
        );
        wrapper.depositERC721(
            address(this),
            address(testNFT),
            uint256(2),
            nftProof
        );
    }

    //TODO: start filling out the following tests
    /**
        Ensure that we can create a new bond vault and we emit the correct events
     */
    function testBondVaultCreation() public {
        //address appraiser,
        //        bytes32 root,
        //        uint256 expiration,
        //        uint256 deadline,
        //        uint256 maturity,
        //        uint256 appraiserNonce
        bytes32 hash = keccak256(
            bondVault.encodeBondVaultHash(
                appraiser,
                bytes32(uint256(0x123)),
                block.timestamp + 30 days,
                block.timestamp + 35 days,
                block.timestamp + 60 days,
                bondVault.appraiserNonces(appraiser)
            )
        );
        uint8 v;
        bytes32 r;
        bytes32 s;

        (v, r, s) = hevm.sign(uint256(0x1339), hash);

        bondVault.newBondVault(
            appraiser,
            bytes32(uint256(0x123)),
            block.timestamp + 30 days,
            block.timestamp + 35 days,
            block.timestamp + 60 days,
            bytes32("0x12345"),
            v,
            r,
            s
        );
    }

    /**
       Ensure that we can borrow capital from the bond controller
       ensure that we're emitting the correct events
       ensure that we're repaying the proper collateral

   */
    function testCommitToLoan() public {}

    /**
        Ensure that asset's that have liens cannot be released to Anyone.
     */
    function testLiens() public {}

    /**
        Ensure that we can auction underlying vaults
        ensure that we're emitting the correct events
        ensure that we're repaying the proper collateral

    */
    function testAuctionVault() public {}

    /**
        Ensure that owner of the token can cancel the auction by repaying the reserve(sum of debt + fee)
        ensure that we're emitting the correct events

    */
    function testCancelAuction() public {}
}
