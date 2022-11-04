pragma solidity ^0.8.16;


interface ITokenBase {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);
}