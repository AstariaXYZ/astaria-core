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
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";

import {IERC165} from "core/interfaces/IERC165.sol";
import {IVault} from "core/interfaces/IVault.sol";
import {ITokenBase} from "core/interfaces/ITokenBase.sol";
import {AstariaVaultBase} from "core/AstariaVaultBase.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";

import {LienToken} from "core/LienToken.sol";
import {VaultImplementation} from "core/VaultImplementation.sol";

/**
 * @title Vault
 */
contract Vault is AstariaVaultBase, VaultImplementation, IVault {
  using SafeTransferLib for ERC20;

  function name() public view override returns (string memory) {
    return string(abi.encodePacked("AST-Vault-", ERC20(underlying()).symbol()));
  }

  function symbol() public view override returns (string memory) {
    return
      string(
        abi.encodePacked("AST-V", owner(), "-", ERC20(underlying()).symbol())
      );
  }

  function deposit(uint256 amount, address receiver)
    public
    virtual
    override
    returns (uint256)
  {
    VIData storage s = _loadVISlot();
    require(s.allowList[msg.sender]);
    ERC20(underlying()).safeTransferFrom(
      address(msg.sender),
      address(this),
      amount
    );
    return amount;
  }

  function withdraw(uint256 amount) external {
    ERC20(underlying()).safeTransferFrom(
      address(this),
      address(msg.sender),
      amount
    );
  }

  function disableAllowList() external pure override(VaultImplementation) {
    //invalid action allowlist must be enabled for private vaults
    revert();
  }

  function modifyAllowList(address depositor, bool enabled)
    external
    pure
    override(VaultImplementation)
  {
    //invalid action private vautls can only be the owner or strategist
    revert();
  }
}
