pragma solidity =0.8.17;

import "gpl/ERC721.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 * @dev String operations.
 */
library Strings {
  bytes16 private constant _HEX_SYMBOLS = "0123456789abcdef";

  /**
   * @dev Converts a `uint256` to its ASCII `string` decimal representation.
   */
  function toString(uint256 value) internal pure returns (string memory) {
    // Inspired by OraclizeAPI's implementation - MIT licence
    // https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol

    if (value == 0) {
      return "0";
    }
    uint256 temp = value;
    uint256 digits;
    while (temp != 0) {
      digits++;
      temp /= 10;
    }
    bytes memory buffer = new bytes(digits);
    while (value != 0) {
      digits -= 1;
      buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
      value /= 10;
    }
    return string(buffer);
  }

  /**
   * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation.
   */
  function toHexString(uint256 value) internal pure returns (string memory) {
    if (value == 0) {
      return "0x00";
    }
    uint256 temp = value;
    uint256 length = 0;
    while (temp != 0) {
      length++;
      temp >>= 8;
    }
    return toHexString(value, length);
  }

  /**
   * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation with fixed length.
   */
  function toHexString(
    uint256 value,
    uint256 length
  ) internal pure returns (string memory) {
    bytes memory buffer = new bytes(2 * length + 2);
    buffer[0] = "0";
    buffer[1] = "x";
    for (uint256 i = 2 * length + 1; i > 1; --i) {
      buffer[i] = _HEX_SYMBOLS[value & 0xf];
      value >>= 4;
    }
    require(value == 0, "Strings: hex length insufficient");
    return string(buffer);
  }
}

import {IERC721} from "core/interfaces/IERC721.sol";

interface ILocker is IERC721 {
  error NotOwner();
  error AmountMustBeGreaterThanZero();
  error NoCodeAtAddress();

  struct Deposit {
    address token;
    uint256 amount;
  }

  function deposit(
    ERC20 token,
    uint256 amount
  ) external returns (uint256 tokenId);

  function withdraw(
    uint256 tokenId,
    address receiver
  ) external returns (address, uint256);

  function getDeposit(uint256 tokenId) external view returns (Deposit memory);
}

contract TheLocker is ERC721, ILocker {
  using SafeTransferLib for ERC20;
  uint256 internal _counter;

  constructor() {
    _disableInitializers();
  }

  function initialize() public initializer {
    __initERC721("TheLocker", "LOCK");
    _counter = 1;
  }

  mapping(uint256 => Deposit) public deposits;

  function deposit(
    ERC20 token,
    uint256 amount
  ) external returns (uint256 tokenId) {
    if (amount == 0) {
      revert AmountMustBeGreaterThanZero();
    }
    if (address(token).code.length == 0) {
      revert NoCodeAtAddress();
    }
    token.safeTransferFrom(msg.sender, address(this), amount);
    tokenId = _counter;
    deposits[tokenId] = Deposit(address(token), amount);
    _safeMint(msg.sender, _counter);
    ++_counter;
  }

  function withdraw(
    uint256 tokenId,
    address receiver
  ) external returns (address, uint256) {
    if (msg.sender != ownerOf(tokenId)) {
      revert NotOwner();
    }
    Deposit memory deposit = deposits[tokenId];
    delete deposits[tokenId];
    _burn(tokenId);
    ERC20(deposit.token).safeTransfer(receiver, deposit.amount);
    return (deposit.token, deposit.amount);
  }

  function getDeposit(
    uint256 tokenId
  ) external view override returns (Deposit memory) {
    return deposits[tokenId];
  }

  function tokenURI(
    uint256 id
  ) public view override(ERC721, IERC721) returns (string memory) {
    Deposit memory deposit = deposits[id];
    //return a base64 encoded json string of the deposit data

    return
      string(
        abi.encodePacked(
          "data:application/json,",
          "{",
          "'asset': '",
          Strings.toHexString(uint256(uint160(address(deposit.token)))),
          "',",
          "'name': '",
          ERC20(deposit.token).name(),
          "',",
          "'symbol': '",
          ERC20(deposit.token).symbol(),
          "',",
          "'decimals': '",
          Strings.toString(ERC20(deposit.token).decimals()),
          "',",
          "'amount': '",
          Strings.toString(deposit.amount),
          "'}"
        )
      );
  }
}
