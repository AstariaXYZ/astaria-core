pragma solidity ^0.8.17;

import {IERC4626Base} from "interfaces/IERC4626Base.sol";

import {Clone} from "clones-with-immutable-args/Clone.sol";

abstract contract ERC4626Base is Clone, IERC4626Base {
  function underlying() public view virtual returns (address);
}
