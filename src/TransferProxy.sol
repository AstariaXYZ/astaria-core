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

  function trySafeTransferFrom(
    address token,
    address from,
    address to,
    uint256 amount
  ) internal returns (bool success) {
    assembly {
      // Get a pointer to some free memory.
      let freeMemoryPointer := mload(0x40)

      // Write the abi-encoded calldata into memory, beginning with the function selector.
      mstore(
        freeMemoryPointer,
        0x23b872dd00000000000000000000000000000000000000000000000000000000
      )
      mstore(add(freeMemoryPointer, 4), from) // Append the "from" argument.
      mstore(add(freeMemoryPointer, 36), to) // Append the "to" argument.
      mstore(add(freeMemoryPointer, 68), amount) // Append the "amount" argument.

      success := and(
        // Set success to whether the call reverted, if not we check it either
        // returned exactly 1 (can't just be non-zero data), or had no return data.
        or(
          and(eq(mload(0), 1), gt(returndatasize(), 31)),
          iszero(returndatasize())
        ),
        // We use 100 because the length of our calldata totals up like so: 4 + 32 * 3.
        // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
        // Counterintuitively, this call must be positioned second to the or() call in the
        // surrounding and() call or else returndatasize() will be zero during the computation.
        call(gas(), token, 0, freeMemoryPointer, 100, 0, 32)
      )
    }
  }

  function tokenTransferFromWithErrorReceiver(
    address token,
    address from,
    address to,
    uint256 amount
  ) external requiresAuth {
    if (!trySafeTransferFrom(token, from, to, amount)) {
      _transferToErrorReceiver(token, from, to, amount);
    }
  }
}
