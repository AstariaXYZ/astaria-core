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
import {ILienToken} from "../interfaces/ILienToken.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {IBrokerRouter, BrokerRouter} from "../BrokerRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {Strings2} from "./utils/Strings2.sol";
import {IBroker, SoloBroker, BrokerImplementation} from "../BrokerImplementation.sol";
import {BrokerVault} from "../BrokerVault.sol";
import {TransferProxy} from "../TransferProxy.sol";

import {TestHelpers, Dummy721, IWETH9} from "./TestHelpers.t.sol";

string constant weth9Artifact = "src/tests/WETH9.json";

contract Fuzzers is TestHelpers {
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
        interestRate = bound(interestRate, 1e10, 1e12); // is this reasonable? (original tests were 1e20)
        uint256 maxInterestRate = bound(interestRate, 1e10, 1e12); // is this reasonable? (original tests were 1e20)
        duration = bound(
            duration,
            uint256(block.timestamp + 1 minutes),
            uint256(block.timestamp + 10 minutes)
        );

        uint256 maxAmount = uint256(100000000000000000000);
        uint256 maxDebt = uint256(10000000000000000000);

        // reverts with "Attempting to borrow more than available in the specified vault" starting at an upper bound of ~100 ether
        amount = bound(amount, 1 ether, 10 ether);

        Dummy721 loanTest = new Dummy721();
        address tokenContract = address(loanTest);
        uint256 tokenId = uint256(1);

        (bytes32 vaultHash, ) = _commitToLoan(
            tokenContract,
            tokenId,
            maxAmount,
            maxDebt,
            interestRate,
            maxInterestRate,
            duration,
            amount,
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
