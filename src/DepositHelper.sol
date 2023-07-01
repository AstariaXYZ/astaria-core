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
import {IERC20} from "core/interfaces/IERC20.sol";
import {IWETH9} from "gpl/interfaces/IWETH9.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";
import {IAstariaVaultBase} from "core/interfaces/IAstariaVaultBase.sol";

contract DepositHelper {
  IWETH9 WETH;
  address public immutable transferProxy;

  constructor(address _transferProxy, address _weth) {
    transferProxy = _transferProxy;
    WETH = IWETH9(_weth);
  }

  function deposit(address vault) external payable returns (uint256 shares) {
    if (IAstariaVaultBase(vault).asset() != address(WETH)) revert();
    try WETH.deposit{value: msg.value}() {
      WETH.approve(transferProxy, msg.value);
      WETH.approve(vault, msg.value);

      IERC4626(vault).deposit(msg.value, address(this));
      shares = IERC20(vault).balanceOf(address(this));
      IERC20(vault).transfer(msg.sender, shares);
    } catch {
      revert();
    }
  }

  fallback() external payable {}

  receive() external payable {}
}
