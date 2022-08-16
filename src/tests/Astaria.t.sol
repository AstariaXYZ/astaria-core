pragma solidity ^0.8.15;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {CollateralVault, IFlashAction} from "../CollateralVault.sol";
import {LienToken} from "../LienToken.sol";
import {ILienToken} from "../interfaces/ILienToken.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {IBrokerRouter, BrokerRouter} from "../BrokerRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {Strings2} from "./utils/Strings2.sol";
import {IBroker, BrokerImplementation} from "../BrokerImplementation.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import "./TestHelpers.t.sol";

contract BorrowAndRedeposit is IFlashAction, TestHelpers {
    function onFlashAction(bytes calldata data) external returns (bytes32) {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);

        _commitToLoan(tokenContract, tokenId, defaultTerms);
        return bytes32(keccak256("FlashAction.onFlashAction"));
    }
}

//TODO:
// - setup helpers to repay loans
// - setup helpers to pay loans at their schedule
// - test for interest
// - test auction flow
// - create/cancel/end
contract AstariaTest is TestHelpers {
    using FixedPointMathLib for uint256;
    using CollateralLookup for address;

    event DepositERC721(
        address indexed from,
        address indexed tokenContract,
        uint256 tokenId
    );

    event ReleaseTo(
        address indexed underlyingAsset,
        uint256 assetId,
        address indexed to
    );

    event Liquidation(
        uint256 collateralVault,
        uint256 position,
        uint256 reserve
    );

    event AuctionCanceled(uint256 indexed auctionId);

    event AuctionBid(
        uint256 indexed tokenId,
        address sender,
        uint256 value,
        bool firstBid,
        bool extended
    );

    event AuctionEnded(
        uint256 indexed tokenId,
        address winner,
        uint256 winningBid,
        uint256[] recipients
    );

    event NewBondVault(
        address appraiser,
        address broker,
        bytes32 bondVault,
        bytes32 contentHash,
        uint256 expiration
    );

    /**
     * Ensure that we can borrow capital from the bond controller
     * ensure that we're emitting the correct events
     * ensure that we're repaying the proper collateral
     */
    function testCommitToLoan() public {
        //        address tokenContract = address(
        //            0x938e5ed128458139A9c3306aCE87C60BCBA9c067
        //        );
        //        uint256 tokenId = uint256(10);
        //
        //        _hijackNFT(tokenContract, tokenId);

        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);

        uint256 balanceBefore = WETH9.balanceOf(address(this));
        //balance of WETH before loan

        vm.expectEmit(true, true, false, true);
        emit DepositERC721(address(this), tokenContract, tokenId);

        (bytes32 vaultHash, , ) = _commitToLoan(
            tokenContract,
            tokenId,
            defaultTerms
        );

        // BrokerVault(BOND_CONTROLLER.getBroker(testBondVaultHash)).withdraw(50 ether);

        //assert weth balance is before + 1 ether
        assert(
            WETH9.balanceOf(address(this)) ==
                balanceBefore + defaultTerms.amount
        );
    }

    function testSoloLend() public {
        vm.startPrank(appraiserOne);
        address vault = _createBondVault(testBondVaultHash, false);

        vm.deal(appraiserOne, 1000 ether);
        WETH9.deposit{value: 50 ether}();
        WETH9.approve(vault, type(uint256).max);

        vm.warp(block.timestamp + 10000 days); // forward past expiration date

        //        BOND_CONTROLLER.lendToVault(testBondVaultHash, 50 ether);
        IBroker(vault).deposit(50 ether, address(this));

        vm.stopPrank();
    }

    function testWithdraw() public {}

    function testReleaseToAddress() public {
        Dummy721 releaseTest = new Dummy721();
        address tokenContract = address(releaseTest);
        uint256 tokenId = uint256(1);
        _depositNFTs(tokenContract, tokenId);
        // startMeasuringGas("ReleaseTo Address");

        uint256 starTokenId = uint256(
            keccak256(abi.encodePacked(tokenContract, tokenId))
        );

        (address underlyingAsset, uint256 assetId) = COLLATERAL_VAULT
            .getUnderlying(starTokenId);

        vm.expectEmit(true, true, false, true);

        emit ReleaseTo(underlyingAsset, assetId, address(this));

        COLLATERAL_VAULT.releaseToAddress(starTokenId, address(this));
        // stopMeasuringGas();
    }

    /**
     * Ensure that asset's that have liens cannot be released to Anyone.
     */
    function testLiens() public {
        //trigger loan commit
        //try to release asset

        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);

        vm.expectEmit(true, true, false, true);
        emit DepositERC721(address(this), tokenContract, tokenId);
        (
            bytes32 vaultHash,
            address vault,
            IBrokerRouter.Commitment memory terms
        ) = _commitToLoan(tokenContract, tokenId, defaultTerms);
        vm.expectRevert(bytes("must be no liens or auctions to call this"));

        COLLATERAL_VAULT.releaseToAddress(
            uint256(keccak256(abi.encodePacked(tokenContract, tokenId))),
            address(this)
        );
    }

    /**
     * Ensure that we can auction underlying vaults
     * ensure that we're emitting the correct events
     * ensure that we're repaying the proper collateral
     */

    struct TestAuctionVaultResponse {
        bytes32 hash;
        uint256 collateralVault;
        uint256 reserve;
    }

    //    function testAuctionVault()
    //        public
    //        returns (TestAuctionVaultResponse memory)
    //    {
    //        Dummy721 loanTest = new Dummy721();
    //        address tokenContract = address(loanTest);
    //        uint256 tokenId = uint256(1);
    //        vm.expectEmit(true, true, false, true);
    //        emit DepositERC721(address(this), tokenContract, tokenId);
    //        (
    //            bytes32 vaultHash,
    //            IBrokerRouter.Commitment memory terms
    //        ) = _commitToLoan(tokenContract, tokenId, defaultTerms);
    //        uint256 starId = uint256(
    //            keccak256(abi.encodePacked(tokenContract, tokenId))
    //        );
    //        _warpToMaturity(starId, uint256(0));
    //        address broker = BOND_CONTROLLER.getBroker(vaultHash);
    //
    //        vm.expectEmit(false, false, false, false);
    //
    //        emit Liquidation(terms.collateralVault, uint256(0), uint256(0)); // not calculating/checking reserve
    //
    //        uint256 reserve = BOND_CONTROLLER.liquidate(
    //            terms.collateralVault,
    //            uint256(0)
    //        );
    //
    //        //        return (vaultHash, starId, reserve);
    //        return TestAuctionVaultResponse(vaultHash, starId, reserve);
    //    }

    /**
     * Ensure that owner of the token can cancel the auction by repaying the reserve(sum of debt + fee)
     * ensure that we're emitting the correct events
     */
    // expect emit cancelAuction
    //    function testCancelAuction() public {
    //        TestAuctionVaultResponse memory response = testAuctionVault();
    //        vm.deal(address(this), response.reserve);
    //        WETH9.deposit{value: response.reserve}();
    //        WETH9.approve(address(TRANSFER_PROXY), response.reserve);
    //
    //        vm.expectEmit(true, false, false, false);
    //
    //        emit AuctionCanceled(response.collateralVault);
    //
    //        COLLATERAL_VAULT.cancelAuction(response.collateralVault);
    //    }
    //
    //    function testEndAuctionWithBids() public {
    //        TestAuctionVaultResponse memory response = testAuctionVault();
    //
    //        vm.expectEmit(true, false, false, false);
    //
    //        // uint256 indexed tokenId, address sender, uint256 value, bool firstBid, bool extended
    //        emit AuctionBid(
    //            response.collateralVault,
    //            address(this),
    //            response.reserve,
    //            true,
    //            true
    //        ); // TODO check (non-indexed data check failing)
    //
    //        _createBid(bidderOne, response.collateralVault, response.reserve);
    //        _createBid(
    //            bidderTwo,
    //            response.collateralVault,
    //            response.reserve += ((response.reserve * 5) / 100)
    //        );
    //        _createBid(
    //            bidderOne,
    //            response.collateralVault,
    //            response.reserve += ((response.reserve * 30) / 100)
    //        );
    //        _warpToAuctionEnd(response.collateralVault);
    //
    //        vm.expectEmit(false, false, false, false);
    //
    //        uint256[] memory dummyRecipients;
    //        emit AuctionEnded(uint256(0), address(0), uint256(0), dummyRecipients);
    //
    //        COLLATERAL_VAULT.endAuction(response.collateralVault);
    //    }

    function testBrokerRouterFileSetup() public {
        bytes memory newLiquidationFeePercent = abi.encode(uint256(0));
        BOND_CONTROLLER.file(
            bytes32("LIQUIDATION_FEE_PERCENT"),
            newLiquidationFeePercent
        );
        assert(BOND_CONTROLLER.LIQUIDATION_FEE_PERCENT() == uint256(0));

        bytes memory newMinInterestBps = abi.encode(uint256(0));
        BOND_CONTROLLER.file(bytes32("MIN_INTEREST_BPS"), newMinInterestBps);
        assert(BOND_CONTROLLER.MIN_INTEREST_BPS() == uint256(0));

        bytes memory appraiserNumerator = abi.encode(uint256(0));
        BOND_CONTROLLER.file(
            bytes32("APPRAISER_NUMERATOR"),
            appraiserNumerator
        );
        assert(
            BOND_CONTROLLER.APPRAISER_ORIGINATION_FEE_NUMERATOR() == uint256(0)
        );

        bytes memory appraiserOriginationFeeBase = abi.encode(uint256(0));
        BOND_CONTROLLER.file(
            bytes32("APPRAISER_ORIGINATION_FEE_BASE"),
            appraiserOriginationFeeBase
        );
        assert(BOND_CONTROLLER.APPRAISER_ORIGINATION_FEE_BASE() == uint256(0));

        bytes memory minDurationIncrease = abi.encode(uint256(0));
        BOND_CONTROLLER.file(
            bytes32("MIN_DURATION_INCREASE"),
            minDurationIncrease
        );
        assert(BOND_CONTROLLER.MIN_DURATION_INCREASE() == uint256(0));

        bytes memory feeTo = abi.encode(address(0));
        BOND_CONTROLLER.file(bytes32("feeTo"), feeTo);
        assert(BOND_CONTROLLER.feeTo() == address(0));

        bytes memory vaultImplementation = abi.encode(address(0));
        BOND_CONTROLLER.file(
            bytes32("VAULT_IMPLEMENTATION"),
            vaultImplementation
        );
        assert(BOND_CONTROLLER.VAULT_IMPLEMENTATION() == address(0));

        vm.expectRevert("unsupported/file");
        BOND_CONTROLLER.file(bytes32("Joseph Delong"), "");
    }

    function testCollateralVaultFileSetup() public {
        // bytes memory supportedAssetsRoot = abi.encode(bytes32(0));
        // COLLATERAL_VAULT.file(bytes32("SUPPORTED_ASSETS_ROOT"), supportedAssetsRoot);
        // assert(COLLATERAL_VAULT.SUPPORTED_ASSETS_ROOT(), bytes32(0));

        bytes memory conduit = abi.encode(address(0));
        COLLATERAL_VAULT.file(bytes32("CONDUIT"), conduit);
        assert(COLLATERAL_VAULT.CONDUIT() == address(0));

        bytes memory conduitKey = abi.encode(bytes32(0));
        COLLATERAL_VAULT.file(bytes32("CONDUIT_KEY"), conduitKey);
        assert(COLLATERAL_VAULT.CONDUIT_KEY() == bytes32(0));

        // setupSeaport fails at SEAPORT.information() in non-forked tests
        // bytes memory seaportAddr = abi.encode(address(0x00000000006c3852cbEf3e08E8dF289169EdE581));
        // COLLATERAL_VAULT.file(bytes32("setupSeaport"), seaportAddr);

        bytes memory brokerRouterAddr = abi.encode(address(0));
        COLLATERAL_VAULT.file(bytes32("setBondController"), brokerRouterAddr);
        assert(COLLATERAL_VAULT.BROKER_ROUTER() == IBrokerRouter(address(0)));

        bytes memory supportedAssetsRoot = abi.encode(bytes32(0));
        COLLATERAL_VAULT.file(bytes32("setSupportedRoot"), supportedAssetsRoot); // SUPPORTED_ASSETS_ROOT not public, not tested

        bytes memory auctionHouseAddr = abi.encode(address(0));
        COLLATERAL_VAULT.file(bytes32("setAuctionHouse"), auctionHouseAddr);
        assert(COLLATERAL_VAULT.AUCTION_HOUSE() == IAuctionHouse(address(0)));

        bytes memory securityHook = abi.encode(address(0), address(0));
        COLLATERAL_VAULT.file(bytes32("setSecurityHook"), securityHook);
        assert(COLLATERAL_VAULT.securityHooks(address(0)) == address(0));

        vm.expectRevert("unsupported/file");
        COLLATERAL_VAULT.file(bytes32("Andrew Redden"), "");
    }

    function testLienTokenFileSetup() public {
        bytes memory auctionHouseAddr = abi.encode(address(0));
        LIEN_TOKEN.file(bytes32("setAuctionHouse"), auctionHouseAddr);
        assert(LIEN_TOKEN.AUCTION_HOUSE() == IAuctionHouse(address(0)));

        bytes memory collateralVaultAddr = abi.encode(address(0));
        LIEN_TOKEN.file(bytes32("setCollateralVault"), collateralVaultAddr);
        assert(LIEN_TOKEN.COLLATERAL_VAULT() == ICollateralVault(address(0)));

        vm.expectRevert("unsupported/file");
        COLLATERAL_VAULT.file(bytes32("Justin Bram"), "");
    }

    //    function testRefinanceLoan() public {
    //        Dummy721 loanTest = new Dummy721();
    //        address tokenContract = address(loanTest);
    //        uint256 tokenId = uint256(1);
    //        vm.expectEmit(true, true, false, true);
    //        emit DepositERC721(address(this), tokenContract, tokenId);
    //        (
    //            bytes32 vaultHash,
    //            address vault,
    //            IBrokerRouter.Commitment memory outgoing
    //        ) = _commitToLoan(tokenContract, tokenId, defaultTerms);
    //        uint256 collateralVault = tokenContract.computeId(tokenId);
    //        _warpToMaturity(collateralVault, uint256(0));
    //
    //        // TODO check
    //        uint256 reserve = BOND_CONTROLLER.liquidate(
    //            collateralVault,
    //            uint256(0)
    //        );
    //
    //        LoanTerms memory newTerms = LoanTerms({
    //            maxAmount: uint256(100000000000000000000),
    //            maxDebt: uint256(10000000000000000000),
    //            interestRate: uint256(10000000000000), // interest rate decreased
    //            duration: uint256(block.timestamp + 1000000000 minutes), // duration doubled
    //            amount: uint256(1 ether),
    //            schedule: uint256(50 ether)
    //        });
    //
    //        // TODO fix
    //        //        IBrokerRouter.Commitment memory outgoing = IBrokerRouter.Commitment({
    //        //            vault: vault, // broker
    //        //            token: address(WETH9),
    //        //            proof: terms.proof, // proof
    //        //            collateralVault: terms.collateralVault, // collateralVault
    //        //            maxAmount: defaultTerms.maxAmount,
    //        //            maxDebt: defaultTerms.maxDebt,
    //        //            rate: defaultTerms.interestRate, // rate
    //        //            duration: defaultTerms.duration,
    //        //            schedule: defaultTerms.schedule
    //        //        });
    //
    //        //        IBrokerRouter.Commitment memory incoming = IBrokerRouter.Terms({
    //        //            broker: broker, // broker
    //        //            token: address(WETH9),
    //        //            proof: terms.proof, // proof
    //        //            collateralVault: terms.collateralVault, // collateralVault
    //        //            maxAmount: newTerms.maxAmount,
    //        //            maxDebt: newTerms.maxDebt,
    //        //            rate: uint256(0), // used to be newTerms.rate
    //        //            duration: newTerms.duration,
    //        //            schedule: newTerms.schedule
    //        //        });
    //
    //        // address tokenContract;
    //        //        uint256 tokenId;
    //        //        bytes32[] depositProof;
    //        //        NewObligationRequest nor;
    //        IBrokerRouter.Commitment memory incoming = IBrokerRouter.Commitment(
    //            tokenContract,tokenId,
    //        );
    //
    //        IBrokerRouter.RefinanceCheckParams
    //            memory refinanceCheckParams = IBrokerRouter.RefinanceCheckParams(
    //                uint256(0),
    //                incoming
    //            );
    //
    //        assert(BOND_CONTROLLER.isValidRefinance(refinanceCheckParams));
    //        _commitWithoutDeposit(tokenContract, tokenId, newTerms); // refinances loan
    //    }

    // function testRefinanceLoan() public {
    //     //------------------------------

    //     Dummy721 loanTest = new Dummy721();
    //     address tokenContract = address(loanTest);
    //     uint256 tokenId = uint256(1);

    //     LoanTerms memory newTerms = LoanTerms({
    //         maxAmount: uint256(100000000000000000000),
    //         interestRate: uint256(10000000000000000000), // interest rate decreased
    //         duration: uint256(block.timestamp + 10 minutes * 2), // duration doubled
    //         amount: uint256(1 ether),
    //         lienPosition: uint256(0),
    //         schedule: uint256(50 ether)
    //     });

    //     uint256 collateralVault = uint256(
    //         keccak256(abi.encodePacked(tokenContract, tokenId))
    //     );
    //     bytes32 vaultHash;
    //     bytes32[] memory proof;

    //     (vaultHash, proof) = _generateLoanProof(collateralVault, defaultTerms);

    //     address broker = BOND_CONTROLLER.getBroker(vaultHash);

    //     // TODO fix
    //     IBrokerRouter.Terms memory outgoing = IBrokerRouter.Terms({
    //         broker: broker, // broker
    //         proof: proof, // proof
    //         collateralVault: collateralVault, // collateralVault
    //         maxAmount: defaultTerms.maxAmount,
    //         rate: defaultTerms.interestRate, // rate
    //         duration: defaultTerms.duration,
    //         position: defaultTerms.lienPosition, // position
    //         schedule: defaultTerms.schedule
    //     });

    //     (vaultHash, proof) = _generateLoanProof(collateralVault, newTerms);

    //     IBrokerRouter.Terms memory incoming = IBrokerRouter.Terms({
    //         broker: broker, // broker
    //         proof: proof, // proof
    //         collateralVault: collateralVault, // collateralVault
    //         maxAmount: newTerms.maxAmount,
    //         rate: newTerms.interestRate, // rate
    //         duration: newTerms.duration,
    //         position: newTerms.lienPosition, // position
    //         schedule: newTerms.schedule
    //     });

    //     IBrokerRouter.RefinanceCheckParams
    //         memory refinanceCheckParams = IBrokerRouter.RefinanceCheckParams(
    //             outgoing,
    //             incoming
    //         );

    // BOND_CONTROLLER.isValidRefinance(refinanceCheckParams);

    // _refinanceLoan(tokenContract, tokenId, defaultTerms, newTerms);

    // (bytes32 outgoing, IBrokerRouter.Terms memory terms) = _commitToLoan(
    //     tokenContract,
    //     tokenId,
    //     defaultTerms
    // );

    // uint256[] memory loanDetails2 = new uint256[](6);
    // loanDetails2[0] = uint256(100000000000000000000); //maxAmount
    // loanDetails2[1] = uint256(10000000000000000000); //interestRate
    // loanDetails2[2] = uint256(block.timestamp + 10 minutes * 2); //duration
    // loanDetails2[3] = uint256(1 ether); //amount
    // loanDetails2[4] = uint256(0); //lienPosition
    // loanDetails2[5] = uint256(50); //schedule

    // _commitWithoutDeposit(
    //     tokenContract,
    //     tokenId,
    //     loanDetails2[0],
    //     loanDetails2[1], //interestRate
    //     loanDetails2[2], //duration
    //     loanDetails2[3], // amount
    //     loanDetails2[4], //lienPosition
    //     loanDetails2[5] //schedule
    // );
    // }

    // lienToken testing

    //    function testBuyoutLien() public {
    //        Dummy721 buyoutTest = new Dummy721();
    //        address tokenContract = address(buyoutTest);
    //        uint256 tokenId = uint256(1);
    //
    //        LoanTerms memory loanTerms = LoanTerms({
    //            maxAmount: 10 ether,
    //            maxDebt: 20 ether, //used to be uint256(10000000000000000000)
    //            interestRate: uint256(0),
    //            duration: 730 days,
    //            amount: uint256(10 ether),
    //            schedule: uint256(50 ether)
    //        });
    //
    //        (
    //            bytes32 vaultHash,
    //            ,
    //            IBrokerRouter.Commitment memory terms
    //        ) = _commitToLoan(tokenContract, tokenId, loanTerms);
    //
    //        uint256 collateralVault = tokenContract.computeId(tokenId);
    //
    //        _warpToMaturity(collateralVault, uint256(0));
    //
    //        address broker = BOND_CONTROLLER.getBroker(vaultHash);
    //
    //        WETH9.deposit{value: 20 ether}();
    //        WETH9.transfer(broker, 20 ether);
    //        BrokerImplementation(broker).buyoutLien(
    //            collateralVault,
    //            uint256(0),
    //            terms.nor
    //        );
    //    }

    event INTEREST(uint256 interest);

    // TODO update once better math implemented
    function testLienGetInterest() public {
        uint256 collateralVault = _generateDefaultCollateralVault();

        // interest rate of uint256(50000000000000000000)
        // duration of 10 minutes
        uint256 interest = LIEN_TOKEN.getInterest(collateralVault, uint256(0));
        assertEq(interest, uint256(0));

        _warpToMaturity(collateralVault, uint256(0));

        interest = LIEN_TOKEN.getInterest(collateralVault, uint256(0));
        emit INTEREST(interest);
        assertEq(interest, uint256(516474411155456000000000000000000)); // just pasting current output, will change later
    }

    // for now basically redundant since just adding to lien getInterest, should set up test flow for multiple liens later
    function testLienGetTotalDebtForCollateralVault() public {
        uint256 collateralVault = _generateDefaultCollateralVault();

        uint256 totalDebt = LIEN_TOKEN.getTotalDebtForCollateralVault(
            collateralVault
        );

        assertEq(totalDebt, uint256(1000000000000000000));
    }

    function testLienGetBuyout() public {
        uint256 collateralVault = _generateDefaultCollateralVault();

        (uint256 owed, uint256 owedPlus) = LIEN_TOKEN.getBuyout(
            collateralVault,
            uint256(0)
        );

        assertEq(owed, uint256(1000000000000000000));
        assertEq(owedPlus, uint256(179006655693800000000000000000));
    }

    // TODO add after _generateDefaultCollateralVault()
    function testLienMakePayment() public {
        uint256 collateralVault = _generateDefaultCollateralVault();

        // TODO fix
        LIEN_TOKEN.makePayment(collateralVault, uint256(0), uint256(0));
    }

    function testLienGetImpliedRate() public {
        uint256 collateralVault = _generateDefaultCollateralVault();

        uint256 impliedRate = LIEN_TOKEN.getImpliedRate(collateralVault);
        assertEq(impliedRate, uint256(2978480128));
    }

    // flashAction testing

    // should fail with "flashAction: NFT not returned"
    function testFailDoubleFlashAction() public {
        Dummy721 loanTest = new Dummy721();

        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);

        (bytes32 vaultHash, , ) = _commitToLoan(
            tokenContract,
            tokenId,
            defaultTerms
        );

        uint256 starId = uint256(
            keccak256(abi.encodePacked(tokenContract, tokenId))
        );
        IFlashAction borrowAndRedeposit = new BorrowAndRedeposit();
        COLLATERAL_VAULT.flashAction(borrowAndRedeposit, starId, "");
    }

    // failure testing
    function testFailLendWithoutTransfer() public {
        address vault = _createBondVault(testBondVaultHash, true);

        WETH9.transfer(address(BOND_CONTROLLER), uint256(1));
        IBroker(vault).deposit(uint256(1), address(this));
    }

    function testFailLendWithNonexistentVault() public {
        address vault = _createBondVault(testBondVaultHash, true);

        BrokerRouter emptyController;
        //        emptyController.lendToVault(testBondVaultHash, uint256(1));
        IBroker(vault).deposit(uint256(1), address(this));
    }

    function testFailLendPastExpiration() public {
        address vault = _createBondVault(testBondVaultHash, true);
        vm.deal(lender, 1000 ether);
        vm.startPrank(lender);
        WETH9.deposit{value: 50 ether}();
        WETH9.approve(vault, type(uint256).max);

        vm.warp(block.timestamp + 10000 days); // forward past expiration date

        //        BOND_CONTROLLER.lendToVault(testBondVaultHash, 50 ether);
        IBroker(vault).deposit(50 ether, address(this));
        vm.stopPrank();
    }

    function testFailCommitToLoanNotOwner() public {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);
        vm.prank(address(1));
        (bytes32 vaultHash, , ) = _commitToLoan(
            tokenContract,
            tokenId,
            defaultTerms
        );
    }

    function testFailSoloLendNotAppraiser() public {
        vm.startPrank(appraiserOne);
        address vault = _createBondVault(testBondVaultHash, false);
        vm.stopPrank();

        vm.deal(lender, 1000 ether);
        vm.startPrank(lender);
        WETH9.deposit{value: 50 ether}();
        WETH9.approve(vault, type(uint256).max);

        vm.warp(block.timestamp + 10000 days); // forward past expiration date

        // delete?
        BOND_CONTROLLER.lendToVault(vault, 50 ether);

        IBroker(vault).deposit(50 ether, address(this));
        vm.stopPrank();
    }
}
