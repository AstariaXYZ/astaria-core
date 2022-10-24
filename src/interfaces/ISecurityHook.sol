pragma solidity ^0.8.17;

interface ISecurityHook {
  function getState(address, uint256) external view returns (bytes memory);
}
