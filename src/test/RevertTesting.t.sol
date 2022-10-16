pragma solidity ^0.8.16;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
// import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
// import {ERC721} from "solmate/tokens/ERC721.sol";
import {ERC721} from "gpl/ERC721.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
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
import {PublicVault} from "../PublicVault.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

import "./TestHelpers2.t.sol";

contract RevertTesting is TestHelpers {
    using FixedPointMathLib for uint256;
    using CollateralLookup for address;

    // function testFailLendWithoutTransfer() public {
    //     address vault = _createVault(true, appraiserOne);

    //     WETH9.transfer(address(ASTARIA_ROUTER), uint256(1));
    //     IVault(vault).deposit(uint256(1), address(this));
    // }

    // function testFailLendWithNonexistentVault() public {
    //     address vault = _createVault(true, appraiserOne);

    //     AstariaRouter emptyController;
    //     //        emptyController.lendToVault(testBondVaultHash, uint256(1));
    //     IVault(vault).deposit(uint256(1), address(this));
    // }

    // function testFailCommitToLoanNotOwner() public {
    //     Dummy721 loanTest = new Dummy721();
    //     address tokenContract = address(loanTest);
    //     uint256 tokenId = uint256(1);
    //     vm.prank(address(1));
    //     (bytes32 vaultHash,,) = _commitToLien(appraiserOne, tokenContract, tokenId, defaultTerms);
    // }

    // Only strategists for PrivateVaults can supply capital
    function testFailSoloLendNotAppraiser() public {
        Dummy721 nft = new Dummy721();
        address tokenContract = address(nft);
        uint256 tokenId = uint256(1);

        uint256 initialBalance = WETH9.balanceOf(address(this));

        address privateVault = _createPrivateVault({strategist: strategistOne, delegate: strategistTwo});

        _lendToVault(Lender({addr: address(1), amountToLend: 50 ether}), privateVault);
    }

    // PublicVaults should not be able to progress to the next epoch unless all liens that are able to be liquidated have been liquidated
    function testFailProcessEpochWithUnliquidatedLien() public {
        Dummy721 nft = new Dummy721();
        address tokenContract = address(nft);
        uint256 tokenId = uint256(1);

        uint256 initialBalance = WETH9.balanceOf(address(this));

        // create a PublicVault with a 14-day epoch
        address publicVault =
            _createPublicVault({strategist: strategistOne, delegate: strategistTwo, epochLength: 14 days});

        // lend 50 ether to the PublicVault as address(1)
        _lendToVault(Lender({addr: address(1), amountToLend: 50 ether}), publicVault);

        // borrow 10 eth against the dummy NFT
        _commitToLien({
            vault: publicVault,
            strategist: strategistOne,
            strategistPK: strategistOnePK,
            tokenContract: tokenContract,
            tokenId: tokenId,
            lienDetails: IAstariaRouter.LienDetails({
                maxAmount: 50 ether,
                rate: ((uint256(0.05 ether) / 365) * 1 days),
                duration: uint256(block.timestamp + 10 days),
                maxPotentialDebt: 50 ether
            }),
            amount: 10 ether
        });

        vm.warp(block.timestamp + 15 days);
        PublicVault(publicVault).processEpoch();
    }

    function testFailBorrowMoreThanMaxPotentialDebt() public {}
}
