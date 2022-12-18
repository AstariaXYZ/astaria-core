pragma solidity =0.8.17;

import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {IRouterBase} from "core/interfaces/IRouterBase.sol";

interface IAstariaVaultBase is IRouterBase {
  function owner() external view returns (address);

  function COLLATERAL_TOKEN() external view returns (ICollateralToken);

  function START() external view returns (uint256);

  function EPOCH_LENGTH() external view returns (uint256);

  function VAULT_FEE() external view returns (uint256);
}
