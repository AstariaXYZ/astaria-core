pragma solidity ^0.8.16;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {ERC721} from "gpl/ERC721.sol";
// import {ERC721} from "solmate/tokens/ERC721.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {CollateralToken} from "../CollateralToken.sol";
import {LienToken} from "../LienToken.sol";
import {ILienToken} from "../interfaces/ILienToken.sol";
import {ICollateralToken} from "../interfaces/ICollateralToken.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {Strings2} from "./utils/Strings2.sol";
import {IVault, VaultImplementation} from "../VaultImplementation.sol";
import {TransferProxy} from "../TransferProxy.sol";

import "./TestHelpers.t.sol";

contract Fuzzers is TestHelpers {
    using CollateralLookup for address;

    struct FuzzInputs {
        uint256 amount;
        uint256 interestRate;
        uint256 duration;
        uint256 maxPotentialDebt;
    }

    modifier validateInputs(FuzzInputs memory args) {
        args.amount = bound(args.amount, 1 ether, 100000000000000000000);
        args.interestRate = bound(args.interestRate, 1e10, 1e12);
        args.duration = bound(args.duration, block.timestamp + 1 minutes, block.timestamp + 10 minutes);
        args.maxPotentialDebt = bound(args.amount, 1 ether, 200000000000000000000);
        _;
    }

    function _commitToLien(address tokenContract, uint256 tokenId, FuzzInputs memory args)
        internal
        returns (bytes32 vaultHash, address vault, IAstariaRouter.Commitment memory terms)
    {
        LoanTerms memory loanTerms = LoanTerms({
            maxAmount: defaultTerms.maxAmount,
            interestRate: args.interestRate,
            duration: args.duration,
            amount: args.amount,
            maxPotentialDebt: args.maxPotentialDebt
        });
        return _commitToLien(tokenContract, tokenId, loanTerms);
    }

    function testFuzzCommitToLoan(FuzzInputs memory args) public validateInputs(args) {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);

        _commitToLien(tokenContract, tokenId, args);
    }

    // lien testing
    function testFuzzLienGetInterest(FuzzInputs memory args) public validateInputs(args) {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);
        (,, IAstariaRouter.Commitment memory terms) = _commitToLien(tokenContract, tokenId, args);

        uint256 collateralId = tokenContract.computeId(tokenId);

        uint256 interest = LIEN_TOKEN.getInterest(collateralId, uint256(0));
        assertEq(interest, uint256(0));

        // TODO calcs, waiting on better math for now
        // _warpToMaturity(collateralId, uint256(0));
        // interest = LIEN_TOKEN.getInterest(terms.collateralId, uint256(0));
    }

    function testFuzzLienGetTotalDebtForCollateralToken(FuzzInputs memory args) public validateInputs(args) {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);
        (,, IAstariaRouter.Commitment memory terms) = _commitToLien(tokenContract, tokenId, args);
        uint256 totalDebt = LIEN_TOKEN.getTotalDebtForCollateralToken(tokenContract.computeId(tokenId));
        // TODO calcs
        assert(args.amount <= totalDebt);
    }

    function testFuzzLienGetBuyout(FuzzInputs memory args) public validateInputs(args) {
        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);
        (,, IAstariaRouter.Commitment memory terms) = _commitToLien(tokenContract, tokenId, args);

        (uint256 owed, uint256 owedPlus) = LIEN_TOKEN.getBuyout(tokenContract.computeId(tokenId), uint256(0));

        assertLt(owed, owedPlus);
    }

    // TODO once isValidRefinance() hooked in, vm.assume better terms
    function testFuzzRefinanceLoan(FuzzInputs memory args, uint256 newInterestRate, uint256 newDuration)
        public
        validateInputs(args)
    {
        newInterestRate = bound(newInterestRate, 1e10, 1e12);
        newDuration = bound(newDuration, block.timestamp + 1 minutes, block.timestamp + 10 minutes);

        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);

        LoanTerms memory newTerms = LoanTerms({
            maxAmount: defaultTerms.maxAmount,
            interestRate: newInterestRate,
            duration: newDuration,
            amount: args.amount,
            maxPotentialDebt: args.maxPotentialDebt
        });

        _commitToLien(tokenContract, tokenId, args);
        _commitWithoutDeposit(tokenContract, tokenId, newTerms);
    }

    //    function testFuzzLendToVault(uint256 amount) public {
    //        amount = bound(amount, 1 ether, 20 ether); // starts failing at ~200 ether
    //
    //        Dummy721 lienTest = new Dummy721();
    //        address tokenContract = address(lienTest);
    //        uint256 tokenId = uint256(1);
    //
    //        bytes32 vaultHash = _commitToLien(tokenContract, tokenId);
    //
    //        // _createVault(vaultHash);
    //        vm.deal(lender, 1000 ether);
    //        vm.startPrank(lender);
    //        WETH9.deposit{value: 50 ether}();
    //        WETH9.approve(address(ASTARIA_ROUTER), type(uint256).max);
    //
    //        //        ASTARIA_ROUTER.lendToVault(vaultHash, amount);
    //        VaultImplementation(ASTARIA_ROUTER.getBroker(vaultHash)).deposit(
    //            amount,
    //            address(this)
    //        );
    //        vm.stopPrank();
    //    }

    function testFuzzCreateAuction(uint256 reservePrice) public {}

    function testFuzzCreateBid(uint256 amount) public {}
} // TODO repayLoan() test(s)
