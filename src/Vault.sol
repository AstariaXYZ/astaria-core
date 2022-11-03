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

import {IAstariaRouter} from "interfaces/IAstariaRouter.sol";
import {IERC165} from "interfaces/IERC165.sol";
import {ILienToken} from "interfaces/ILienToken.sol";
import {ITokenBase} from "interfaces/ITokenBase.sol";
import {IVault} from "interfaces/IVault.sol";

import {AstariaVaultBase} from "AstariaVaultBase.sol";
import {LienToken} from "LienToken.sol";
import {VaultImplementation} from "VaultImplementation.sol";

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
