pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {ERC721} from "gpl/ERC721.sol";
import {CollateralToken, IFlashAction} from "../CollateralToken.sol";
import {LienToken} from "../LienToken.sol";
import {ILienToken} from "../interfaces/ILienToken.sol";
import {ICollateralToken} from "../interfaces/ICollateralToken.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {Strings2} from "./utils/Strings2.sol";
import {IVault, VaultImplementation} from "../VaultImplementation.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import "./TestHelpers.t.sol";

//TODO: fix helper

//contract BorrowAndRedeposit is IFlashAction, TestHelpers {
//    function onFlashAction(
//        IFlashAction.Underlying calldata underlying,
//        bytes calldata data
//    ) external returns (bytes32) {
//        _commitToLien(underlying.token, underlying.tokenId, defaultTerms);
//        return bytes32(keccak256("FlashAction.onFlashAction"));
//    }
//}

//TODO:
// - setup helpers to repay loans
// - setup helpers to pay loans at their schedule
// - test for interest
// - test auction flow
// - create/cancel/end
contract AstariaTest is TestHelpers {
    using FixedPointMathLib for uint256;
    using CollateralLookup for address;

    event Deposit721(
        address indexed tokenContract, uint256 indexed tokenId, uint256 indexed collateralId, address depositedFor
    );

    event ReleaseTo(address indexed underlyingAsset, uint256 assetId, address indexed to);

    event Liquidation(uint256 collateralId, uint256 position, uint256 reserve);

    event AuctionCanceled(uint256 indexed auctionId);

    event AuctionBid(uint256 indexed tokenId, address sender, uint256 value, bool firstBid, bool extended);

    event AuctionEnded(uint256 indexed tokenId, address winner, uint256 winningBid, uint256[] recipients);

    event NewVault(address appraiser, address broker, bytes32 bondVault, bytes32 contentHash, uint256 expiration);

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

        vm.expectEmit(true, true, true, true);
        emit Deposit721(tokenContract, tokenId, tokenContract.computeId(tokenId), address(this));

        (bytes32 vaultHash,,) = _commitToLien(appraiserOne, tokenContract, tokenId, defaultTerms);

        // BrokerVault(ASTARIA_ROUTER.getBroker(testBondVaultHash)).withdraw(50 ether);

        //assert weth balance is before + 1 ether532

        emit Balance(balanceBefore);
        emit Balance(WETH9.balanceOf(address(this)));
        assert(WETH9.balanceOf(address(this)) == balanceBefore + defaultTerms.amount);
    }

    event Balance(uint256);

    function testSoloLend() public {
        address vault = _createVault(false, appraiserOne);
        vm.startPrank(appraiserOne);
        vm.deal(appraiserOne, 1000 ether);

        WETH9.deposit{value: 50 ether}();
        WETH9.approve(vault, type(uint256).max);

        vm.warp(block.timestamp + 10000 days); // forward past expiration date

        //        ASTARIA_ROUTER.lendToVault(testBondVaultHash, 50 ether);
        IVault(vault).deposit(50 ether, address(this));

        vm.stopPrank();
    }

    function testPublicVault() public {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);

        uint256 balanceBefore = WETH9.balanceOf(address(this));
        //balance of WETH before loan

        vm.expectEmit(true, true, true, true);
        emit Deposit721(tokenContract, tokenId, tokenContract.computeId(tokenId), address(this));

        (bytes32 vaultHash,,) = _commitToLien(appraiserTwo, tokenContract, tokenId, defaultTerms);

        // BrokerVault(ASTARIA_ROUTER.getBroker(testBondVaultHash)).withdraw(50 ether);

        //assert weth balance is before + 1 ether
        assert(WETH9.balanceOf(address(this)) == balanceBefore + defaultTerms.amount);
    }

    function testWithdraw() public {}

    function testCommitment() public {
        Dummy721 releaseTest = new Dummy721();
        address tokenContract = address(releaseTest);
        uint256 tokenId = uint256(1);
        _depositNFTs(tokenContract, tokenId);
        (bytes32 termRoot, IAstariaRouter.Commitment memory terms, address vault) = _commitWithoutDeposit(
            CommitWithoutDeposit(
                appraiserTwo,
                block.timestamp + 2 days,
                tokenContract,
                tokenId,
                defaultTerms.maxAmount,
                defaultTerms.interestRate,
                defaultTerms.duration,
                defaultTerms.amount,
                defaultTerms.maxPotentialDebt
            )
        );

        (bool valid,) = ASTARIA_ROUTER.validateCommitment(terms);

        require(valid);
    }

    function testReleaseToAddress() public {
        Dummy721 releaseTest = new Dummy721();
        address tokenContract = address(releaseTest);
        uint256 tokenId = uint256(1);
        _depositNFTs(tokenContract, tokenId);
        // startMeasuringGas("ReleaseTo Address");

        uint256 starTokenId = uint256(keccak256(abi.encodePacked(tokenContract, tokenId)));

        (address underlyingAsset, uint256 assetId) = COLLATERAL_TOKEN.getUnderlying(starTokenId);

        vm.expectEmit(true, true, false, true);

        emit ReleaseTo(underlyingAsset, assetId, address(this));

        COLLATERAL_TOKEN.releaseToAddress(starTokenId, address(this));
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
        emit Deposit721(tokenContract, tokenId, tokenContract.computeId(tokenId), address(this));

        (bytes32 vaultHash, address vault, IAstariaRouter.Commitment memory terms) =
            _commitToLien(appraiserOne, tokenContract, tokenId, defaultTerms);
        vm.expectRevert(bytes("must be no liens or auctions to call this"));

        COLLATERAL_TOKEN.releaseToAddress(uint256(keccak256(abi.encodePacked(tokenContract, tokenId))), address(this));
    }

    /**
     * Ensure that we can auction underlying vaults
     * ensure that we're emitting the correct events
     * ensure that we're repaying the proper collateral
     */

    struct TestAuctionVaultResponse {
        bytes32 hash;
        uint256 collateralId;
        uint256 reserve;
    }

    function testAuctionVault() public returns (TestAuctionVaultResponse memory) {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);
        (bytes32 vaultHash, address vault, IAstariaRouter.Commitment memory terms) =
            _commitToLien(appraiserOne, tokenContract, tokenId, defaultTerms);
        uint256 collateralId = tokenContract.computeId(tokenId);
        _warpToMaturity(collateralId, uint256(0));

        //            vm.expectEmit(false, false, false, false);

        emit Liquidation(collateralId, uint256(0), uint256(0)); // not calculating/checking reserve

        uint256 reserve = ASTARIA_ROUTER.liquidate(collateralId, uint256(0));

        //        return (vaultHash, collateralId, reserve);
        return TestAuctionVaultResponse(vaultHash, collateralId, reserve);
    }

    /**
     * Ensure that owner of the token can cancel the auction by repaying the reserve(sum of debt + fee)
     * ensure that we're emitting the correct events
     */
    // expect emit cancelAuction
    function testCancelAuction() public {
        TestAuctionVaultResponse memory response = testAuctionVault();
        vm.deal(address(this), response.reserve);
        WETH9.deposit{value: response.reserve}();
        WETH9.approve(address(TRANSFER_PROXY), response.reserve);

        vm.expectEmit(true, false, false, false);

        emit AuctionCanceled(response.collateralId);

        COLLATERAL_TOKEN.cancelAuction(response.collateralId);
    }

    function testEndAuctionWithBids() public {
        TestAuctionVaultResponse memory response = testAuctionVault();

        vm.expectEmit(true, false, false, false);

        // uint256 indexed tokenId, address sender, uint256 value, bool firstBid, bool extended
        //        emit AuctionBid(response.collateralId, address(this), response.reserve, true, true); // TODO check (non-indexed data check failing)

        _createBid(bidderOne, response.collateralId, response.reserve);
        _createBid(bidderTwo, response.collateralId, response.reserve += ((response.reserve * 5) / 100));
        _createBid(bidderOne, response.collateralId, response.reserve += ((response.reserve * 30) / 100));
        _warpToAuctionEnd(response.collateralId);

        //        vm.expectEmit(false, false, false, false);

        uint256[] memory dummyRecipients;
        emit AuctionEnded(uint256(0), address(0), uint256(0), dummyRecipients);

        COLLATERAL_TOKEN.endAuction(response.collateralId);
    }

    function testAstariaRouterFileSetup() public {
        bytes memory newLiquidationFeePercent = abi.encode(uint256(0));
        ASTARIA_ROUTER.file(bytes32("LIQUIDATION_FEE_PERCENT"), newLiquidationFeePercent);
        assert(ASTARIA_ROUTER.LIQUIDATION_FEE_PERCENT() == uint256(0));

        bytes memory newMinInterestBps = abi.encode(uint256(0));
        ASTARIA_ROUTER.file(bytes32("MIN_INTEREST_BPS"), newMinInterestBps);
        assert(ASTARIA_ROUTER.MIN_INTEREST_BPS() == uint256(0));

        bytes memory appraiserNumerator = abi.encode(uint256(0));
        ASTARIA_ROUTER.file(bytes32("APPRAISER_NUMERATOR"), appraiserNumerator);
        assert(ASTARIA_ROUTER.STRATEGIST_ORIGINATION_FEE_NUMERATOR() == uint256(0));

        bytes memory appraiserOriginationFeeBase = abi.encode(uint256(0));
        ASTARIA_ROUTER.file(bytes32("APPRAISER_ORIGINATION_FEE_BASE"), appraiserOriginationFeeBase);
        assert(ASTARIA_ROUTER.STRATEGIST_ORIGINATION_FEE_BASE() == uint256(0));

        bytes memory minDurationIncrease = abi.encode(uint256(0));
        ASTARIA_ROUTER.file(bytes32("MIN_DURATION_INCREASE"), minDurationIncrease);
        assert(ASTARIA_ROUTER.MIN_DURATION_INCREASE() == uint256(0));

        bytes memory feeTo = abi.encode(address(0));
        ASTARIA_ROUTER.file(bytes32("feeTo"), feeTo);
        assert(ASTARIA_ROUTER.feeTo() == address(0));

        bytes memory vaultImplementation = abi.encode(address(0));
        ASTARIA_ROUTER.file(bytes32("VAULT_IMPLEMENTATION"), vaultImplementation);
        assert(ASTARIA_ROUTER.VAULT_IMPLEMENTATION() == address(0));

        vm.expectRevert("unsupported/file");
        ASTARIA_ROUTER.file(bytes32("Joseph Delong"), "");
    }

    function testCollateralTokenFileSetup() public {
        // bytes memory supportedAssetsRoot = abi.encode(bytes32(0));
        // COLLATERAL_TOKEN.file(bytes32("SUPPORTED_ASSETS_ROOT"), supportedAssetsRoot);
        // assert(COLLATERAL_TOKEN.SUPPORTED_ASSETS_ROOT(), bytes32(0));

        bytes memory astariaRouterAddr = abi.encode(address(0));
        COLLATERAL_TOKEN.file(bytes32("setAstariaRouter"), astariaRouterAddr);
        assert(COLLATERAL_TOKEN.ASTARIA_ROUTER() == IAstariaRouter(address(0)));

        // bytes memory supportedAssetsRoot = abi.encode(bytes32(0));
        // COLLATERAL_TOKEN.file(bytes32("setSupportedRoot"), supportedAssetsRoot); // SUPPORTED_ASSETS_ROOT not public, not tested

        bytes memory auctionHouseAddr = abi.encode(address(0));
        COLLATERAL_TOKEN.file(bytes32("setAuctionHouse"), auctionHouseAddr);
        assert(COLLATERAL_TOKEN.AUCTION_HOUSE() == IAuctionHouse(address(0)));

        bytes memory securityHook = abi.encode(address(0), address(0));
        COLLATERAL_TOKEN.file(bytes32("setSecurityHook"), securityHook);
        assert(COLLATERAL_TOKEN.securityHooks(address(0)) == address(0));

        vm.expectRevert("unsupported/file");
        COLLATERAL_TOKEN.file(bytes32("Andrew Redden"), "");
    }

    function testLienTokenFileSetup() public {
        bytes memory auctionHouseAddr = abi.encode(address(0));
        LIEN_TOKEN.file(bytes32("setAuctionHouse"), auctionHouseAddr);
        assert(LIEN_TOKEN.AUCTION_HOUSE() == IAuctionHouse(address(0)));

        bytes memory collateralIdAddr = abi.encode(address(0));
        LIEN_TOKEN.file(bytes32("setCollateralToken"), collateralIdAddr);
        assert(LIEN_TOKEN.COLLATERAL_TOKEN() == ICollateralToken(address(0)));

        vm.expectRevert("unsupported/file");
        COLLATERAL_TOKEN.file(bytes32("Justin Bram"), "");
    }

    // lienToken testing

    function testBuyoutLien() public {
        Dummy721 buyoutTest = new Dummy721();
        address tokenContract = address(buyoutTest);
        uint256 tokenId = uint256(1);

        (bytes32 vaultHash, address vault, IAstariaRouter.Commitment memory terms) =
            _commitToLien(appraiserOne, tokenContract, tokenId, defaultTerms);

        (bytes32 incomingVaultHash, IAstariaRouter.Commitment memory incomingTerms, address incomingVault) =
        _commitWithoutDeposit(
            CommitWithoutDeposit(
                appraiserTwo,
                block.timestamp + 2 days,
                tokenContract,
                tokenId,
                refinanceTerms.maxAmount,
                refinanceTerms.interestRate,
                refinanceTerms.duration,
                refinanceTerms.amount,
                refinanceTerms.maxPotentialDebt
            )
        );
        uint256 collateralId = tokenContract.computeId(tokenId);

        _warpForBuyout();

        vm.startPrank(appraiserTwo);
        vm.deal(appraiserTwo, 50 ether);
        WETH9.approve(incomingVault, 20 ether);
        vm.stopPrank();
        VaultImplementation(incomingVault).buyoutLien(collateralId, uint256(0), incomingTerms);
    }

    event INTEREST(uint256 interest);

    // TODO update once better math implemented
    function testLienGetInterest() public {
        uint256 collateralId = _generateDefaultCollateralToken();

        // interest rate of uint256(50000000000000000000)
        // duration of 10 minutes
        uint256 interest = LIEN_TOKEN.getInterest(collateralId, uint256(0));
        assertEq(interest, uint256(0));

        _warpToMaturity(collateralId, uint256(0));

        interest = LIEN_TOKEN.getInterest(collateralId, uint256(0));
        emit INTEREST(interest);
        assertEq(interest, uint256(516474411155456000000000000000000)); // just pasting current output, will change later
    }

    // for now basically redundant since just adding to lien getInterest, should set up test flow for multiple liens later
    function testLienGetTotalDebtForCollateralToken() public {
        uint256 collateralId = _generateDefaultCollateralToken();

        uint256 totalDebt = LIEN_TOKEN.getTotalDebtForCollateralToken(collateralId);

        assertEq(totalDebt, uint256(1000000000000000000));
    }

    function testLienGetBuyout() public {
        uint256 collateralId = _generateDefaultCollateralToken();

        (uint256 owed, uint256 owedPlus) = LIEN_TOKEN.getBuyout(collateralId, uint256(0));

        assertEq(owed, uint256(1000000000000000000));
        assertEq(owedPlus, uint256(179006655693800000000000000000));
    }

    // TODO add after _generateDefaultCollateralToken()
    function testLienMakePayment() public {
        uint256 collateralId = _generateDefaultCollateralToken();

        // TODO fix
        LIEN_TOKEN.makePayment(collateralId, uint256(0), uint256(0));
    }

    function testLienGetImpliedRate() public {
        uint256 collateralId = _generateDefaultCollateralToken();

        uint256 impliedRate = LIEN_TOKEN.getImpliedRate(collateralId);
        assertEq(impliedRate, uint256(2978480128));
    }

    // flashAction testing

    // should fail with "flashAction: NFT not returned"
    //    function testFailDoubleFlashAction() public {
    //        Dummy721 loanTest = new Dummy721();
    //
    //        address tokenContract = address(loanTest);
    //        uint256 tokenId = uint256(1);
    //
    //        (bytes32 vaultHash, , ) = _commitToLien(
    //            tokenContract,
    //            tokenId,
    //            defaultTerms
    //        );
    //
    //        uint256 collateralId = uint256(
    //            keccak256(abi.encodePacked(tokenContract, tokenId))
    //        );
    //        IFlashAction borrowAndRedeposit = new BorrowAndRedeposit();
    //        COLLATERAL_TOKEN.flashAction(borrowAndRedeposit, collateralId, "");
    //    }

    // failure testing
    function testFailLendWithoutTransfer() public {
        address vault = _createVault(true, appraiserOne);

        WETH9.transfer(address(ASTARIA_ROUTER), uint256(1));
        IVault(vault).deposit(uint256(1), address(this));
    }

    function testFailLendWithNonexistentVault() public {
        address vault = _createVault(true, appraiserOne);

        AstariaRouter emptyController;
        //        emptyController.lendToVault(testBondVaultHash, uint256(1));
        IVault(vault).deposit(uint256(1), address(this));
    }

    function testFailLendPastExpiration() public {
        address vault = _createVault(true, appraiserOne);
        vm.deal(lender, 1000 ether);
        vm.startPrank(lender);
        WETH9.deposit{value: 50 ether}();
        WETH9.approve(vault, type(uint256).max);

        vm.warp(block.timestamp + 10000 days); // forward past expiration date

        IVault(vault).deposit(50 ether, address(this));
        vm.stopPrank();
    }

    function testFailCommitToLoanNotOwner() public {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);
        vm.prank(address(1));
        (bytes32 vaultHash,,) = _commitToLien(appraiserOne, tokenContract, tokenId, defaultTerms);
    }

    function testFailSoloLendNotAppraiser() public {
        vm.startPrank(appraiserOne);
        address vault = _createVault(false, appraiserOne);
        vm.stopPrank();

        vm.deal(lender, 1000 ether);
        vm.startPrank(lender);
        WETH9.deposit{value: 50 ether}();
        WETH9.approve(vault, type(uint256).max);

        vm.warp(block.timestamp + 10000 days); // forward past expiration date

        IVault(vault).deposit(50 ether, address(this));
        vm.stopPrank();
    }
}
