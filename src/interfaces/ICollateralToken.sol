// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.15;

import {IAstariaRouter} from "interfaces/IAstariaRouter.sol";
import {IERC721} from "interfaces/IERC721.sol";
import {IFlashAction} from "interfaces/IFlashAction.sol";
import {ILienToken} from "interfaces/ILienToken.sol";
import {ITransferProxy} from "interfaces/ITransferProxy.sol";

import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";

interface ICollateralToken is IERC721 {
  struct Asset {
    address tokenContract;
    uint256 tokenId;
  }
  struct CollateralStorage {
    ITransferProxy TRANSFER_PROXY;
    ILienToken LIEN_TOKEN;
    IAstariaRouter ASTARIA_ROUTER;
    mapping(address => bool) flashEnabled;
    //mapping of the collateralToken ID and its underlying asset
    mapping(uint256 => Asset) idToUnderlying;
    //mapping of a security token hook for an nft's token contract address
    mapping(address => address) securityHooks;
  }
  struct File {
    bytes32 what;
    bytes data;
  }

  /**
   * @notice Executes a FlashAction using locked collateral. A valid FlashAction performs a specified action with the collateral within a single transaction and must end with the collateral being returned to the Vault it was locked in.
   * @param receiver The FlashAction to execute.
   * @param collateralId The ID of the CollateralToken to temporarily unwrap.
   * @param data Input data used in the FlashAction.
   */
  function flashAction(
    IFlashAction receiver,
    uint256 collateralId,
    bytes calldata data
  ) external;

  function securityHooks(address) external view returns (address);

  /**
   * @notice Retrieve the address and tokenId of the underlying NFT of a CollateralToken.
   * @param collateralId The ID of the CollateralToken wrapping the NFT.
   * @return The address and tokenId of the underlying NFT.
   */
  function getUnderlying(uint256 collateralId)
    external
    view
    returns (address, uint256);

  /**
   * @notice Unlocks the NFT for a CollateralToken and sends it to a specified address.
   * @param collateralId The ID for the CollateralToken of the NFT to unlock.
   * @param releaseTo The address to send the NFT to.
   */
  function releaseToAddress(uint256 collateralId, address releaseTo) external;

  event Deposit721(
    address indexed tokenContract,
    uint256 indexed tokenId,
    uint256 indexed collateralId,
    address depositedFor
  );
  event ReleaseTo(
    address indexed underlyingAsset,
    uint256 assetId,
    address indexed to
  );
  event FileUpdated(bytes32 indexed what, bytes data);

  error InvalidCollateral();
  error InvalidSender();
  error InvalidCollateralState(InvalidCollateralStates);
  error ProtocolPaused();

  enum InvalidCollateralStates {
    NO_AUCTION,
    AUCTION,
    ACTIVE_LIENS
  }

  error FlashActionCallbackFailed();
  error FlashActionSecurityCheckFailed();
  error FlashActionNFTNotReturned();
}
