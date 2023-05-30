// SPDX-License-Identifier: BUSL-1.1

/**
 *  █████╗ ███████╗████████╗ █████╗ ██████╗ ██╗ █████╗
 * ██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██║██╔══██╗
 * ███████║███████╗   ██║   ███████║██████╔╝██║███████║
 * ██╔══██║╚════██║   ██║   ██╔══██║██╔══██╗██║██╔══██║
 * ██║  ██║███████║   ██║   ██║  ██║██║  ██║██║██║  ██║
 * ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝
 *
 * Astaria Labs, Inc
 */

pragma solidity =0.8.17;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {
  MultiRolesAuthority
} from "solmate/auth/authorities/MultiRolesAuthority.sol";

import {
  IERC1155Receiver
} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

import {ERC721} from "gpl/ERC721.sol";

import {ICollateralToken} from "../interfaces/ICollateralToken.sol";
import {ILienToken} from "../interfaces/ILienToken.sol";
import {IPublicVault} from "../interfaces/IPublicVault.sol";
import {CollateralToken, IFlashAction} from "../CollateralToken.sol";
import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {VaultImplementation} from "../VaultImplementation.sol";
import {IVaultImplementation} from "../interfaces/IVaultImplementation.sol";
import {LienToken} from "../LienToken.sol";
import {PublicVault} from "../PublicVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";
import {
  Create2ClonesWithImmutableArgs
} from "create2-clones-with-immutable-args/Create2ClonesWithImmutableArgs.sol";

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";

contract InvalidVaultTesting is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeTransferLib for ERC20;

  function testEpochTooLow() public {
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    _warpToEpochEnd(publicVault);
    PublicVault(publicVault).processEpoch();
    vm.startPrank(address(1));
    uint256 vaultTokenBalance = IERC20(publicVault).balanceOf(address(1));
    ERC20(publicVault).safeApprove(address(ASTARIA_ROUTER), vaultTokenBalance);
    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidVaultState.selector,
        IPublicVault.InvalidVaultStates.EPOCH_TOO_LOW
      )
    );
    ASTARIA_ROUTER.redeemFutureEpoch({
      vault: IPublicVault(publicVault),
      shares: vaultTokenBalance,
      receiver: address(1),
      epoch: 0
    });
    vm.stopPrank();
  }

  function testEpochNotOver() public {
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );
    skip(7 days);
    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidVaultState.selector,
        IPublicVault.InvalidVaultStates.EPOCH_NOT_OVER
      )
    );
    PublicVault(publicVault).processEpoch();
  }

  function testWithdrawReserveNotZero() public {
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    _signalWithdraw(address(1), publicVault);

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(0);

    _warpToEpochEnd(publicVault);

    PublicVault(publicVault).processEpoch();

    _warpToEpochEnd(publicVault);
    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidVaultState.selector,
        IPublicVault.InvalidVaultStates.WITHDRAW_RESERVE_NOT_ZERO
      )
    );
    PublicVault(publicVault).processEpoch();
  }


  function testLiensOpenForEpochNotZero() public {
    TestNFT nft = new TestNFT(1);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(0);

    uint256 initialBalance = WETH9.balanceOf(address(this));

    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    (, ILienToken.Stack[] memory stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: standardLienDetails,
      amount: 10 ether,
      isFirstLien: true
    });

    _warpToEpochEnd(publicVault);
    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidVaultState.selector,
        IPublicVault.InvalidVaultStates.LIENS_OPEN_FOR_EPOCH_NOT_ZERO
      )
    );
    PublicVault(publicVault).processEpoch();
  }

  function testDepositCapExceeded() public {
    address publicVault = ASTARIA_ROUTER.newPublicVault({
      epochLength: 2 weeks,
      delegate: strategistTwo,
      underlying: address(WETH9),
      vaultFee: 0,
      allowListEnabled: false,
      allowList: new address[](0),
      depositCap: 15 ether
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 10 ether}),
      publicVault
    );


    vm.deal(address(2), 20 ether);
    vm.startPrank(address(2));
    WETH9.deposit{value: 10 ether}();
    WETH9.approve(address(TRANSFER_PROXY), 10 ether);
    vm.expectRevert(
      abi.encodeWithSelector(
        IPublicVault.InvalidVaultState.selector,
        IPublicVault.InvalidVaultStates.DEPOSIT_CAP_EXCEEDED
      )
    );
    ASTARIA_ROUTER.depositToVault(
      IERC4626(publicVault),
      address(2),
      10 ether,
      uint256(0)
    );
    vm.stopPrank();
  }
}
