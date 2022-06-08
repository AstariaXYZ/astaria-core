pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {IStarNFT, StarNFT} from "../StarNFT.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {IBrokerRouter, BrokerRouter} from "../BrokerRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {Strings2} from "./utils/Strings2.sol";
import {BrokerImplementation} from "../BrokerImplementation.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {BeaconProxy} from "openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

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

// contract Test is DSTestPlus {
//     function deployCode(string memory what) public returns (address addr) {
//         bytes memory bytecode = vm.getCode(what);
//         assembly {
//             addr := create(0, add(bytecode, 0x20), mload(bytecode))
//         }
//     }
// }

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
        AUCTION_HOUSE,
        TRANSFER_PROXY
    }

    using Strings2 for bytes;
    StarNFT STAR_NFT;
    BrokerRouter BOND_CONTROLLER;
    Dummy721 testNFT;
    TransferProxy TRANSFER_PROXY;
    IWETH9 WETH9;
    MultiRolesAuthority MRA;
    AuctionHouse AUCTION_HOUSE;
    bytes32 public whiteListRoot;
    bytes32[] public nftProof;

    bytes32 testBondVaultHash =
        bytes32(
            0x54a8c0ab653c15bfb48b47fd011ba2b9617af01cb45cab344acd57c924d56798
        );
    uint256 appraiserOnePK = uint256(0x1339);
    uint256 appraiserTwoPK = uint256(0x1344);
    address appraiserOne = vm.addr(appraiserOnePK);
    address lender = vm.addr(0x1340);
    address borrower = vm.addr(0x1341);
    address bidderOne = vm.addr(0x1342);
    address bidderTwo = vm.addr(0x1343);
    address appraiserTwo = vm.addr(appraiserTwoPK);
    address appraisterThree = vm.addr(0x1345);

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

        address liquidator = vm.addr(0x1337); //remove

        TRANSFER_PROXY = new TransferProxy(MRA);
        STAR_NFT = new StarNFT(MRA, address(TRANSFER_PROXY));
        BrokerImplementation implementation = new BrokerImplementation();

        BOND_CONTROLLER = new BrokerRouter(
            address(WETH9),
            address(STAR_NFT),
            address(TRANSFER_PROXY),
            address(implementation)
        );

        AUCTION_HOUSE = new AuctionHouse(
            address(WETH9),
            address(MRA),
            address(STAR_NFT),
            address(TRANSFER_PROXY)
        );

        STAR_NFT.setBondController(address(BOND_CONTROLLER));
        STAR_NFT.setAuctionHouse(address(AUCTION_HOUSE));
        _setupRolesAndCapabilities();
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
        MRA.setRoleCapability(
            uint8(UserRoles.BOND_CONTROLLER),
            TRANSFER_PROXY.tokenTransferFrom.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.AUCTION_HOUSE),
            TRANSFER_PROXY.tokenTransferFrom.selector,
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

        bytes memory res = vm.ffi(inputs);
        (root, proof) = abi.decode(res, (bytes32, bytes32[]));
    }

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

    /**
        Ensure that we can create a new bond vault and we emit the correct events
     */

    function _createBondVault(bytes32 vaultHash) internal {
        return
            _createBondVault(
                appraiserOne,
                block.timestamp + 30 days, //expiration
                block.timestamp + 1 days, //deadline
                uint256(10), //buyout
                vaultHash,
                appraiserOnePK
            );
    }

    function _createBondVault(
        address appraiser,
        uint256 expiration,
        uint256 deadline,
        uint256 buyout,
        bytes32 _rootHash,
        uint256 appraiserPk
    ) internal {
        bytes32 hash = keccak256(
            BOND_CONTROLLER.encodeBondVaultHash(
                appraiser,
                _rootHash,
                expiration,
                BOND_CONTROLLER.appraiserNonces(appraiser),
                deadline,
                buyout
            )
        );
        uint8 v;
        bytes32 r;
        bytes32 s;

        (v, r, s) = vm.sign(uint256(appraiserPk), hash);

        BOND_CONTROLLER.newBondVault(
            IBrokerRouter.NewBondVaultParams(
                appraiser,
                _rootHash,
                expiration,
                deadline,
                buyout,
                bytes32("0x12345"),
                v,
                r,
                s
            )
        );
    }

    function _generateLoanProof(
        uint256 _collateralVault,
        uint256 maxAmount,
        uint256 interest,
        uint256 duration,
        uint256 lienPosition,
        uint256 schedule
    ) internal returns (bytes32 rootHash, bytes32[] memory proof) {
        (address tokenContract, uint256 tokenId) = STAR_NFT
            .getUnderlyingFromStar(_collateralVault);
        string[] memory inputs = new string[](9);
        //address, tokenId, maxAmount, interest, duration, lienPosition, schedule

        inputs[0] = "node";
        inputs[1] = "scripts/loanProofGenerator.js";
        inputs[2] = abi.encodePacked(tokenContract).toHexString(); //tokenContract
        inputs[3] = abi.encodePacked(tokenId).toHexString(); //tokenId
        inputs[4] = abi.encodePacked(maxAmount).toHexString(); //valuation
        inputs[5] = abi.encodePacked(interest).toHexString(); //interest
        inputs[6] = abi.encodePacked(duration).toHexString(); //stop
        inputs[7] = abi.encodePacked(lienPosition).toHexString(); //lienPosition
        inputs[8] = abi.encodePacked(schedule).toHexString(); //schedule

        bytes memory res = vm.ffi(inputs);
        (rootHash, proof) = abi.decode(res, (bytes32, bytes32[]));
    }

    function _hijackNFT(address tokenContract, uint256 tokenId) internal {
        ERC721 hijack = ERC721(tokenContract);

        address currentOwner = hijack.ownerOf(tokenId);
        vm.startPrank(currentOwner);
        hijack.transferFrom(currentOwner, address(this), tokenId);
        vm.stopPrank();
    }

    /**
       Ensure that we can borrow capital from the bond controller
       ensure that we're emitting the correct events
       ensure that we're repaying the proper collateral
   */
    function testCommitToLoan() public {
        //        address tokenContract = address(
        //            0x938e5ed128458139A9c3306aCE87C60BCBA9c067
        //        );
        //        uint256 tokenId = uint256(10);
        //
        //        _hijackNFT(tokenContract, tokenId);

        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(address(loanTest));
        uint256 tokenId = uint256(1);
        uint256 maxAmount = uint256(100000000000000000000);
        uint256 interestRate = uint256(50000000000000000000);
        uint256 duration = uint256(block.timestamp + 10 minutes);
        uint256 amount = uint256(1 ether);
        uint8 lienPosition = uint8(0);
        uint256 schedule = uint256(50);

        uint256 balanceBefore = WETH9.balanceOf(address(this));
        //balance of WETH before loan
        (bytes32 vaultHash, ) = _commitToLoan(
            tokenContract,
            tokenId,
            maxAmount,
            interestRate,
            duration,
            amount,
            lienPosition,
            schedule
        );

        //assert weth balance is before + 1 ether
        assert(WETH9.balanceOf(address(this)) == balanceBefore + 1 ether);
    }

    function _lendToVault(bytes32 vaultHash, uint256 amount) internal {
        vm.deal(lender, amount);
        vm.startPrank(lender);
        WETH9.deposit{value: amount}();
        WETH9.approve(
            address(BOND_CONTROLLER.getBroker(vaultHash)),
            type(uint256).max
        );
        //        BOND_CONTROLLER.lendToVault(vaultHash, amount);
        BrokerImplementation(BOND_CONTROLLER.getBroker(vaultHash)).deposit(
            amount,
            address(this)
        );
        vm.stopPrank();
    }

    function _commitToLoan(address tokenContract, uint256 tokenId)
        internal
        returns (bytes32 vaultHash, IStarNFT.Terms memory)
    {
        return
            _commitToLoan(
                tokenContract,
                tokenId,
                uint256(100000000000000000000),
                uint256(50000000000000000000),
                uint256(block.timestamp + 10 minutes),
                uint256(1 ether),
                uint256(0),
                uint256(50 ether)
            );
    }

    event LogStuff(address);

    function _commitToLoan(
        address tokenContract,
        uint256 tokenId,
        uint256 maxAmount,
        uint256 interestRate,
        uint256 duration,
        uint256 amount,
        uint256 lienPosition,
        uint256 schedule
    ) internal returns (bytes32 vaultHash, IStarNFT.Terms memory) {
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

        bytes32[] memory proof;
        (vaultHash, proof) = _generateLoanProof(
            collateralVault,
            maxAmount,
            interestRate,
            duration,
            lienPosition,
            schedule
        );

        //        terms = IStarNFT.Terms(
        //            broker,
        //            proof,
        //            collateralVault,
        //            maxAmount,
        //            interestRate,
        //            duration,
        //            lienPosition,
        //            schedule
        //        );

        {
            _createBondVault(
                appraiserOne,
                block.timestamp + 30 days, //expiration
                block.timestamp + 1 days, //deadline
                uint256(10), //buyout
                vaultHash,
                appraiserOnePK
            );
        }

        _lendToVault(vaultHash, uint256(500 ether));

        //event NewLoan(bytes32 bondVault, uint256 collateralVault, uint256 amount);
        vm.expectEmit(true, true, false, false);
        emit NewLoan(vaultHash, collateralVault, amount);
        address broker = BOND_CONTROLLER.getBroker(vaultHash);
        IStarNFT.Terms memory terms = IStarNFT.Terms(
            broker,
            proof,
            collateralVault,
            maxAmount,
            interestRate,
            duration,
            lienPosition,
            schedule
        );
        BrokerImplementation(broker).commitToLoan(terms, amount, address(this));
        return (vaultHash, terms);
    }

    function testReleaseToAddress() public {
        Dummy721 releaseTest = new Dummy721();
        address tokenContract = address(releaseTest);
        uint256 tokenId = uint256(1);
        _depositNFTs(tokenContract, tokenId);
        // startMeasuringGas("ReleaseTo Address");

        STAR_NFT.releaseToAddress(
            uint256(keccak256(abi.encodePacked(tokenContract, tokenId))),
            address(this)
        );
        // stopMeasuringGas();
    }

    /**
        Ensure that asset's that have liens cannot be released to Anyone.
     */
    function testLiens() public {
        //trigger loan commit
        //try to release asset

        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(address(loanTest));
        uint256 tokenId = uint256(1);
        uint256 maxAmount = uint256(100000000000000000000);
        uint256 interestRate = uint256(50000000000000000000);
        uint256 duration = uint256(block.timestamp + 10 minutes);
        uint256 amount = uint256(1 ether);
        uint8 lienPosition = uint8(0);
        uint256 schedule = uint256(50);
        (bytes32 vaultHash, IStarNFT.Terms memory terms) = _commitToLoan(
            tokenContract,
            tokenId,
            maxAmount,
            interestRate,
            duration,
            amount,
            lienPosition,
            schedule
        );
        vm.expectRevert(bytes("must be no liens to call this"));

        STAR_NFT.releaseToAddress(
            uint256(keccak256(abi.encodePacked(tokenContract, tokenId))),
            address(this)
        );
    }

    function _warpToMaturity(uint256 collateralVault, uint256 position)
        internal
    {
        StarNFT.Lien memory lien = STAR_NFT.getLien(collateralVault, position);
        vm.warp(block.timestamp + lien.end + 2 days);
    }

    function _warpToAuctionEnd(uint256 collateralVault) internal {
        uint256 auctionId = STAR_NFT.starIdToAuctionId(collateralVault);
        (
            uint256 tokenId,
            uint256 amount,
            uint256 duration,
            uint256 firstBidTime,
            uint256 reservePrice,
            address bidder
        ) = AUCTION_HOUSE.getAuctionData(auctionId);
        vm.warp(block.timestamp + duration);
    }

    /**
        Ensure that we can auction underlying vaults
        ensure that we're emitting the correct events
        ensure that we're repaying the proper collateral

    */

    struct TestAuctionVaultResponse {
        bytes32 hash;
        uint256 collateralVault;
        uint256 reserve;
    }

    function testAuctionVault()
        public
        returns (TestAuctionVaultResponse memory)
    {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(address(loanTest));
        uint256 tokenId = uint256(1);
        uint256 maxAmount = uint256(100000000000000000000);
        uint256 interestRate = uint256(50000000000000000000);
        uint256 duration = uint256(block.timestamp + 10 minutes);
        uint256 amount = uint256(1 ether);
        uint8 lienPosition = uint8(0);
        uint256 schedule = uint256(50);
        (bytes32 vaultHash, IStarNFT.Terms memory terms) = _commitToLoan(
            tokenContract,
            tokenId,
            maxAmount,
            interestRate,
            duration,
            amount,
            lienPosition,
            schedule
        );
        uint256 starId = uint256(
            keccak256(abi.encodePacked(tokenContract, tokenId))
        );
        _warpToMaturity(starId, uint256(0));
        address broker = BOND_CONTROLLER.getBroker(vaultHash);
        uint256 reserve = BOND_CONTROLLER.liquidate(terms);
        //        return (vaultHash, starId, reserve);
        return TestAuctionVaultResponse(vaultHash, starId, reserve);
    }

    /**
        Ensure that owner of the token can cancel the auction by repaying the reserve(sum of debt + fee)
        ensure that we're emitting the correct events

    */
    function testCancelAuction() public {
        TestAuctionVaultResponse memory response = testAuctionVault();
        vm.deal(address(this), response.reserve);
        WETH9.deposit{value: response.reserve}();
        WETH9.approve(address(TRANSFER_PROXY), response.reserve);
        STAR_NFT.cancelAuction(response.collateralVault);
    }

    function _createBid(
        address bidder,
        uint256 tokenId,
        uint256 amount
    ) internal {
        vm.deal(bidder, (amount * 15) / 10);
        vm.startPrank(bidder);
        WETH9.deposit{value: amount}();
        WETH9.approve(address(TRANSFER_PROXY), amount);
        uint256 auctionId = STAR_NFT.starIdToAuctionId(tokenId);
        AUCTION_HOUSE.createBid(auctionId, amount);
        vm.stopPrank();
    }

    function testEndAuctionWithBids() public {
        TestAuctionVaultResponse memory response = testAuctionVault();
        _createBid(bidderOne, response.collateralVault, response.reserve);
        _createBid(
            bidderTwo,
            response.collateralVault,
            response.reserve += ((response.reserve * 5) / 100)
        );
        _createBid(
            bidderOne,
            response.collateralVault,
            response.reserve += ((response.reserve * 30) / 100)
        );
        _warpToAuctionEnd(response.collateralVault);
        STAR_NFT.endAuction(response.collateralVault);
    }

    function testRefinanceLoan() public {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(address(loanTest));
        uint256 tokenId = uint256(1);

        uint256[] memory loanDetails = new uint256[](6);
        loanDetails[0] = uint256(100000000000000000000); //maxAmount
        loanDetails[1] = uint256(50000000000000000000); //interestRate
        loanDetails[2] = uint256(block.timestamp + 10 minutes); //duration
        loanDetails[3] = uint256(1 ether); //amount
        loanDetails[4] = uint256(0); //lienPosition
        loanDetails[5] = uint256(50); //schedule

        uint256[] memory loanDetails2 = new uint256[](6);
        loanDetails2[0] = uint256(100000000000000000000); //maxAmount
        loanDetails2[1] = uint256(10000000000000000000); //interestRate
        loanDetails2[2] = uint256(block.timestamp + 10 minutes * 2); //duration
        loanDetails2[3] = uint256(1 ether); //amount
        loanDetails2[4] = uint256(0); //lienPosition
        loanDetails2[5] = uint256(50); //schedule
        (bytes32 outgoing, IStarNFT.Terms memory terms) = _commitToLoan(
            tokenContract,
            tokenId,
            loanDetails[0],
            loanDetails[1],
            loanDetails[2],
            loanDetails[3],
            loanDetails[4],
            loanDetails[5]
        );

        uint256 collateralVault = uint256(
            keccak256(
                abi.encodePacked(
                    tokenContract, //based ghoul
                    tokenId
                )
            )
        );
        {
            (bytes32 incoming, bytes32[] memory newLoanProof) = _generateLoanProof(
                collateralVault,
                loanDetails2[0], //max amount
                loanDetails2[1], //interestRate
                loanDetails2[2], //duration
                loanDetails2[4], //lienPosition
                loanDetails2[5] //schedule
            );

            _createBondVault(
                appraiserTwo,
                block.timestamp + 30 days, //expiration
                block.timestamp + 1 days, //deadline
                uint256(10), //buyout
                incoming,
                appraiserTwoPK
            );

            _lendToVault(incoming, uint256(500 ether));

            vm.startPrank(appraiserTwo);
            bytes32[] memory dealBrokers = new bytes32[](2);
            dealBrokers[0] = outgoing;
            dealBrokers[1] = incoming;
            //            uint256[] memory collateralDetails = new uint256[](2);
            //            collateralDetails[0] = collateralVault;
            //            collateralDetails[1] = uint256(0);

            //            BrokerImplementation(BOND_CONTROLLER.getBroker(incoming))
            //                .buyoutLien(
            //                    collateralVault,
            //                    uint256(0),
            //                    newLoanProof,
            //                    loanDetails2
            //                );
            vm.stopPrank();
        }
    }

    // failure testing
    function testFailLendWithoutTransfer() public {
        WETH9.transfer(address(BOND_CONTROLLER), uint256(1));
        BrokerImplementation(BOND_CONTROLLER.getBroker(testBondVaultHash))
            .deposit(uint256(1), address(this));
    }

    function testFailLendWithNonexistentVault() public {
        BrokerRouter emptyController;
        //        emptyController.lendToVault(testBondVaultHash, uint256(1));
        BrokerImplementation(BOND_CONTROLLER.getBroker(testBondVaultHash))
            .deposit(uint256(1), address(this));
    }

    function testFailLendPastExpiration() public {
        _createBondVault(testBondVaultHash);
        vm.deal(lender, 1000 ether);
        vm.startPrank(lender);
        WETH9.deposit{value: 50 ether}();
        WETH9.approve(
            address(BOND_CONTROLLER.getBroker(testBondVaultHash)),
            type(uint256).max
        );

        vm.warp(block.timestamp + 10000 days); // forward past expiration date

        //        BOND_CONTROLLER.lendToVault(testBondVaultHash, 50 ether);
        BrokerImplementation(BOND_CONTROLLER.getBroker(testBondVaultHash))
            .deposit(50 ether, address(this));
        vm.stopPrank();
    }

    function testFailCommitToLoanNotOwner() public {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);
        vm.prank(address(1));
        (bytes32 vaultHash, ) = _commitToLoan(tokenContract, tokenId);
    }

    // fuzzers

    function testFuzzPermit(uint256 deadline) public {
        vm.assume(deadline > block.timestamp);

        // BOND_CONTROLLER.permit()

        // assertGt(deadline, block.timestamp); // delete
    }

    function testFuzzCommitToLoan(
        uint256 interestRate,
        uint256 duration,
        uint256 amount
    ) public {
        interestRate = bound(interestRate, 1e10, 1e30); // is this reasonable? (original tests were 1e20)
        duration = bound(
            duration,
            uint256(block.timestamp + 1 minutes),
            uint256(block.timestamp + 10 minutes)
        );

        uint256 maxAmount = uint256(100000000000000000000);

        // reverts with "Attempting to borrow more than available in the specified vault" starting at an upper bound of ~100 ether
        amount = bound(amount, 1 ether, 10 ether);

        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);

        (bytes32 vaultHash, IStarNFT.Terms memory terms) = _commitToLoan(
            tokenContract,
            tokenId,
            maxAmount,
            interestRate,
            duration,
            amount,
            uint256(0),
            uint256(50 ether)
        );
    }

    //    function testFuzzLendToVault(uint256 amount) public {
    //        amount = bound(amount, 1 ether, 20 ether); // starts failing at ~200 ether
    //
    //        Dummy721 lienTest = new Dummy721();
    //        address tokenContract = address(lienTest);
    //        uint256 tokenId = uint256(1);
    //
    //        bytes32 vaultHash = _commitToLoan(tokenContract, tokenId);
    //
    //        // _createBondVault(vaultHash);
    //        vm.deal(lender, 1000 ether);
    //        vm.startPrank(lender);
    //        WETH9.deposit{value: 50 ether}();
    //        WETH9.approve(address(BOND_CONTROLLER), type(uint256).max);
    //
    //        //        BOND_CONTROLLER.lendToVault(vaultHash, amount);
    //        BrokerImplementation(BOND_CONTROLLER.getBroker(vaultHash)).deposit(
    //            amount,
    //            address(this)
    //        );
    //        vm.stopPrank();
    //    }

    function testFuzzManageLiens(uint256 amount) public {}

    function testFuzzCreateAuction(uint256 reservePrice) public {}

    function testFuzzCreateBid(uint256 amount) public {}

    // TODO repayLoan() test(s)

    function testFuzzRefinanceLoan(uint256 newInterestRate, uint256 newDuration)
        public
    {}
}
