pragma solidity ^0.8.17;

import {IFlashAction} from "core/interfaces/IFlashAction.sol";
import {IV3PositionManager} from "core/interfaces/IV3PositionManager.sol";
import {ERC721} from "gpl/ERC721.sol";

contract ClaimFees is IFlashAction {
  address public immutable positionManager;

  constructor(address positionManager_) {
    positionManager = positionManager_;
  }

  function onFlashAction(
    IFlashAction.Underlying calldata asset,
    bytes calldata data
  ) external override returns (bytes32) {
    address receiver = abi.decode(data, (address));
    IV3PositionManager(positionManager).collect(
      IV3PositionManager.CollectParams(
        asset.tokenId,
        receiver,
        type(uint128).max,
        type(uint128).max
      )
    );
    ERC721(asset.token).safeTransferFrom(
      address(this),
      msg.sender,
      asset.tokenId
    );
    return keccak256("FlashAction.onFlashAction");
  }
}
