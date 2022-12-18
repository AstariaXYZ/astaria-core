pragma solidity =0.8.17;

import {IERC165} from "core/interfaces/IERC165.sol";

interface IERC721 is IERC165 {
  event Transfer(address indexed from, address indexed to, uint256 indexed id);

  event Approval(
    address indexed owner,
    address indexed spender,
    uint256 indexed id
  );

  event ApprovalForAll(
    address indexed owner,
    address indexed operator,
    bool approved
  );

  function tokenURI(uint256 id) external view returns (string memory);

  function ownerOf(uint256 id) external view returns (address owner);

  function balanceOf(address owner) external view returns (uint256 balance);

  function approve(address spender, uint256 id) external;

  function setApprovalForAll(address operator, bool approved) external;

  function transferFrom(
    address from,
    address to,
    uint256 id
  ) external;

  function safeTransferFrom(
    address from,
    address to,
    uint256 id
  ) external;

  function safeTransferFrom(
    address from,
    address to,
    uint256 id,
    bytes calldata data
  ) external;
}
