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

contract AstariaTest2 is TestHelpers {
    using FixedPointMathLib for uint256;
    using CollateralLookup for address;

    function testBasicPublicVaultLoan() public {
        Dummy721 nft = new Dummy721();
        address tokenContract = address(nft);
        uint256 tokenId = uint256(1);

        uint256 initialBalance = WETH9.balanceOf(address(this));

        address publicVault =
            _createPublicVault({strategist: strategistOne, delegate: strategistTwo, epochLength: 14 days});

        _lendToVault(Lender({addr: address(1), amountToLend: 50 ether, lendingDuration: 0 days}), publicVault);

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

        vm.warp(block.timestamp + 10 days);
    }

    function testBasicPrivateVaultLoan() public {
        Dummy721 nft = new Dummy721();
        address tokenContract = address(nft);
        uint256 tokenId = uint256(1);

        uint256 initialBalance = WETH9.balanceOf(address(this));

        address publicVault =
            _createPublicVault({strategist: strategistOne, delegate: strategistTwo, epochLength: 14 days});

        _lendToVault(Lender({addr: strategistOne, amountToLend: 50 ether, lendingDuration: 0 days}), publicVault);

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

        assertEq(WETH9.balanceOf(address(this)), initialBalance + 10 ether);
    }

    function testWithdrawProxy() public {
        Dummy721 nft = new Dummy721();
        address tokenContract = address(nft);
        uint256 tokenId = uint256(1);

        address publicVault =
            _createPublicVault({strategist: strategistOne, delegate: strategistTwo, epochLength: 14 days});

        _lendToVault(Lender({addr: address(1), amountToLend: 50 ether, lendingDuration: 0 days}), publicVault);

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
                duration: uint256(block.timestamp + 10 days),
                maxPotentialDebt: 50 ether
            }),
            amount: 10 ether
        });

        uint256 collateralId = tokenContract.computeId(tokenId);

        PublicVault(publicVault).redeem({shares: vaultTokenBalance, receiver: address(1), owner: address(1)});

        address withdrawProxy = PublicVault(publicVault).withdrawProxies(1);

        assertEq(vaultTokenBalance, IERC20(withdrawProxy).balanceOf(address(1)));

        vm.warp(block.timestamp + 14 days);

        uint256[] memory collateralIds = new uint[](1);
        collateralIds[1] = collateralId;

        uint256[] memory positions = new uint[](1);
        positions[1] = uint256(0);

        PublicVault(publicVault).processEpoch(collateralIds, positions);

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

        _lendToVault(Lender({addr: address(1), amountToLend: 50 ether, lendingDuration: 0 days}), publicVault);

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
                duration: uint256(block.timestamp + 13 days),
                maxPotentialDebt: 50 ether
            }),
            amount: 10 ether
        });

        uint256 collateralId = tokenContract.computeId(tokenId);

        PublicVault(publicVault).redeem({shares: vaultTokenBalance, receiver: address(1), owner: address(1)});

        address withdrawProxy = PublicVault(publicVault).withdrawProxies(1);

        // assertEq(vaultTokenBalance, IERC20(withdrawProxy).balanceOf(address(1)));

        vm.warp(block.timestamp + 13 days); // end of loan

        ASTARIA_ROUTER.liquidate(collateralId, uint256(0));

        assertTrue(
            PublicVault(publicVault).liquidationAccountants(0) != address(0), "LiquidationAccountant not deployed"
        ); // or maybe 1st epoch?

        _bid(address(2), tokenId, 20 ether);

        vm.warp(block.timestamp + 1 days); // epoch boundary

        uint256[] memory collateralIds = new uint[](1);
        collateralIds[1] = collateralId;

        uint256[] memory positions = new uint[](1);
        positions[1] = uint256(0);

        PublicVault(publicVault).processEpoch(collateralIds, positions);

        vm.warp(block.timestamp + 13 days);
        vm.startPrank(address(1));
        WithdrawProxy(withdrawProxy).withdraw(vaultTokenBalance);
        vm.stopPrank();

        assertEq(WETH9.balanceOf(address(1)), 70 ether);
    }
}
