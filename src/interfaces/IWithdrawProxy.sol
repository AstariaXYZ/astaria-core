pragma solidity ^0.8.17;
import {IERC165} from "core/interfaces/IERC165.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {IRouterBase} from "core/interfaces/IRouterBase.sol";

interface IWithdrawProxy is IRouterBase, IERC165 {
  function owner() external pure returns (address);

  function VAULT() external pure returns (address);

  function CLAIMABLE_EPOCH() external pure returns (uint256);

  error NotSupported();
}
