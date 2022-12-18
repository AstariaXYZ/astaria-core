// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity =0.8.17;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
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
import {IV3PositionManager} from "core/interfaces/IV3PositionManager.sol";

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

import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";
import {ClaimFees} from "../actions/UNIV3/ClaimFees.sol";

contract ForkedTesting is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;

  address constant V3_NFT_ADDRESS =
    address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88); // todo get real nft address

  function _hijackNFT(address nft, uint256 tokenId) internal {
    address holder = ERC721(nft).ownerOf(tokenId);
    vm.startPrank(holder);
    ERC721(nft).transferFrom(holder, address(this), tokenId);
    vm.stopPrank();
  }

  //run with blocknumber 15919113
  //matic weth pair
  function testClaimFeesAgainstV3Liquidity() public {
    address tokenContract = V3_NFT_ADDRESS;
    // fork mainnet on this block 15934974
    uint256 tokenId = uint256(349999);
    _hijackNFT(tokenContract, tokenId);

    ClaimFees claimFees = new ClaimFees(V3_NFT_ADDRESS);

    address privateVault = _createPrivateVault({
      strategist: strategistOne,
      delegate: strategistTwo
    });

    _lendToVault(
      Lender({addr: strategistOne, amountToLend: 50 ether}),
      privateVault
    );
    address[] memory assets;
    {
      (
        ,
        ,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        ,
        ,
        uint128 tokensOwed0,
        uint128 tokensOwed1
      ) = IV3PositionManager(tokenContract).positions(tokenId);

      assets = new address[](2);
      assets[0] = token0;
      assets[1] = token1;
      _commitToV3Lien({
        params: V3LienParams({
          assets: assets,
          fee: fee,
          borrower: address(0),
          tickLower: tickLower,
          tickUpper: tickUpper,
          liquidity: liquidity,
          strategist: strategistOne,
          strategistPK: strategistOnePK,
          tokenContract: tokenContract,
          amount0Min: tokensOwed0,
          amount1Min: tokensOwed1,
          tokenId: tokenId,
          details: standardLienDetails
        }),
        vault: privateVault,
        amount: 10 ether,
        stack: new ILienToken.Stack[](0),
        isFirstLien: true
      });
    }

    COLLATERAL_TOKEN.file(
      ICollateralToken.File(
        ICollateralToken.FileType.FlashEnabled,
        abi.encode(V3_NFT_ADDRESS, true)
      )
    );

    uint256 balance0Before = IERC20(assets[0]).balanceOf(address(this));
    uint256 balance1Before = IERC20(assets[1]).balanceOf(address(this));

    COLLATERAL_TOKEN.flashAction(
      IFlashAction(claimFees),
      tokenContract.computeId(tokenId),
      abi.encode(address(this))
    );
    assert(IERC20(assets[0]).balanceOf(address(this)) > balance0Before);
    assert(IERC20(assets[1]).balanceOf(address(this)) > balance1Before);
  }
}
