pragma solidity ^0.8.16;

interface IVault {
  function deposit(uint256, address) external returns (uint256);
}
