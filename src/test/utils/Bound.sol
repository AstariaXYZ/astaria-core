// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;
import {StdUtils} from "forge-std/Test.sol";

abstract contract Bound is StdUtils {
  function _boundMin(
    uint256 value,
    uint256 min
  ) internal pure returns (uint256) {
    return _bound(value, min, type(uint256).max);
  }

  function _boundMax(
    uint256 value,
    uint256 max
  ) internal pure returns (uint256) {
    return _bound(value, 0, max);
  }

  function _boundNonZero(uint256 value) internal pure returns (uint256) {
    return _boundMin(value, 1);
  }

  function _toUint(address value) internal pure returns (uint256 output) {
    assembly {
      output := value
    }
  }

  function _toAddress(uint256 value) internal pure returns (address output) {
    assembly {
      output := value
    }
  }

  function _boundNonZero(address value) internal pure returns (address) {
    return _toAddress(_boundMin(_toUint(value), 1));
  }
}
