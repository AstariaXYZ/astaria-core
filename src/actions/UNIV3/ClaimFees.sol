pragma solidity =0.8.17;

import {IFlashAction} from "core/interfaces/IFlashAction.sol";
import {IV3PositionManager} from "core/interfaces/IV3PositionManager.sol";
import {ERC721} from "gpl/ERC721.sol";
import {IERC721Receiver} from "core/interfaces/IERC721Receiver.sol";

contract ClaimFees is IFlashAction, IERC721Receiver {
  address public immutable positionManager;
  bytes32 private constant FLASH_ACTION_MAGIC =
    keccak256("FlashAction.onFlashAction");

  constructor(address positionManager_) {
    positionManager = positionManager_;
  }

  function onERC721Received(
    address,
    address,
    uint256,
    bytes calldata
  ) external override returns (bytes4) {
    return this.onERC721Received.selector;
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
    ERC721(asset.token).transferFrom(address(this), msg.sender, asset.tokenId);
    return FLASH_ACTION_MAGIC;
  }
}
