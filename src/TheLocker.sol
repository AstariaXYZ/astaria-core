pragma solidity =0.8.17;

import "gpl/ERC721.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibString} from "solady/utils/LibString.sol";
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
          LibString.toString(uint256(uint160(address(deposit.token)))),
          "',",
          "'amount': '",
          LibString.toString(deposit.amount),
          "'}"
        )
      );
  }
}
