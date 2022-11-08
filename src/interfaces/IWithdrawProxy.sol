pragma solidity ^0.8.17;
import {IERC165} from "core/interfaces/IERC165.sol";
import {IERC4626} from "./IERC4626.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {IRouterBase} from "core/interfaces/IRouterBase.sol";

interface IWithdrawProxy is IRouterBase, IERC165 {
  //  function ROUTER() external pure returns (IAstariaRouter);
  //
  //  function IMPL_TYPE() external pure override(IRouterBase) returns (uint8);

  function owner() external pure returns (address);

  function VAULT() external pure returns (address);

  function CLAIMABLE_EPOCH() external pure returns (uint256);

  //  function withdrawReserveReceived() external view returns (uint256);
  //
  //  function withdrawReserve() external view returns (uint256);
  //
  //  function withdrawRatio() external view returns (uint256);
  //
  //  function expected() external view returns (uint256);
  //
  //  function finalAuctionEnd() external view returns (uint256);
  //
  //  function publicVault() external view returns (address);
}
