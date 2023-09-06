pragma solidity 0.8.17;

import {IPublicVault} from "core/interfaces/IPublicVault.sol";

contract ProcessEpochBatch {
  function batchProcessEpoch(
    IPublicVault publicVault,
    uint256 loopCount
  ) external {
    uint64 j = 0;
    for (; j < loopCount; ) {
      publicVault.transferWithdrawReserve();
      try publicVault.processEpoch() {} catch Error(string memory reason) {
        break;
      } catch (bytes memory reason) {
        break;
      }

      unchecked {
        ++j;
      }
    }
  }
}
