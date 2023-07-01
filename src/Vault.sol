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

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {IERC165} from "core/interfaces/IERC165.sol";
import {VaultImplementation} from "core/VaultImplementation.sol";
import {IERC721Receiver} from "core/interfaces/IERC721Receiver.sol";

/**
 * @title Vault
 */
contract Vault is VaultImplementation {
  using SafeTransferLib for ERC20;

  function onERC721Received(
    address operator,
    address from,
    uint256 tokenId,
    bytes calldata data
  ) external override returns (bytes4) {
    //send token to the owner
    if (
      operator == address(ROUTER()) &&
      msg.sender == address(ROUTER().LIEN_TOKEN())
    ) {
      (
        address borrower,
        uint256 amount,
        ,
        ,
        address feeTo,
        uint256 feeRake
      ) = abi.decode(
          data,
          (address, uint256, uint40, uint256, address, uint256)
        );
      _issuePayout(borrower, amount, feeTo, feeRake);
      ERC721(msg.sender).safeTransferFrom(
        address(this),
        owner(),
        tokenId,
        data
      );
    }
    return this.onERC721Received.selector;
  }

  function name()
    public
    view
    virtual
    override(VaultImplementation)
    returns (string memory)
  {
    return string(abi.encodePacked("AST-Vault-", ERC20(asset()).symbol()));
  }

  function symbol()
    public
    view
    virtual
    override(VaultImplementation)
    returns (string memory)
  {
    return
      string(abi.encodePacked("AST-V", owner(), "-", ERC20(asset()).symbol()));
  }

  function supportsInterface(
    bytes4
  ) public pure virtual override(IERC165) returns (bool) {
    return false;
  }

  function deposit(
    uint256 amount,
    address receiver
  ) public virtual whenNotPaused returns (uint256) {
    VIData storage s = _loadVISlot();
    require(s.allowList[msg.sender] && receiver == owner());
    ERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    return amount;
  }

  function withdraw(uint256 amount) external {
    require(msg.sender == owner());
    ERC20(asset()).safeTransfer(msg.sender, amount);
  }

  function disableAllowList() external pure override(VaultImplementation) {
    //invalid action allowlist must be enabled for private vaults
    revert InvalidRequest(InvalidRequestReason.NO_AUTHORITY);
  }

  function enableAllowList() external pure override(VaultImplementation) {
    //invalid action allowlist must be enabled for private vaults
    revert InvalidRequest(InvalidRequestReason.NO_AUTHORITY);
  }

  function modifyAllowList(
    address,
    bool
  ) external pure override(VaultImplementation) {
    //invalid action private vautls can only be the owner or strategist
    revert InvalidRequest(InvalidRequestReason.NO_AUTHORITY);
  }
}
