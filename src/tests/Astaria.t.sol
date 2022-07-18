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
import {ILienToken} from "../interfaces/ILienToken.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {IBrokerRouter, BrokerRouter} from "../BrokerRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {Strings2} from "./utils/Strings2.sol";
import {IBroker, SoloBroker, BrokerImplementation} from "../BrokerImplementation.sol";
import {BrokerVault} from "../BrokerVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {BeaconProxy} from "openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import {TestHelpers, Dummy721, IWETH9} from "./TestHelpers.sol";

string constant weth9Artifact = "src/tests/WETH9.json";

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
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);

        uint256 balanceBefore = WETH9.balanceOf(address(this));
        //balance of WETH before loan

        vm.expectEmit(true, true, false, true);
        emit DepositERC721(address(this), tokenContract, tokenId);

        (bytes32 vaultHash, ) = _commitToLoan(
            tokenContract,
            tokenId,
            defaultTerms
        );

        //assert weth balance is before + 1 ether
        assert(
            WETH9.balanceOf(address(this)) ==
                balanceBefore + defaultTerms.amount
        );
    }

    function testSoloLend() public {
        vm.startPrank(appraiserOne);
        _createBondVault(testBondVaultHash, false);

        vm.deal(appraiserOne, 1000 ether);
        WETH9.deposit{value: 50 ether}();
        WETH9.approve(
            address(BOND_CONTROLLER.getBroker(testBondVaultHash)),
            type(uint256).max
        );

        vm.warp(block.timestamp + 10000 days); // forward past expiration date

        //        BOND_CONTROLLER.lendToVault(testBondVaultHash, 50 ether);
        IBroker(BOND_CONTROLLER.getBroker(testBondVaultHash)).deposit(
            50 ether,
            address(this)
        );
        vm.stopPrank();
    }

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
        Ensure that asset's that have liens cannot be released to Anyone.
     */
    function testLiens() public {
        //trigger loan commit
        //try to release asset

        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);

        vm.expectEmit(true, true, false, true);
        emit DepositERC721(address(this), tokenContract, tokenId);
        (bytes32 vaultHash, IBrokerRouter.Terms memory terms) = _commitToLoan(
            tokenContract,
            tokenId,
            defaultTerms
        );
        vm.expectRevert(bytes("must be no liens or auctions to call this"));

        COLLATERAL_VAULT.releaseToAddress(
            uint256(keccak256(abi.encodePacked(tokenContract, tokenId))),
            address(this)
        );
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
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);
        vm.expectEmit(true, true, false, true);
        emit DepositERC721(address(this), tokenContract, tokenId);
        (bytes32 vaultHash, IBrokerRouter.Terms memory terms) = _commitToLoan(
            tokenContract,
            tokenId,
            defaultTerms
        );
        uint256 starId = uint256(
            keccak256(abi.encodePacked(tokenContract, tokenId))
        );
        _warpToMaturity(starId, uint256(0));
        address broker = BOND_CONTROLLER.getBroker(vaultHash);

        vm.expectEmit(false, false, false, false);

        emit Liquidation(terms.collateralVault, uint256(0), uint256(0)); // not calculating/checking reserve

        uint256 reserve = BOND_CONTROLLER.liquidate(
            terms.collateralVault,
            uint256(0)
        );

        //        return (vaultHash, starId, reserve);
        return TestAuctionVaultResponse(vaultHash, starId, reserve);
    }

    /**
        Ensure that owner of the token can cancel the auction by repaying the reserve(sum of debt + fee)
        ensure that we're emitting the correct events

    */
    // expect emit cancelAuction
    function testCancelAuction() public {
        TestAuctionVaultResponse memory response = testAuctionVault();
        vm.deal(address(this), response.reserve);
        WETH9.deposit{value: response.reserve}();
        WETH9.approve(address(TRANSFER_PROXY), response.reserve);

        vm.expectEmit(true, false, false, false);

        emit AuctionCanceled(response.collateralVault);

        COLLATERAL_VAULT.cancelAuction(response.collateralVault);
    }

    function testEndAuctionWithBids() public {
        TestAuctionVaultResponse memory response = testAuctionVault();

        vm.expectEmit(true, false, false, false);

        // uint256 indexed tokenId, address sender, uint256 value, bool firstBid, bool extended
        emit AuctionBid(
            response.collateralVault,
            address(this),
            response.reserve,
            true,
            true
        ); // TODO check (non-indexed data check failing)

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

        vm.expectEmit(false, false, false, false);

        uint256[] memory dummyRecipients;
        emit AuctionEnded(uint256(0), address(0), uint256(0), dummyRecipients);

        COLLATERAL_VAULT.endAuction(response.collateralVault);
    }

    function testBrokerRouterFileSetup() public {
        bytes memory newLiquidationFeePercent = abi.encode(uint256(0));
        BOND_CONTROLLER.file(bytes32("LIQUIDATION_FEE_PERCENT"), newLiquidationFeePercent);
        assert(BOND_CONTROLLER.LIQUIDATION_FEE_PERCENT() == uint256(0));

        bytes memory newMinInterestBps = abi.encode(uint256(0));
        BOND_CONTROLLER.file(bytes32("MIN_INTEREST_BPS"), newMinInterestBps);
        assert(BOND_CONTROLLER.MIN_INTEREST_BPS() == uint256(0));

        bytes memory appraiserNumerator = abi.encode(uint256(0));
        BOND_CONTROLLER.file(bytes32("APPRAISER_NUMERATOR"), appraiserNumerator);
        assert(BOND_CONTROLLER.APPRAISER_ORIGINATION_FEE_NUMERATOR() == uint256(0));

        bytes memory appraiserOriginationFeeBase = abi.encode(uint256(0));
        BOND_CONTROLLER.file(bytes32("APPRAISER_ORIGINATION_FEE_BASE"), appraiserOriginationFeeBase);
        assert(BOND_CONTROLLER.APPRAISER_ORIGINATION_FEE_BASE() == uint256(0));

        bytes memory minDurationIncrease = abi.encode(uint256(0));
        BOND_CONTROLLER.file(bytes32("MIN_DURATION_INCREASE"), minDurationIncrease);
        assert(BOND_CONTROLLER.MIN_DURATION_INCREASE() == uint256(0));

        bytes memory feeTo = abi.encode(address(0));
        BOND_CONTROLLER.file(bytes32("feeTo"), feeTo);
        assert(BOND_CONTROLLER.feeTo() == address(0));

        bytes memory soloImplementation = abi.encode(address(0));
        BOND_CONTROLLER.file(bytes32("SOLO_IMPLEMENTATION"), soloImplementation);
        assert(BOND_CONTROLLER.SOLO_IMPLEMENTATION() == address(0));

        bytes memory vaultImplementation = abi.encode(address(0));
        BOND_CONTROLLER.file(bytes32("VAULT_IMPLEMENTATION"), vaultImplementation);
        assert(BOND_CONTROLLER.VAULT_IMPLEMENTATION() == address(0));

        bytes memory setAppraiser = abi.encode(address(0));
        BOND_CONTROLLER.file(bytes32("setAppraiser"), setAppraiser);
        assert(BOND_CONTROLLER.appraisers(address(0)));

        bytes memory revokeAppraiser = abi.encode(address(0));
        BOND_CONTROLLER.file(bytes32("revokeAppraiser"), revokeAppraiser);
        assert(!BOND_CONTROLLER.appraisers(address(0)));

        address[] memory vaultAppraisers = new address[](1);
        vaultAppraisers[0] = address(0);
        BOND_CONTROLLER.file(bytes32("setAppraisers"), abi.encode(vaultAppraisers));
        assert(BOND_CONTROLLER.appraisers(address(0)));

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

    function testRefinanceLoan() public {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);

        LoanTerms memory newTerms = LoanTerms({
            maxAmount: uint256(100000000000000000000),
            maxDebt: uint256(10000000000000000000),
            interestRate: uint256(10000000000000000000), // interest rate decreased
            maxInterestRate: uint256(10000000000000000000), // interest rate decreased
            duration: uint256(block.timestamp + 10 minutes * 2), // duration doubled
            amount: uint256(1 ether),
            schedule: uint256(50 ether)
        });

        _refinanceLoan(tokenContract, tokenId, defaultTerms, newTerms);

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
    }

    // flashAction testing

    // should fail with "flashAction: NFT not returned"
    function testFailDoubleFlashAction() public {
        Dummy721 loanTest = new Dummy721();

        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);

        (bytes32 vaultHash, ) = _commitToLoan(
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
        WETH9.transfer(address(BOND_CONTROLLER), uint256(1));
        IBroker(BOND_CONTROLLER.getBroker(testBondVaultHash)).deposit(
            uint256(1),
            address(this)
        );
    }

    function testFailLendWithNonexistentVault() public {
        BrokerRouter emptyController;
        //        emptyController.lendToVault(testBondVaultHash, uint256(1));
        IBroker(BOND_CONTROLLER.getBroker(testBondVaultHash)).deposit(
            uint256(1),
            address(this)
        );
    }

    function testFailLendPastExpiration() public {
        _createBondVault(testBondVaultHash, true);
        vm.deal(lender, 1000 ether);
        vm.startPrank(lender);
        WETH9.deposit{value: 50 ether}();
        WETH9.approve(
            address(BOND_CONTROLLER.getBroker(testBondVaultHash)),
            type(uint256).max
        );

        vm.warp(block.timestamp + 10000 days); // forward past expiration date

        //        BOND_CONTROLLER.lendToVault(testBondVaultHash, 50 ether);
        IBroker(BOND_CONTROLLER.getBroker(testBondVaultHash)).deposit(
            50 ether,
            address(this)
        );
        vm.stopPrank();
    }

    function testFailCommitToLoanNotOwner() public {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);
        vm.prank(address(1));
        (bytes32 vaultHash, ) = _commitToLoan(
            tokenContract,
            tokenId,
            defaultTerms
        );
    }

    function testFailSoloLendNotAppraiser() public {
        vm.startPrank(appraiserOne);
        _createBondVault(testBondVaultHash, false);
        vm.stopPrank();

        vm.deal(lender, 1000 ether);
        vm.startPrank(lender);
        WETH9.deposit{value: 50 ether}();
        WETH9.approve(
            address(BOND_CONTROLLER.getBroker(testBondVaultHash)),
            type(uint256).max
        );

        vm.warp(block.timestamp + 10000 days); // forward past expiration date

        //        BOND_CONTROLLER.lendToVault(testBondVaultHash, 50 ether);
        IBroker(BOND_CONTROLLER.getBroker(testBondVaultHash)).deposit(
            50 ether,
            address(this)
        );
        vm.stopPrank();
    }
}
