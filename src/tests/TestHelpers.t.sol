pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {CollateralVault} from "../CollateralVault.sol";
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
    struct LoanTerms {
        uint256 maxAmount;
        uint256 maxDebt;
        uint256 interestRate;
        uint256 maxInterestRate;
        uint256 duration;
        uint256 amount;
        uint256 schedule;
    }

    LoanTerms defaultTerms =
        LoanTerms({
            maxAmount: uint256(100000000000000000000),
            maxDebt: uint256(10000000000000000000),
            interestRate: uint256(50000000000000000000),
            maxInterestRate: uint256(500000000000000000000),
            duration: uint256(block.timestamp + 10 minutes),
            amount: uint256(1 ether),
            schedule: uint256(50 ether)
        });

    // modifier validateLoanTerms(LoanTerms memory terms) {

    // }

    event Dummy();
    event NewLien(uint256 lienId);

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
    address appraiserThree = vm.addr(0x1345);

    event NewTermCommitment(
        bytes32 bondVault,
        uint256 collateralVault,
        uint256 amount
    );
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

    function setUp() public virtual {
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

        COLLATERAL_VAULT.file(
            bytes32("setBondController"),
            abi.encode(address(BOND_CONTROLLER))
        );
        COLLATERAL_VAULT.file(
            bytes32("setAuctionHouse"),
            abi.encode(address(AUCTION_HOUSE))
        );

        // COLLATERAL_VAULT.setBondController(address(BOND_CONTROLLER));
        // COLLATERAL_VAULT.setAuctionHouse(address(AUCTION_HOUSE));

        bool seaportActive;
        address seaport = address(0x00000000006c3852cbEf3e08E8dF289169EdE581);
        bytes32 codeHash;
        assembly {
            codeHash := extcodehash(seaport)
        }

        if (codeHash != 0x0) {
            bytes memory seaportAddr = abi.encode(
                address(0x00000000006c3852cbEf3e08E8dF289169EdE581)
            );
            COLLATERAL_VAULT.file(bytes32("setupSeaport"), seaportAddr);
            // COLLATERAL_VAULT.setupSeaport(
            //     address(0x00000000006c3852cbEf3e08E8dF289169EdE581)
            // );
        }

        LIEN_TOKEN.file(
            bytes32("setAuctionHouse"),
            abi.encode(address(AUCTION_HOUSE))
        );
        LIEN_TOKEN.file(
            bytes32("setCollateralVault"),
            abi.encode(address(COLLATERAL_VAULT))
        );

        // LIEN_TOKEN.setAuctionHouse(address(AUCTION_HOUSE));
        // LIEN_TOKEN.setCollateralVault(address(COLLATERAL_VAULT));
        _setupRolesAndCapabilities();
        _setupAppraisers();
    }

    function _setupAppraisers() internal {
        address[] memory appraisers = new address[](2);
        appraisers[0] = appraiserOne;
        appraisers[1] = appraiserTwo;

        BOND_CONTROLLER.file(bytes32("setAppraisers"), abi.encode(appraisers));

        // BOND_CONTROLLER.setAppraisers(appraisers);
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
        COLLATERAL_VAULT.file(bytes32("setSupportedRoot"), abi.encode(root));
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

    function _createBondVault(bytes32 vaultHash, bool vault) internal {
        if (vault) {
            return
                _createBondVault(
                    appraiserTwo, // appraiserTwo for vault
                    block.timestamp + 30 days, //expiration
                    block.timestamp + 1 days, //deadline
                    uint256(10), //buyout
                    vaultHash,
                    appraiserTwoPK
                );
        } else {
            _createBondVault(
                appraiserOne, // appraiserOne for solo vault
                block.timestamp + 30 days, //expiration
                block.timestamp + 1 days, //deadline
                uint256(10), //buyout
                vaultHash,
                appraiserOnePK
            );
        }
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
                BOND_CONTROLLER.appraiserNonce(appraiser),
                deadline,
                buyout
            )
        );
        uint8 v;
        bytes32 r;
        bytes32 s;

        (v, r, s) = vm.sign(uint256(appraiserPk), hash);

        IBrokerRouter.BrokerParams memory params = IBrokerRouter.BrokerParams(
            appraiser,
            _rootHash,
            expiration,
            deadline,
            buyout,
            bytes32("0x12345"),
            v,
            r,
            s
        );
        if (appraiser == appraiserOne) {
            BOND_CONTROLLER.newSoloVault(params);
        } else {
            BOND_CONTROLLER.newBondVault(params);
        }
    }

    function _generateLoanProof(
        uint256 _collateralVault,
        LoanTerms memory terms
    ) internal returns (bytes32 rootHash, bytes32[] memory proof) {
        return
            _generateLoanProof(
                _collateralVault,
                terms.maxAmount,
                terms.maxDebt,
                terms.interestRate,
                terms.maxInterestRate,
                terms.duration,
                terms.schedule
            );
    }

    function _generateLoanProof(
        uint256 _collateralVault,
        uint256 maxAmount,
        uint256 maxDebt,
        uint256 interest,
        uint256 maxInterest,
        uint256 duration,
        uint256 schedule
    ) internal returns (bytes32 rootHash, bytes32[] memory proof) {
        (address tokenContract, uint256 tokenId) = COLLATERAL_VAULT
            .getUnderlying(_collateralVault);
        string[] memory inputs = new string[](10);
        //address, tokenId, maxAmount, interest, duration, lienPosition, schedule

        inputs[0] = "node";
        inputs[1] = "scripts/loanProofGenerator.js";
        inputs[2] = abi.encodePacked(tokenContract).toHexString(); //tokenContract
        inputs[3] = abi.encodePacked(tokenId).toHexString(); //tokenId
        inputs[4] = abi.encodePacked(maxAmount).toHexString(); //valuation
        inputs[5] = abi.encodePacked(maxDebt).toHexString(); //valuation
        inputs[6] = abi.encodePacked(interest).toHexString(); //interest
        inputs[7] = abi.encodePacked(maxInterest).toHexString(); //interest
        inputs[8] = abi.encodePacked(duration).toHexString(); //stop
        inputs[9] = abi.encodePacked(schedule).toHexString(); //schedule

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

    function _commitToLoan(
        address tokenContract,
        uint256 tokenId,
        uint256 maxAmount,
        uint256 maxDebt,
        uint256 interestRate,
        uint256 maxInterestRate,
        uint256 duration,
        uint256 amount,
        uint256 schedule
    ) internal returns (bytes32 vaultHash, IBrokerRouter.Terms memory terms) {
        _depositNFTs(
            tokenContract, //based ghoul
            tokenId
        );

        // return
        //     _commitWithoutDeposit(
        //         tokenContract,
        //         tokenId,
        //         maxAmount,
        //         interestRate,
        //         duration,
        //         amount,
        //         lienPosition,
        //         schedule
        //     );

        address broker;

        (vaultHash, terms, broker) = _commitWithoutDeposit(
            tokenContract,
            tokenId,
            maxAmount,
            maxDebt,
            interestRate,
            maxInterestRate,
            duration,
            amount,
            schedule
        );

        // vm.expectEmit(true, true, false, false);
        // emit NewTermCommitment(vaultHash, collateralVault, amount);
        BrokerImplementation(broker).commitToLoan(terms, amount, address(this));
        // BrokerVault(broker).withdraw(0 ether);

        return (vaultHash, terms);
    }

    function _commitToLoan(
        address tokenContract,
        uint256 tokenId,
        LoanTerms memory loanTerms
    ) internal returns (bytes32 vaultHash, IBrokerRouter.Terms memory terms) {
        _depositNFTs(
            tokenContract, //based ghoul
            tokenId
        );

        address broker;

        (vaultHash, terms, broker) = _commitWithoutDeposit(
            tokenContract,
            tokenId,
            loanTerms.maxAmount,
            loanTerms.maxDebt,
            loanTerms.interestRate,
            loanTerms.maxInterestRate,
            loanTerms.duration,
            loanTerms.amount,
            loanTerms.schedule
        );
        BrokerImplementation(broker).commitToLoan(
            terms,
            loanTerms.amount,
            address(this)
        );

        return (vaultHash, terms);
    }

    function _commitWithoutDeposit(
        address tokenContract,
        uint256 tokenId,
        LoanTerms memory loanTerms
    )
        internal
        returns (
            bytes32 vaultHash,
            IBrokerRouter.Terms memory terms,
            address broker
        )
    {
        return
            _commitWithoutDeposit(
                tokenContract,
                tokenId,
                loanTerms.maxAmount,
                loanTerms.maxDebt,
                loanTerms.interestRate,
                loanTerms.maxInterestRate,
                loanTerms.duration,
                loanTerms.amount,
                loanTerms.schedule
            );
    }

    // TODO clean up flow, for now makes refinancing more convenient
    function _commitWithoutDeposit(
        address tokenContract,
        uint256 tokenId,
        uint256 maxAmount,
        uint256 maxDebt,
        uint256 interestRate,
        uint256 maxInterestRate,
        uint256 duration,
        uint256 amount,
        uint256 schedule
    )
        internal
        returns (
            bytes32 vaultHash,
            IBrokerRouter.Terms memory terms,
            address broker
        )
    {
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
            maxDebt,
            interestRate,
            maxInterestRate,
            duration,
            schedule
        );

        _createBondVault(vaultHash, true);

        _lendToVault(vaultHash, uint256(500 ether), appraiserTwo);

        address broker = BOND_CONTROLLER.getBroker(vaultHash);
        IBrokerRouter.Terms memory terms = IBrokerRouter.Terms(
            broker,
            address(WETH9),
            proof,
            collateralVault,
            maxAmount,
            maxDebt,
            interestRate,
            maxInterestRate,
            duration,
            schedule
        );

        return (vaultHash, terms, broker);
    }

    // struct LoanTerms {
    //     uint256 maxAmount;
    //     uint256 interestRate;
    //     uint256 duration;
    //     uint256 amount;
    //     uint256 lienPosition;
    //     uint256 schedule;
    // }

    function _refinanceLoan(
        address tokenContract,
        uint256 tokenId,
        LoanTerms memory oldTerms,
        LoanTerms memory newTerms
    ) internal {
        _commitToLoan(tokenContract, tokenId, oldTerms);

        _commitWithoutDeposit(tokenContract, tokenId, newTerms);
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
        (
            uint256 amount,
            uint256 duration,
            uint256 firstBidTime,
            uint256 reservePrice,
            address bidder
        ) = AUCTION_HOUSE.getAuctionData(collateralVault);
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
        AUCTION_HOUSE.createBid(tokenId, amount);
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
        // BOND_CONTROLLER.getBroker(vaultHash).withdraw(uint256(0));

        vm.stopPrank();
    }

    function _withdraw(
        bytes32 vaultHash,
        uint256 amount,
        address lendAs
    ) internal {
        vm.startPrank(lendAs);

        vm.stopPrank();
    }
}