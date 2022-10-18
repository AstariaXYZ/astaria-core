// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 * 
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {
  ERC4626Cloned,
  WithdrawVaultBase,
  ITokenBase
} from "gpl/ERC4626-Cloned.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";

/**
 * @title WithdrawProxy
 * @notice This contract collects funds for liquidity providers who are exiting. When a liquidity provider is the first in an epoch to mark that they would like to withdraw their funds, a WithdrawProxy for the liquidity provider's PublicVault is deployed to collect loan repayments until the end of the next epoch. Users are minted WithdrawTokens according to their balance in the protocol which are redeemable 1:1 for the underlying PublicVault asset by the end of the next epoch.
 *
 */
contract WithdrawProxy is ERC4626Cloned, WithdrawVaultBase {
  using SafeTransferLib for ERC20;
  using FixedPointMathLib for uint256;

  function totalAssets() public view override returns (uint256) {
    return ERC20(underlying()).balanceOf(address(this));
  }

  /**
   * @notice Public view function to return the name of this WithdrawProxy.
   * @return The name of this WithdrawProxy.
   */
  function name()
    public
    view
    override(ITokenBase, WithdrawVaultBase)
    returns (string memory)
  {
    return
      string(
        abi.encodePacked("AST-WithdrawVault-", ERC20(underlying()).symbol())
      );
  }

  /**
   * @notice Public view function to return the symbol of this WithdrawProxy.
   * @return The symbol of this WithdrawProxy.
   */
  function symbol()
    public
    view
    override(ITokenBase, WithdrawVaultBase)
    returns (string memory)
  {
    return
      string(
        abi.encodePacked("AST-W", owner(), "-", ERC20(underlying()).symbol())
      );
  }

  /**
   * @notice Sends collected funds to a withdrawing liquidity provider
   * @param amount The amount of the underlying PublicVault asset the user is withdrawing. The user must have as many WithdrawProxy tokens as underlying PublicVault assets they are withdrawing, and the WithdrawProxy must have a sufficient balance of the underlying PublicVault asset.
   */
  // function withdraw(uint256 amount) public {
  //     require(balanceOf[msg.sender] >= amount, "insufficient balance");
  //     ERC20(underlying()).safeTransfer(
  //         msg.sender, (amount.mulDivDown(1, totalSupply())) * ERC20(underlying()).balanceOf(address(this))
  //     );
  //     redeem(amount, msg.sender, msg.sender);
  //     _burn(msg.sender, amount);
  // }

  /**
   * @notice Mints WithdrawTokens for withdrawing liquidity providers, redeemable by the end of the next epoch.
   * @param receiver The receiver of the Withdraw Tokens.
   * @param shares The number of shares to mint.
   */
  function mint(address receiver, uint256 shares) public virtual {
    require(msg.sender == owner(), "only owner can mint");
    _mint(receiver, shares);
  }

  //    /**
  //     * @notice Burns WithdrawTokens, stops accruing funds for the liquidity provider to withdraw, and reinvests any accrued funds back into the liquidity provider's PublicVault.
  //     * @param amount The amount of WithdrawTokens the user wishes to burn.
  //     */
  //    function undoWithdraw(uint256 amount) public {
  //        require(ERC20(underlying()).balanceOf(msg.sender) >= amount);
  //    }
}
