pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {ICollateralVault, CollateralVault, LienToken, ILienToken} from "../CollateralVault.sol";
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

//TODO:
// - setup helpers to repay loans
// - setup helpers to pay loans at their schedule
// - test for interest
contract TestHelpers is Test {
    enum UserRoles {
        ADMIN,
        BOND_CONTROLLER,
        WRAPPER,
        AUCTION_HOUSE,
        TRANSFER_PROXY
    }

    using Strings2 for bytes;
    CollateralVault COLLATERAL_VAULT;
    LienToken LIEN_TOKEN;
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
        LIEN_TOKEN = new LienToken(
            MRA,
            address(TRANSFER_PROXY),
            address(WETH9)
        );
        COLLATERAL_VAULT = new CollateralVault(
            MRA,
            address(TRANSFER_PROXY),
            address(LIEN_TOKEN)
        );
        SoloBroker soloImpl = new SoloBroker();
        BrokerVault vaultImpl = new BrokerVault();

        BOND_CONTROLLER = new BrokerRouter(
            MRA,
            address(WETH9),
            address(COLLATERAL_VAULT),
            address(LIEN_TOKEN),
            address(TRANSFER_PROXY),
            address(vaultImpl),
            address(soloImpl)
        );

        AUCTION_HOUSE = new AuctionHouse(
            address(WETH9),
            address(MRA),
            address(COLLATERAL_VAULT),
            address(LIEN_TOKEN),
            address(TRANSFER_PROXY)
        );

        COLLATERAL_VAULT.setBondController(address(BOND_CONTROLLER));
        COLLATERAL_VAULT.setAuctionHouse(address(AUCTION_HOUSE));
        _setupRolesAndCapabilities();
        _setupAppraisers();
    }

    function _setupAppraisers() internal {
        address[] memory appraisers = new address[](2);
        appraisers[0] = appraiserOne;
        appraisers[1] = appraiserTwo;

        BOND_CONTROLLER.setAppraisers(appraisers);
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
            uint8(UserRoles.BOND_CONTROLLER),
            LienToken.createLien.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.WRAPPER),
            AuctionHouse.cancelAuction.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.BOND_CONTROLLER),
            CollateralVault.auctionVault.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.BOND_CONTROLLER),
            TRANSFER_PROXY.tokenTransferFrom.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.AUCTION_HOUSE),
            LienToken.removeLiens.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.AUCTION_HOUSE),
            LienToken.stopLiens.selector,
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
        MRA.setUserRole(
            address(COLLATERAL_VAULT),
            uint8(UserRoles.WRAPPER),
            true
        );
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
        ERC721(tokenContract).setApprovalForAll(
            address(COLLATERAL_VAULT),
            true
        );
        (bytes32 root, bytes32[] memory proof) = _createWhitelist(
            tokenContract
        );
        COLLATERAL_VAULT.setSupportedRoot(root);
        COLLATERAL_VAULT.depositERC721(
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
            IBrokerRouter.BrokerParams(
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
        (address tokenContract, uint256 tokenId) = COLLATERAL_VAULT
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

    function _commitToLoan(address tokenContract, uint256 tokenId)
        internal
        returns (bytes32 vaultHash, ICollateralVault.Terms memory)
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

    function _commitToLoan(
        address tokenContract,
        uint256 tokenId,
        uint256 maxAmount,
        uint256 interestRate,
        uint256 duration,
        uint256 amount,
        uint256 lienPosition,
        uint256 schedule
    ) internal returns (bytes32 vaultHash, ICollateralVault.Terms memory) {
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

        //        terms = ICollateralVault.Terms(
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

        _lendToVault(vaultHash, uint256(500 ether), appraiserOne);

        //event NewLoan(bytes32 bondVault, uint256 collateralVault, uint256 amount);
        vm.expectEmit(true, true, false, false);
        emit NewLoan(vaultHash, collateralVault, amount);
        address broker = BOND_CONTROLLER.getBroker(vaultHash);
        ICollateralVault.Terms memory terms = ICollateralVault.Terms(
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

    function _warpToMaturity(uint256 collateralVault, uint256 position)
        internal
    {
        ILienToken.Lien memory lien = LIEN_TOKEN.getLien(
            collateralVault,
            position
        );
        vm.warp(block.timestamp + lien.start + lien.duration + 2 days);
    }

    function _warpToAuctionEnd(uint256 collateralVault) internal {
        uint256 auctionId = COLLATERAL_VAULT.starIdToAuctionId(collateralVault);
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

    function _createBid(
        address bidder,
        uint256 tokenId,
        uint256 amount
    ) internal {
        vm.deal(bidder, (amount * 15) / 10);
        vm.startPrank(bidder);
        WETH9.deposit{value: amount}();
        WETH9.approve(address(TRANSFER_PROXY), amount);
        uint256 auctionId = COLLATERAL_VAULT.starIdToAuctionId(tokenId);
        AUCTION_HOUSE.createBid(auctionId, amount);
        vm.stopPrank();
    }

    function _lendToVault(
        bytes32 vaultHash,
        uint256 amount,
        address lendAs
    ) internal {
        vm.deal(lendAs, amount);
        vm.startPrank(lendAs);
        WETH9.deposit{value: amount}();
        WETH9.approve(
            address(BOND_CONTROLLER.getBroker(vaultHash)),
            type(uint256).max
        );
        //        BOND_CONTROLLER.lendToVault(vaultHash, amount);
        IBroker(BOND_CONTROLLER.getBroker(vaultHash)).deposit(amount, lendAs);
        vm.stopPrank();
    }
}
