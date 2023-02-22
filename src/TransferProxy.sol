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

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";
import {
  Create2ClonesWithImmutableArgs
} from "create2-clones-with-immutable-args/Create2ClonesWithImmutableArgs.sol";
import {Clone} from "create2-clones-with-immutable-args/Clone.sol";

import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";

//error receivber is a simple contract that only transfers tokens to the owner
//it is used to test the transfer proxy
contract Receiver is Clone {
  using SafeTransferLib for ERC20;

  function withdraw(ERC20 token, uint256 amount) public {
    require(msg.sender == _getArgAddress(0), "only owner can withdraw");
    token.safeTransfer(msg.sender, token.balanceOf(address(this)));
  }
}

contract TransferProxy is Auth, ITransferProxy {
  using SafeTransferLib for ERC20;
  mapping(address => address) public errorReceivers;
  address public immutable receiverImplementation;

  constructor(
    Authority _AUTHORITY,
    address _receiverImplementation
  ) Auth(msg.sender, _AUTHORITY) {
    receiverImplementation = _receiverImplementation;
  }

  function _transferToErrorReceiver(
    address token,
    address from,
    address to,
    uint256 amount
  ) internal {
    // Ensure that an initial owner has been supplied.

    if (errorReceivers[to] == address(0)) {
      errorReceivers[to] = Create2ClonesWithImmutableArgs.clone(
        receiverImplementation,
        abi.encodePacked(to),
        keccak256(abi.encodePacked(to))
      );
    }
    ERC20(token).safeTransferFrom(from, errorReceivers[to], amount);
  }

  function tokenTransferFrom(
    address token,
    address from,
    address to,
    uint256 amount
  ) external requiresAuth {
    ERC20(token).safeTransferFrom(from, to, amount);
  }

  function tokenTransferFromWithErrorReceiver(
    address token,
    address from,
    address to,
    uint256 amount
  ) external requiresAuth {
    try ERC20(token).transferFrom(from, to, amount) {} catch {
      _transferToErrorReceiver(token, from, to, amount);
    }
  }
}
