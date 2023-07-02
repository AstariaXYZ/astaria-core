// SPDX-License-Identifier: BUSL-1.1

/**
 *  █████╗ ███████╗████████╗ █████╗ ██████╗ ██╗ █████╗
 * ██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██║██╔══██╗
 * ███████║███████╗   ██║   ███████║██████╔╝██║███████║
 * ██╔══██║╚════██║   ██║   ██╔══██║██╔══██╗██║██╔══██║
 * ██║  ██║███████║   ██║   ██║  ██║██║  ██║██║██║  ██║
 * ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝
 *
 * Astaria Labs, Inc
 */

pragma solidity =0.8.17;

import {IERC165} from "core/interfaces/IERC165.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {IRouterBase} from "core/interfaces/IRouterBase.sol";
import {IPublicVault} from "core/interfaces/IPublicVault.sol";

interface IWithdrawProxy is IRouterBase, IERC165, IERC4626 {
  function VAULT() external pure returns (IPublicVault);

  function CLAIMABLE_EPOCH() external pure returns (uint64);

  function setWithdrawRatio(uint256 liquidationWithdrawRatio) external;

  function drain(
    uint256 amount,
    address withdrawProxy
  ) external returns (uint256);

  function claim() external;

  function getState()
    external
    view
    returns (
      uint256 withdrawRatio,
      uint256 expected,
      uint40 finalAuctionEnd,
      uint256 withdrawReserveReceived
    );

  function increaseWithdrawReserveReceived(uint256 amount) external;

  function getExpected() external view returns (uint256);

  function getWithdrawRatio() external view returns (uint256);

  function getFinalAuctionEnd() external view returns (uint256);

  error NotSupported();
}
