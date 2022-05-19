pragma solidity ^0.8.13;

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {StarNFT} from "../StarNFT.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {NFTBondController} from "../NFTBondController.sol";
import {AuctionHouse} from "auction/AuctionHouse.sol";
import {Strings2} from "./utils/Strings2.sol";

string constant weth9Artifact = "src/tests/WETH9.json";

contract Dummy721 is MockERC721 {
    constructor() MockERC721("TEST NFT", "TEST") {
        _mint(msg.sender, 1);
        _mint(msg.sender, 2);
    }
}

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

//TODO:
// - setup helpers that let us put a loan into default
// - setup helpers to repay loans
// - setup helpers to pay loans at their schedule
// - test for interest
// - test auction flow
// - create/cancel/end
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

    bytes32 testBondVaultHash =
        bytes32(
            0x54a8c0ab653c15bfb48b47fd011ba2b9617af01cb45cab344acd57c924d56798
        );

    uint256 appraiserPK = 0x1339;
    uint256 lenderPK = 0x1340;
    address appraiser = hevm.addr(appraiserPK);
    address lender = hevm.addr(lenderPK);

    event NewLoan(bytes32 bondVault, uint256 collateralVault, uint256 amount);
    event Repayment(bytes32 bondVault, uint256 collateralVault, uint256 amount);
    event Liquidation(bytes32 bondVault, uint256 collateralVault);
    event NewBondVault(
        address appraiser,
        bytes32 bondVault,
        bytes32 contentHash,
        uint256 expiration
    );
    event RedeemBond(
        bytes32 bondVault,
        uint256 amount,
        address indexed redeemer
    );

    function setUp() public {
        WETH9 = IWETH9(deployCode(weth9Artifact));

        MRA = new MultiRolesAuthority(address(this), Authority(address(0)));

        address liquidator = hevm.addr(0x1337); //remove

        STAR_NFT = new StarNFT(MRA, liquidator);

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
        _setupRolesAndCapabilities();
    }

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"
                )
            );
    }

    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155Received(address,address,uint256,uint256,bytes)"
                )
            );
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

    function _createWhitelist(address newNFT)
        internal
        returns (bytes32 root, bytes32[] memory proof)
    {
        string[] memory inputs = new string[](3);
        inputs[0] = "node";
        inputs[1] = "scripts/whitelistGenerator.js";
        inputs[2] = abi.encodePacked(newNFT).toHexString();

        bytes memory res = hevm.ffi(inputs);
        (root, proof) = abi.decode(res, (bytes32, bytes32[]));
    }

    /**
        Ensure our deposit function emits the correct events
        Ensure that the token Id's are correct
     */
    //    function _depositNFTs() internal {
    //        STAR_NFT.depositERC721(
    //            address(this),
    //            address(testNFT),
    //            uint256(1),
    //            nftProof
    //        );
    //        STAR_NFT.depositERC721(
    //            address(this),
    //            address(testNFT),
    //            uint256(2),
    //            nftProof
    //        );
    //    }
    /**
        Ensure our deposit function emits the correct events
        Ensure that the token Id's are correct
     */

    function _depositNFTs(address tokenContract, uint256 tokenId) internal {
        ERC721(tokenContract).setApprovalForAll(address(STAR_NFT), true);
        (bytes32 root, bytes32[] memory proof) = _createWhitelist(
            tokenContract
        );
        STAR_NFT.setSupportedRoot(root);
        STAR_NFT.depositERC721(
            address(this),
            address(tokenContract),
            uint256(tokenId),
            proof
        );
    }

    //TODO: start filling out the following tests
    /**
        Ensure that we can create a new bond vault and we emit the correct events
     */
    function _createBondVault(bytes32 _rootHash) internal {
        bytes32 hash = keccak256(
            BOND_CONTROLLER.encodeBondVaultHash(
                appraiser,
                _rootHash,
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
            _rootHash,
            block.timestamp + 30 days,
            block.timestamp + 35 days,
            block.timestamp + 60 days,
            bytes32("0x12345"),
            v,
            r,
            s
        );
    }

    function _generateLoanProof(
        uint256 _collateralVault,
        uint256 valuation,
        uint256 interest,
        uint256 start,
        uint256 end,
        uint8 lienPosition,
        uint256 schedule
    ) internal returns (bytes32 rootHash, bytes32[] memory proof) {
        (address tokenContract, uint256 tokenId) = STAR_NFT
            .getUnderlyingFromStar(_collateralVault);
        string[] memory inputs = new string[](10);
        //address, tokenId, valuation, interest, start, stop, lienPosition, schedule

        inputs[0] = "node";
        inputs[1] = "scripts/loanProofGenerator.js";
        inputs[2] = abi.encodePacked(tokenContract).toHexString(); //tokenContract
        inputs[3] = abi.encodePacked(tokenId).toHexString(); //tokenId
        inputs[4] = abi.encodePacked(valuation).toHexString(); //valuation
        inputs[5] = abi.encodePacked(interest).toHexString(); //interest
        inputs[6] = abi.encodePacked(start).toHexString(); //start
        inputs[7] = abi.encodePacked(end).toHexString(); //stop
        inputs[8] = abi.encodePacked(lienPosition).toHexString(); //lienPosition
        inputs[9] = abi.encodePacked(schedule).toHexString(); //schedule

        bytes memory res = hevm.ffi(inputs);
        (rootHash, proof) = abi.decode(res, (bytes32, bytes32[]));
    }

    function _hijackNFT(address tokenContract, uint256 tokenId) internal {
        ERC721 hijack = ERC721(tokenContract);

        address currentOwner = hijack.ownerOf(tokenId);
        hevm.startPrank(currentOwner);
        hijack.transferFrom(currentOwner, address(this), tokenId);
        hevm.stopPrank();
    }

    /**
       Ensure that we can borrow capital from the bond controller
       ensure that we're emitting the correct events
       ensure that we're repaying the proper collateral
   */
    function testCommitToLoan() public {
        address tokenContract = address(
            0x938e5ed128458139A9c3306aCE87C60BCBA9c067
        );
        uint256 tokenId = uint256(10);

        _hijackNFT(tokenContract, tokenId);
        _commitToLoan(tokenContract, tokenId);
    }

    function _commitToLoan(address tokenContract, uint256 tokenId) internal {
        _depositNFTs(
            tokenContract, //based ghoul
            tokenId
        );
        uint256 collateralVault = uint256(
            keccak256(
                abi.encodePacked(
                    tokenContract, //based ghoul
                    tokenId
                )
            )
        );

        uint256 maxAmount = uint256(100000000000000000000);
        uint256 interestRate = uint256(50000000000000000000);
        uint256 start = uint256(1651810553);
        uint256 end = uint256(1665029753);
        uint256 amount = uint256(1 ether);
        uint8 lienPosition = uint8(0);
        uint256 schedule = uint256(0);
        (bytes32 vaultHash, bytes32[] memory proof) = _generateLoanProof(
            collateralVault,
            maxAmount,
            interestRate,
            start,
            end,
            lienPosition,
            schedule
        );

        _createBondVault(vaultHash);
        hevm.deal(lender, 1000 ether);
        hevm.startPrank(lender);
        WETH9.deposit{value: 50 ether}();
        WETH9.approve(address(BOND_CONTROLLER), type(uint256).max);
        BOND_CONTROLLER.lendToVault(vaultHash, 50 ether);
        hevm.stopPrank();

        //event NewLoan(bytes32 bondVault, uint256 collateralVault, uint256 amount);
        hevm.expectEmit(true, true, false, false);
        emit NewLoan(vaultHash, collateralVault, amount);
        BOND_CONTROLLER.commitToLoan(
            proof,
            vaultHash,
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
        Dummy721 releaseTest = new Dummy721();
        address tokenContract = address(releaseTest);
        uint256 tokenid = uint256(1);
        _depositNFTs(tokenContract, tokenid);
        STAR_NFT.releaseToAddress(
            uint256(keccak256(abi.encodePacked(tokenContract, tokenid))),
            address(this)
        );
    }

    /**
        Ensure that asset's that have liens cannot be released to Anyone.
     */
    function testLiens() public {
        //trigger loan commit
        //try to release asset

        Dummy721 lienTest = new Dummy721();
        address tokenContract = address(address(lienTest));
        uint256 tokenId = uint256(1);

        _commitToLoan(tokenContract, tokenId);
        hevm.expectRevert(bytes("must be no liens to call this"));
        STAR_NFT.releaseToAddress(
            uint256(keccak256(abi.encodePacked(tokenContract, tokenId))),
            address(this)
        );
    }

    /**
        Ensure that we can auction underlying vaults
        ensure that we're emitting the correct events
        ensure that we're repaying the proper collateral

    */
    //    function testAuctionVault() public {
    //        //setup bondvault,
    //        //        BOND_CONTROLLER.liquidate(testBondVaultHash, uint256(0), uint256(1));
    //    }

    /**
        Ensure that owner of the token can cancel the auction by repaying the reserve(sum of debt + fee)
        ensure that we're emitting the correct events

    */
    //    function testCancelAuction() public {
    //        //needs helper that moves collateral into default
    //        //trigger liquidate
    //        //cancel auction as holder
    //    }
}
