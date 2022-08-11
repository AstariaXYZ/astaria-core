pragma solidity ^0.8.15;

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
import {CollateralLookup} from "../libraries/CollateralLookup.sol";
import {ILienToken} from "../interfaces/ILienToken.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {IBrokerRouter, BrokerRouter} from "../BrokerRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {Strings2} from "./utils/Strings2.sol";
import {IBroker, BrokerImplementation} from "../BrokerImplementation.sol";
import {PublicVault} from "../PublicVault.sol";
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
    using CollateralLookup for address;

    enum StrategyTypes {
        STANDARD,
        COLLECTION,
        BORROWER
    }

    struct LoanTerms {
        uint256 maxAmount;
        uint256 maxDebt;
        uint256 interestRate;
        uint256 maxInterestRate;
        uint256 duration;
        uint256 amount;
    }

    LoanTerms defaultTerms =
        LoanTerms({
            maxAmount: uint256(10 ether),
            maxDebt: uint256(1 ether),
            interestRate: uint256(50000 gwei),
            maxInterestRate: uint256(75000 gwei),
            duration: uint256(block.timestamp + 10 minutes),
            amount: uint256(0.5 ether)
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
        TRANSFER_PROXY,
        LIEN_TOKEN
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
        //        SoloBroker soloImpl = new SoloBroker();
        PublicVault vaultImpl = new PublicVault();

        BOND_CONTROLLER = new BrokerRouter(
            MRA,
            address(WETH9),
            address(COLLATERAL_VAULT),
            address(LIEN_TOKEN),
            address(TRANSFER_PROXY),
            address(vaultImpl)
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

        // TODO add to AstariaDeploy(?)
        MRA.setRoleCapability(
            uint8(UserRoles.LIEN_TOKEN),
            TRANSFER_PROXY.tokenTransferFrom.selector,
            true
        );
        MRA.setUserRole(address(LIEN_TOKEN), uint8(UserRoles.LIEN_TOKEN), true);
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
     * Ensure our deposit function emits the correct events
     * Ensure that the token Id's are correct
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
     * Ensure that we can create a new bond vault and we emit the correct events
     */

    function _createBondVault(bytes32 vaultHash, bool vault)
        internal
        returns (address)
    {
        if (vault) {
            return
                _createBondVault(
                    appraiserTwo, // appraiserTwo for vault
                    address(0), // appraiserTwo for vault
                    //                    block.timestamp + 30 days, //expiration
                    block.timestamp + 1 days, //deadline
                    uint256(10), //buyout
                    appraiserTwoPK
                );
        } else {
            return
                _createBondVault(
                    appraiserOne, // appraiserOne for solo vault
                    address(0), // appraiserOne for solo vault
                    //                block.timestamp + 30 days, //expiration
                    block.timestamp + 1 days, //deadline
                    uint256(10), //buyout
                    appraiserOnePK
                );
        }
    }

    function _createBondVault(
        address appraiser,
        address delegate,
        //        uint256 expiration,
        uint256 deadline,
        uint256 buyout,
        //        bytes32 _rootHash,
        uint256 appraiserPk
    ) internal returns (address) {
        bytes32 hash = keccak256(
            BOND_CONTROLLER.encodeBondVaultHash(
                appraiser,
                delegate,
                //                expiration,
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
            delegate,
            deadline,
            buyout,
            v,
            r,
            s
        );
        if (appraiser == appraiserOne) {
            return BOND_CONTROLLER.newSoloVault(params);
        } else {
            return BOND_CONTROLLER.newBondVault(params);
        }
    }

    //    function _generateLoanProof(
    //        uint256 _collateralVault,
    //        LoanTerms memory terms
    //    ) internal returns (bytes32 rootHash, bytes32[] memory proof) {
    //        return
    //            _generateLoanProof(
    //                _collateralVault,
    //                terms.maxAmount,
    //                terms.maxDebt,
    //                terms.interestRate,
    //                terms.duration,
    //                terms.schedule
    //            );
    //    }

    //
    //    function _generateLoanProof(
    //        uint256 _collateralVault,
    //        uint256 maxAmount,
    //        uint256 maxDebt,
    //        uint256 interest,
    //        uint256 maxInterest,
    //        uint256 duration,
    //        uint256 schedule
    //    ) internal returns (bytes32 rootHash, bytes32[] memory proof) {
    //        (address tokenContract, uint256 tokenId) = COLLATERAL_VAULT
    //            .getUnderlying(_collateralVault);
    //        string[] memory inputs = new string[](10);
    //        //address, tokenId, maxAmount, interest, duration, lienPosition, schedule
    //
    //        inputs[0] = "node";
    //        inputs[1] = "scripts/loanProofGenerator.js";
    //        inputs[2] = abi.encodePacked(tokenContract).toHexString(); //tokenContract
    //        inputs[3] = abi.encodePacked(tokenId).toHexString(); //tokenId
    //        inputs[4] = abi.encodePacked(maxAmount).toHexString(); //valuation
    //        inputs[5] = abi.encodePacked(maxDebt).toHexString(); //valuation
    //        inputs[6] = abi.encodePacked(interest).toHexString(); //interest
    //        inputs[7] = abi.encodePacked(maxInterest).toHexString(); //interest
    //        inputs[8] = abi.encodePacked(duration).toHexString(); //stop
    //        inputs[9] = abi.encodePacked(schedule).toHexString(); //schedule
    //
    //        bytes memory res = vm.ffi(inputs);
    //        (rootHash, proof) = abi.decode(res, (bytes32, bytes32[]));
    //    }

    struct LoanProofGeneratorParams {
        address tokenContract;
        uint256 tokenId;
        uint8 generationType;
        bytes data;
    }

    function _generateInputs(LoanProofGeneratorParams memory params)
        internal
        returns (string[] memory inputs)
    {
        if (params.generationType == uint8(StrategyTypes.STANDARD)) {
            inputs = new string[](11);

            uint256 collateralVault = uint256(
                keccak256(
                    abi.encodePacked(params.tokenContract, params.tokenId)
                )
            );

            //string[] memory inputs = new string[](10);
            //address, tokenId, maxAmount, interest, duration, lienPosition, schedule

            IBrokerRouter.CollateralDetails memory terms = abi.decode(
                params.data,
                (IBrokerRouter.CollateralDetails)
            );
            inputs[0] = "node";
            inputs[1] = "scripts/loanProofGenerator.js";
            inputs[2] = abi.encodePacked(params.tokenContract).toHexString(); //tokenContract
            inputs[3] = abi.encodePacked(params.tokenId).toHexString(); //tokenId

            inputs[4] = abi.encodePacked(appraiserOne).toHexString(); //appraiserOne
            inputs[5] = abi.encodePacked(appraiserTwo).toHexString(); //appraiserTwo
            inputs[6] = abi.encodePacked(true).toHexString(); //public
            inputs[7] = abi.encodePacked(address(0)).toHexString(); //vault
            //vault details
            inputs[8] = abi
                .encodePacked(uint8(StrategyTypes.STANDARD))
                .toHexString(); //type
            inputs[9] = abi.encodePacked(address(0)).toHexString(); //borrower
            inputs[10] = abi.encode(terms.lien).toHexString(); //lien details

            //            inputs[9] = abi.encodePacked(terms.lien.maxAmount).toHexString(); //valuation
            //            inputs[10] = abi
            //                .encodePacked(terms.lien.maxSeniorDebt)
            //                .toHexString(); //valuation
            //            inputs[11] = abi.encodePacked(uint32(0)).toHexString(); //interest will use variable rate if not fixed
            //            inputs[12] = abi.encodePacked(terms.lien.duration).toHexString(); //stop
            //            inputs[13] = abi.encodePacked(terms.lien.schedule).toHexString(); //schedule
        }
        //        } else if (generationType == StrategyTypes.COLLECTION) {
        //            inputs = new string[](10);
        //            (address tokenContract, uint256 tokenId) = COLLATERAL_VAULT
        //                .getUnderlying(_collateralVault);
        //            string[] memory inputs = new string[](11);
        //            //address, tokenId, maxAmount, interest, duration, lienPosition, schedule
        //
        //            IBrokerRouter.Terms memory terms = abi.decode(
        //                data,
        //                (IBrokerRouter.Terms)
        //            );
        //            inputs[0] = "node";
        //            inputs[1] = "scripts/loanProofGenerator.js";
        //            inputs[2] = abi.encodePacked(tokenContract).toHexString(); //tokenContract
        //            inputs[3] = abi.encodePacked(tokenId).toHexString(); //tokenId
        //            inputs[4] = abi.encodePacked(terms.maxAmount).toHexString(); //valuation
        //            inputs[5] = abi.encodePacked(terms.maxDebt).toHexString(); //valuation
        //            inputs[6] = abi.encodePacked(terms.interest).toHexString(); //interest
        //            inputs[7] = abi.encodePacked(terms.maxInterest).toHexString(); //interest
        //            inputs[8] = abi.encodePacked(terms.duration).toHexString(); //stop
        //            inputs[9] = abi.encodePacked(terms.schedule).toHexString(); //schedule
        //            inputs[10] = abi.encodePacked(terms.schedule).toHexString(); //schedule
        //        } else if (generationType == StrategyTypes.COLLECTION) {} else {}
        return inputs;
    }

    function _generateLoanProof(LoanProofGeneratorParams memory params)
        internal
        returns (bytes32 rootHash, bytes32[] memory proof)
    {
        string[] memory inputs = _generateInputs(params);

        bytes memory res = vm.ffi(inputs);
        (rootHash, proof) = abi.decode(res, (bytes32, bytes32[]));
    }

    event LoanObligationProof(bytes32[]);

    function _generateDefaultCollateralVault()
        internal
        returns (uint256 collateralVault)
    {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);

        (, , IBrokerRouter.Commitment memory terms) = _commitToLoan(
            tokenContract,
            tokenId,
            defaultTerms
        );

        collateralVault = uint256(
            keccak256(abi.encodePacked(tokenContract, tokenId))
        );

        return (tokenContract.computeId(tokenId));
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
        uint256 amount
    )
        internal
        returns (bytes32 vaultHash, IBrokerRouter.Commitment memory terms)
    {
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
            CommitWithoutDeposit(
                tokenContract,
                tokenId,
                maxAmount,
                maxDebt,
                interestRate,
                maxInterestRate,
                duration,
                amount
            )
        );

        // vm.expectEmit(true, true, false, false);
        // emit NewTermCommitment(vaultHash, collateralVault, amount);
        BrokerImplementation(broker).commitToLoan(terms, address(this));
        // BrokerVault(broker).withdraw(0 ether);

        return (vaultHash, terms);
    }

    function _commitToLoan(
        address tokenContract,
        uint256 tokenId,
        LoanTerms memory loanTerms
    )
        internal
        returns (
            bytes32 vaultHash,
            address vault,
            IBrokerRouter.Commitment memory terms
        )
    {
        _depositNFTs(tokenContract, tokenId);
        emit LogTerms(loanTerms);
        (vaultHash, terms, vault) = _commitWithoutDeposit(
            CommitWithoutDeposit(
                tokenContract,
                tokenId,
                loanTerms.maxAmount,
                loanTerms.maxDebt,
                loanTerms.interestRate,
                loanTerms.maxInterestRate,
                loanTerms.duration,
                loanTerms.amount
            )
        );
        emit LogCommitment(terms);

        BrokerImplementation(vault).commitToLoan(terms, address(this));

        return (vaultHash, vault, terms);
    }

    event LogTerms(LoanTerms);

    function _commitWithoutDeposit(
        address tokenContract,
        uint256 tokenId,
        LoanTerms memory loanTerms
    )
        internal
        returns (
            bytes32 vaultHash,
            IBrokerRouter.Commitment memory terms,
            address broker
        )
    {
        return
            _commitWithoutDeposit(
                CommitWithoutDeposit(
                    tokenContract,
                    tokenId,
                    loanTerms.maxAmount,
                    loanTerms.maxDebt,
                    loanTerms.interestRate,
                    loanTerms.maxInterestRate,
                    loanTerms.duration,
                    loanTerms.amount
                )
            );
    }

    function _generateLoanGeneratorParams(
        address tokenContract,
        uint256 tokenId,
        uint256 maxAmount,
        uint256 maxDebt,
        uint256 interestRate,
        uint256 maxInterestRate,
        uint256 duration,
        uint256 amount
    ) internal returns (LoanProofGeneratorParams memory) {
        return
            LoanProofGeneratorParams(
                tokenContract,
                tokenId,
                uint8(0),
                abi.encode(
                    IBrokerRouter.CollateralDetails(
                        uint8(1),
                        tokenContract,
                        tokenId,
                        address(0),
                        IBrokerRouter.LienDetails(
                            maxAmount,
                            maxDebt,
                            interestRate,
                            maxInterestRate,
                            duration
                        )
                    )
                )
            );
    }

    // TODO clean up flow, for now makes refinancing more convenient

    struct CommitWithoutDeposit {
        address tokenContract;
        uint256 tokenId;
        uint256 maxAmount;
        uint256 maxDebt;
        uint256 interestRate;
        uint256 maxInterestRate;
        uint256 duration;
        uint256 amount;
    }

    event LogCommitWithoutDeposit(CommitWithoutDeposit);

    function _commitWithoutDeposit(CommitWithoutDeposit memory params)
        internal
        returns (
            bytes32 obligationRoot,
            IBrokerRouter.Commitment memory terms,
            address vault
        )
    {
        uint256 collateralVault = params.tokenContract.computeId(
            params.tokenId
        );

        bytes32[] memory obligationProof;
        LoanProofGeneratorParams
            memory proofParams = _generateLoanGeneratorParams(
                params.tokenContract,
                params.tokenId,
                params.maxAmount,
                params.maxDebt,
                params.interestRate,
                params.maxInterestRate,
                params.duration,
                params.amount
            );
        (obligationRoot, obligationProof) = _generateLoanProof(proofParams);

        vault = _createBondVault(obligationRoot, true);

        _lendToVault(vault, uint256(500 ether), appraiserTwo);

        uint8 v;
        bytes32 r;
        bytes32 s;
        (v, r, s) = vm.sign(uint256(appraiserOnePK), obligationRoot);
        IBrokerRouter.Commitment memory terms = _generateCommitment(
            params,
            vault,
            obligationRoot,
            obligationProof,
            v,
            r,
            s
        );
        return (obligationRoot, terms, vault);
    }

    event LogCommitment(IBrokerRouter.Commitment);

    function _generateCommitment(
        CommitWithoutDeposit memory params,
        address vault,
        bytes32 obligationRoot,
        bytes32[] memory obligationProof,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal returns (IBrokerRouter.Commitment memory) {
        emit LogCommitWithoutDeposit(params);
        return
            IBrokerRouter.Commitment(
                params.tokenContract,
                params.tokenId,
                new bytes32[](0),
                IBrokerRouter.NewObligationRequest(
                    IBrokerRouter.StrategyDetails(
                        uint8(0),
                        appraiserOne,
                        address(0),
                        BOND_CONTROLLER.appraiserNonce(appraiserOne), //nonce
                        vault
                    ),
                    uint8(StrategyTypes.STANDARD), //obligationType
                    abi.encode(
                        IBrokerRouter.CollateralDetails(
                            uint8(1), //version
                            params.tokenContract, // tokenContract
                            params.tokenId, //tokenId
                            address(0), // borrwer
                            IBrokerRouter.LienDetails({
                                maxAmount: params.maxAmount,
                                maxSeniorDebt: params.maxDebt,
                                rate: params.interestRate,
                                maxInterestRate: params.maxInterestRate,
                                duration: params.duration //lienDetails
                            })
                        )
                    ), //obligationDetails
                    obligationRoot, //obligationRoot
                    obligationProof, //obligationProof
                    params.amount, //amount
                    v, //v
                    r, //r
                    s //s
                )
            );
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
        address vault,
        uint256 amount,
        address lendAs
    ) internal {
        vm.deal(lendAs, amount);
        vm.startPrank(lendAs);
        WETH9.deposit{value: amount}();
        WETH9.approve(vault, type(uint256).max);
        //        BOND_CONTROLLER.lendToVault(vaultHash, amount);
        IBroker(vault).deposit(amount, lendAs);
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
