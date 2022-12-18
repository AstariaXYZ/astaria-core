pragma solidity =0.8.17;
import {IAstariaVaultBase} from "core/interfaces/IAstariaVaultBase.sol";
import {Clone} from "clones-with-immutable-args/Clone.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {IRouterBase} from "core/interfaces/IRouterBase.sol";

abstract contract AstariaVaultBase is Clone, IAstariaVaultBase {
  function name() public view virtual returns (string memory);

  function symbol() public view virtual returns (string memory);

  function ROUTER() public pure returns (IAstariaRouter) {
    return IAstariaRouter(_getArgAddress(0)); //ends at 20
  }

  function IMPL_TYPE() public pure returns (uint8) {
    return _getArgUint8(20); //ends at 21
  }

  function owner() public pure returns (address) {
    return _getArgAddress(21); //ends at 44
  }

  function asset() public pure virtual returns (address) {
    return _getArgAddress(41); //ends at 64
  }

  function START() public pure returns (uint256) {
    return _getArgUint256(61);
  }

  function EPOCH_LENGTH() public pure returns (uint256) {
    return _getArgUint256(93); //ends at 116
  }

  function VAULT_FEE() public pure returns (uint256) {
    return _getArgUint256(125);
  }

  function COLLATERAL_TOKEN() public view returns (ICollateralToken) {
    return ROUTER().COLLATERAL_TOKEN();
  }
}
