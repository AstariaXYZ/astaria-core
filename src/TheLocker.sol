pragma solidity =0.8.17;

import "solmate/tokens/ERC721.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

interface ILocker {
  error NotOwner();

  struct Deposit {
    address token;
    uint256 amount;
  }

  function wrap(ERC20 token, uint256 amount) external;

  function unwrap(uint256 tokenId, address receiver) external;

  function getDeposit(uint256 tokenId) external view returns (Deposit memory);
}

contract TheLocker is ERC721("Astaria ERC20 Locker", "ERC20 Locked"), ILocker {
  using SafeTransferLib for ERC20;
  uint256 internal _counter;

  constructor() {
    _counter = 1;
  }

  mapping(uint256 => Deposit) public deposits;

  function wrap(ERC20 token, uint256 amount) external {
    token.safeTransferFrom(msg.sender, address(this), amount);
    deposits[_counter] = Deposit(address(token), amount);
    _safeMint(msg.sender, _counter);
    ++_counter;
  }

  function unwrap(uint256 tokenId, address receiver) external {
    if (msg.sender != ownerOf(tokenId)) {
      revert NotOwner();
    }
    Deposit memory deposit = deposits[tokenId];
    ERC20 token = ERC20(deposit.token);
    token.safeTransfer(receiver, deposit.amount);
    delete deposits[tokenId];
    _burn(tokenId);
  }

  function getDeposit(
    uint256 tokenId
  ) external view override returns (Deposit memory) {
    return deposits[tokenId];
  }

  function tokenURI(uint256 id) public view override returns (string memory) {
    return "";
  }
}
