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

import "openzeppelin/token/ERC20/IERC20.sol";

interface IWETH9 is IERC20 {
    function deposit() external payable;

    function withdraw(uint256) external;
}

contract Test is DSTestPlus {
    function deployCode(string memory what) public returns (address addr) {
        bytes memory bytecode = hevm.getCode(what);
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
    }
}

contract AstariaTest is Test {
    enum UserRoles {
        ADMIN,
        BOND_CONTROLLER,
        WRAPPER,
        AUCTION_HOUSE
    }

    using Strings2 for bytes;
    StarNFT STAR_NFT;
    NFTBondController BOND_CONTROLLER;
    Dummy721 testNFT;

    IWETH9 WETH9;
    MultiRolesAuthority MRA;
    AuctionHouse AUCTION_HOUSE;
    bytes32 public whiteListRoot;
    bytes32[] public nftProof;

    bytes32 testBondVaultHash = bytes32(uint256(0x123));

    address appraiser = hevm.addr(0x1339);

    function setUp() public {
        WETH9 = IWETH9(deployCode(weth9Artifact));

        MRA = new MultiRolesAuthority(address(this), Authority(address(0)));

        address liquidator = hevm.addr(0x1337); //remove

        testNFT = new Dummy721();
        _createWhitelist(address(testNFT));
        STAR_NFT = new StarNFT(MRA, whiteListRoot, liquidator);

        BOND_CONTROLLER = new NFTBondController(
            "TEST URI",
            address(WETH9),
            address(STAR_NFT)
        );

        AUCTION_HOUSE = new AuctionHouse(
            address(WETH9),
            address(MRA),
            address(BOND_CONTROLLER),
            address(STAR_NFT)
        );

        STAR_NFT.setBondController(address(BOND_CONTROLLER));
        STAR_NFT.setAuctionHouse(address(AUCTION_HOUSE));
        testNFT.setApprovalForAll(address(STAR_NFT), true);
        _setupRolesAndCapabilities();
        _depositNFTs();
    }

    function _setupRolesAndCapabilities() internal {
        MRA.setRoleCapability(
            uint8(UserRoles.WRAPPER),
            AuctionHouse.createAuction.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.WRAPPER),
            AuctionHouse.endAuction.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.WRAPPER),
            AuctionHouse.cancelAuction.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.BOND_CONTROLLER),
            StarNFT.manageLien.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.BOND_CONTROLLER),
            StarNFT.auctionVault.selector,
            true
        );
        MRA.setUserRole(
            address(BOND_CONTROLLER),
            uint8(UserRoles.BOND_CONTROLLER),
            true
        );
        MRA.setUserRole(address(STAR_NFT), uint8(UserRoles.WRAPPER), true);
        MRA.setUserRole(
            address(AUCTION_HOUSE),
            uint8(UserRoles.AUCTION_HOUSE),
            true
        );
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
    function _depositNFTs() internal {
        STAR_NFT.depositERC721(
            address(this),
            address(testNFT),
            uint256(1),
            nftProof
        );
        STAR_NFT.depositERC721(
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
        bytes32 hash = keccak256(
            BOND_CONTROLLER.encodeBondVaultHash(
                appraiser,
                testBondVaultHash,
                block.timestamp + 30 days,
                block.timestamp + 35 days,
                block.timestamp + 60 days,
                BOND_CONTROLLER.appraiserNonces(appraiser)
            )
        );
        uint8 v;
        bytes32 r;
        bytes32 s;

        (v, r, s) = hevm.sign(uint256(0x1339), hash);

        BOND_CONTROLLER.newBondVault(
            appraiser,
            testBondVaultHash,
            block.timestamp + 30 days,
            block.timestamp + 35 days,
            block.timestamp + 60 days,
            bytes32("0x12345"),
            v,
            r,
            s
        );
    }

    function _generateLoanProof(uint256 _collateralVault)
        internal
        returns (bytes32[] memory)
    {
        (address tokenContract, uint256 tokenId) = STAR_NFT
            .getUnderlyingFromStar(_collateralVault);
        string[] memory inputs = new string[](4);
        inputs[0] = "node";
        inputs[1] = "scripts/loanProofGenerator.js";
        inputs[2] = abi.encodePacked(tokenContract).toHexString();
        inputs[3] = abi.encodePacked(tokenId).toHexString();

        bytes memory res = hevm.ffi(inputs);
        bytes32[] memory proof = abi.decode(res, (bytes32[]));
        return proof;
    }

    /**
       Ensure that we can borrow capital from the bond controller
       ensure that we're emitting the correct events
       ensure that we're repaying the proper collateral

   */
    function testCommitToLoan() public {
        //bytes32[] calldata proof,
        //        bytes32 bondVault,
        //        uint256 collateralVault,
        //        uint256 maxAmount,
        //        uint256 interestRate,
        //        uint256 start,
        //        uint256 end,
        //        uint256 amount,
        //        uint256 lienPosition,
        //        uint256 schedule
        uint256 collateralVault = uint256(1);
        uint256 maxAmount = uint256(15 ether);
        uint256 interestRate = uint256(20 gwei);
        uint256 start = block.timestamp + 15 days;
        uint256 end = block.timestamp + 15 days;
        uint256 amount = uint256(5 ether);
        uint256 lienPosition = uint256(0);
        uint256 schedule = uint256(1 gwei);
        bytes32[] memory proof = _generateLoanProof(collateralVault);
        BOND_CONTROLLER.commitToLoan(
            proof,
            testBondVaultHash,
            collateralVault,
            maxAmount,
            interestRate,
            start,
            end,
            amount,
            lienPosition,
            schedule
        );
    }

    function testReleaseToAddress() public {
        STAR_NFT.getUnderlyingFromStar(
            uint256(
                36620565764810032184374596725622674351691659512533154122603505468833195267743
            )
        );
        STAR_NFT.releaseToAddress(
            uint256(
                36620565764810032184374596725622674351691659512533154122603505468833195267743
            ),
            address(this)
        );
    }

    /**
        Ensure that asset's that have liens cannot be released to Anyone.
     */
    function testLiens() public {
        //trigger loan commit
        //try to release asset

        STAR_NFT.releaseToAddress(
            uint256(
                88029459242596929258145495964769489431382501476249398212111764498044871342998
            ),
            address(this)
        );
    }

    /**
        Ensure that we can auction underlying vaults
        ensure that we're emitting the correct events
        ensure that we're repaying the proper collateral

    */
    function testAuctionVault() public {
        BOND_CONTROLLER.liquidate(testBondVaultHash, uint256(0), uint256(1));
    }

    /**
        Ensure that owner of the token can cancel the auction by repaying the reserve(sum of debt + fee)
        ensure that we're emitting the correct events

    */
    function testCancelAuction() public {
        //needs helper that moves collateral into default
        //trigger liquidate
        //cancel auction as holder
    }
}
