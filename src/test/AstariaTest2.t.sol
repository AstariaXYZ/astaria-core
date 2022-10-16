pragma solidity ^0.8.16;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {ERC721} from "gpl/ERC721.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {Strings2} from "./utils/Strings2.sol";
import {IVault, VaultImplementation} from "../VaultImplementation.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {PublicVault} from "../PublicVault.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

import "./TestHelpers2.t.sol";

contract TestNFT is MockERC721 {
    constructor(uint256 size) MockERC721("TestNFT", "TestNFT") {
        for (uint256 i = 0; i < size; ++i) {
            _mint(msg.sender, i);
        }
    }
}

contract AstariaTest2 is TestHelpers {
    using FixedPointMathLib for uint256;
    using CollateralLookup for address;
    using SafeCastLib for uint256;

    function testBasicPublicVaultLoan() public {
        // Dummy721 nft = new Dummy721();
        TestNFT nft = new TestNFT(1);
        address tokenContract = address(nft);
        uint256 tokenId = uint256(0);

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
                duration: 10 days,
                maxPotentialDebt: 50 ether
            }),
            amount: 10 ether
        });

        uint256 collateralId = tokenContract.computeId(tokenId);

        // make sure the borrow was successful
        assertEq(WETH9.balanceOf(address(this)), initialBalance + 10 ether);

        vm.warp(block.timestamp + 10 days);

        _repay(collateralId, 10 ether, address(this));

       
    }

    function testBasicPrivateVaultLoan() public {
        Dummy721 nft = new Dummy721();
        address tokenContract = address(nft);
        uint256 tokenId = uint256(1);

        uint256 initialBalance = WETH9.balanceOf(address(this));

        address privateVault = _createPrivateVault({strategist: strategistOne, delegate: strategistTwo});

        _lendToVault(Lender({addr: strategistOne, amountToLend: 50 ether}), privateVault);

        _commitToLien({
            vault: privateVault,
            strategist: strategistOne,
            strategistPK: strategistOnePK,
            tokenContract: tokenContract,
            tokenId: tokenId,
            lienDetails: IAstariaRouter.LienDetails({
                maxAmount: 50 ether,
                rate: ((uint256(0.05 ether) / 365) * 1 days),
                duration: 10 days,
                maxPotentialDebt: 50 ether
            }),
            amount: 10 ether
        });

        assertEq(WETH9.balanceOf(address(this)), initialBalance + 10 ether);
    }

    function testWithdrawProxy() public {
        Dummy721 nft = new Dummy721();
        address tokenContract = address(nft);
        uint256 tokenId = uint256(1);

        address publicVault =
            _createPublicVault({strategist: strategistOne, delegate: strategistTwo, epochLength: 14 days});

        _lendToVault(Lender({addr: address(1), amountToLend: 50 ether}), publicVault);

        uint256 collateralId = tokenContract.computeId(tokenId);

        uint256 vaultTokenBalance = IERC20(publicVault).balanceOf(address(1));

        _signalWithdrawAtFutureEpoch(address(1), publicVault, uint64(1));

        address withdrawProxy = PublicVault(publicVault).withdrawProxies(1);

        assertEq(vaultTokenBalance, IERC20(withdrawProxy).balanceOf(address(1)));

        vm.warp(block.timestamp + 14 days);

        PublicVault(publicVault).processEpoch();

        vm.warp(block.timestamp + 13 days);
        vm.startPrank(address(1));
        WithdrawProxy(withdrawProxy).withdraw(vaultTokenBalance);
        vm.stopPrank();
    }

    function testLiquidationAccountant() public {
        Dummy721 nft = new Dummy721();
        address tokenContract = address(nft);
        uint256 tokenId = uint256(1);

        address publicVault =
            _createPublicVault({strategist: strategistOne, delegate: strategistTwo, epochLength: 14 days});

        _lendToVault(Lender({addr: address(1), amountToLend: 50 ether}), publicVault);

        uint256 vaultTokenBalance = IERC20(publicVault).balanceOf(address(1));

        _commitToLien({
            vault: publicVault,
            strategist: strategistOne,
            strategistPK: strategistOnePK,
            tokenContract: tokenContract,
            tokenId: tokenId,
            lienDetails: IAstariaRouter.LienDetails({
                maxAmount: 50 ether,
                rate: ((uint256(0.05 ether) / 365) * 1 days),
                duration: 13 days,
                maxPotentialDebt: 50 ether
            }),
            amount: 10 ether
        });

        uint256 collateralId = tokenContract.computeId(tokenId);

        _signalWithdraw(address(1), publicVault);

        address withdrawProxy = PublicVault(publicVault).withdrawProxies(1);

        // assertEq(vaultTokenBalance, IERC20(withdrawProxy).balanceOf(address(1)));

        vm.warp(block.timestamp + 14 days); // end of loan

        ASTARIA_ROUTER.liquidate(collateralId, uint256(0));

        assertTrue(
            PublicVault(publicVault).liquidationAccountants(0) != address(0), "LiquidationAccountant not deployed"
        );

        _bid(address(2), tokenId, 20 ether);

        vm.warp(block.timestamp + 1 days); // epoch boundary

        PublicVault(publicVault).processEpoch();

        vm.warp(block.timestamp + 13 days);
        vm.startPrank(address(1));
        WithdrawProxy(withdrawProxy).withdraw(vaultTokenBalance);
        vm.stopPrank();

        assertEq(WETH9.balanceOf(address(1)), 70 ether);
    }

    event Here();

    function testEpochProcessionMultipleActors() public {
        address alice = address(1);
        address bob = address(2);
        address charlie = address(3);
        address devon = address(4);
        address edgar = address(5);

        TestNFT nft = new TestNFT(2);
        address tokenContract = address(nft);
        uint256 tokenId = uint256(0);

        address publicVault =
            _createPublicVault({strategist: strategistOne, delegate: strategistTwo, epochLength: 14 days});

        _lendToVault(Lender({addr: alice, amountToLend: 50 ether}), publicVault);

        
        _commitToLien({
            vault: publicVault,
            strategist: strategistOne,
            strategistPK: strategistOnePK,
            tokenContract: tokenContract,
            tokenId: tokenId,
            lienDetails: IAstariaRouter.LienDetails({
                maxAmount: 50 ether,
                rate: ((uint256(0.05 ether) / 365) * 1 days),
                duration: 13 days,
                maxPotentialDebt: 50 ether
            }),
            amount: 10 ether
        });
        uint256 collateralId = tokenContract.computeId(tokenId);

        vm.warp(block.timestamp + 10 days);
        _repay(collateralId, 10 ether, address(this));

        emit Here();

        

        emit Here();

        _lendToVault(Lender({addr: bob, amountToLend: 50 ether}), publicVault);

        _signalWithdraw(bob, publicVault);

        vm.warp(block.timestamp + 2 days);

        PublicVault(publicVault).processEpoch();

        // _lendToVault(Lender({addr: charlie, amountToLend: 50 ether}), publicVault);

        // Dummy721 nft2 = new Dummy721();
        // address tokenContract2 = address(nft2);
        // uint256 tokenId2 = uint256(2);

        // _commitToLien({
        //     vault: publicVault,
        //     strategist: strategistOne,
        //     strategistPK: strategistOnePK,
        //     tokenContract: tokenContract2,
        //     tokenId: tokenId2,
        //     lienDetails: IAstariaRouter.LienDetails({
        //         maxAmount: 50 ether,
        //         rate: ((uint256(0.05 ether) / 365) * 1 days),
        //         duration: 13 days,
        //         maxPotentialDebt: 50 ether
        //     }),
        //     amount: 10 ether
        // });

        // uint256 collateralId2 = tokenContract.computeId(tokenId2);

        // _lendToVault(Lender({addr: devon, amountToLend: 50 ether}), publicVault);

        // vm.warp(block.timestamp + 13 days - 1);

        // _repay(collateralId2, 20 ether, address(this));

        // vm.warp(block.timestamp + 2 days);

        // PublicVault(publicVault).processEpoch();

        // _signalWithdraw(alice, publicVault);
        // _signalWithdraw(charlie, publicVault);
        // _signalWithdraw(devon, publicVault);
        // _signalWithdraw(edgar, publicVault);

        // vm.warp(block.timestamp + 15 days);
        // PublicVault(publicVault).processEpoch();

        // vm.warp(block.timestamp + 15 days);
        // PublicVault(publicVault).processEpoch();
    }

    uint8 FUZZ_SIZE = uint8(10);

    struct FuzzInputs {
        uint256 lendAmount;
        uint256 lendDay;
        uint64 lenderWithdrawEpoch;
        uint256 borrowAmount;
        uint256 borrowDay;
        bool willRepay;
        uint256 repayAmount;
        uint256 bidAmount;
    }

    modifier validateInputs(FuzzInputs[] memory args) {
        for (uint8 i = 0; i < args.length; i++) {
            FuzzInputs memory input = args[i];
            input.lendAmount = bound(input.lendAmount, 1 ether, 2 ether).safeCastTo64();
            input.lendDay = bound(input.lendDay, 0, 42);
            input.lenderWithdrawEpoch = bound(input.lenderWithdrawEpoch, 0, 3).safeCastTo64();
            input.borrowAmount = bound(input.borrowAmount, 1 ether, 2 ether);
            input.borrowDay = bound(input.borrowDay, 0, 42);

            if (input.willRepay) {
                input.repayAmount = input.borrowAmount;
                input.bidAmount = 0;
            } else {
                input.repayAmount = bound(input.repayAmount, 0 ether, input.borrowAmount - 1);
                input.bidAmount = bound(input.bidAmount, 0 ether, input.borrowAmount * 2);
            }
        }
        _;
    }

    // a test that deploys a PublicVault, lends 50 ether to the Vault, and then calls _signalWithdraw without doing _commitToLien.
    //    function testWithdrawProxyWithoutCommitToLien(FuzzInputs[] memory args) public validateInputs(args) {
    //        address publicVault =
    //        _createPublicVault({strategist: strategistOne, delegate: strategistTwo, epochLength: 14 days});
    //        for (uint256 i = 0; i < 42; i++) {
    //            vm.warp(block.timestamp + (1 days));
    //
    //            for (uint256 j = 0; j < args.length; j++) {
    //                FuzzInputs memory input = args[j];
    //                if (input.lendDay == i) {
    //                    _lendToVault(Lender({addr: address(j), amountToLend: input.lendAmount}), publicVault);
    //                }
    //
    //                if (input.borrowDay == i) {
    //                    _commitToLien({
    //                        vault: publicVault,
    //                        strategist: strategistOne,
    //                        strategistPK: strategistOnePK,
    //                        tokenContract: tokenContract,
    //                        tokenId: tokenId,
    //                        lienDetails: IAstariaRouter.LienDetails({
    //                            maxAmount: 50 ether,
    //                            rate: ((uint256(0.05 ether) / 365) * 1 days),
    //                            duration: uint256(block.timestamp + 13 days),
    //                            maxPotentialDebt: 50 ether
    //                        }),
    //                        amount: input.borrowAmount
    //                    });
    //                }
    //
    //                if (input.lenderWithdrawEpoch == i) {
    //                    _signalWithdraw(address(j), publicVault);
    //                }
    //
    //                if (input.willRepay) {
    //                    _repayLien(address(j), publicVault, input.repayAmount);
    //                } else {
    //                    _bid(address(j), publicVault, input.bidAmount);
    //                }
    //            }
    //        }
    //    }

    function run() public {
        testBasicPublicVaultLoan();
    }
}
