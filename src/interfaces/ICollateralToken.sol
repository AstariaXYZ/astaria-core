// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity =0.8.17;

import {IERC721} from "core/interfaces/IERC721.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IFlashAction} from "core/interfaces/IFlashAction.sol";
import {
  ConsiderationInterface
} from "seaport/interfaces/ConsiderationInterface.sol";
import {
  ConduitControllerInterface
} from "seaport/interfaces/ConduitControllerInterface.sol";
import {IERC1155} from "core/interfaces/IERC1155.sol";
import {Order, OrderParameters} from "seaport/lib/ConsiderationStructs.sol";
import {ClearingHouse} from "core/ClearingHouse.sol";
import {IRoyaltyEngine} from "core/interfaces/IRoyaltyEngine.sol";

interface ICollateralToken is IERC721 {
  event ListedOnSeaport(uint256 collateralId, Order listingOrder);
  event FileUpdated(FileType what, bytes data);
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

  struct Asset {
    address tokenContract;
    uint256 tokenId;
  }

  struct CollateralStorage {
    ITransferProxy TRANSFER_PROXY;
    ILienToken LIEN_TOKEN;
    IAstariaRouter ASTARIA_ROUTER;
    ConsiderationInterface SEAPORT;
    IRoyaltyEngine ROYALTY_ENGINE;
    ConduitControllerInterface CONDUIT_CONTROLLER;
    address CONDUIT;
    address OS_FEE_PAYEE;
    uint16 osFeeNumerator;
    uint16 osFeeDenominator;
    bytes32 CONDUIT_KEY;
    mapping(uint256 => bytes32) collateralIdToAuction;
    mapping(address => bool) flashEnabled;
    //mapping of the collateralToken ID and its underlying asset
    mapping(uint256 => Asset) idToUnderlying;
    //mapping of a security token hook for an nft's token contract address
    mapping(address => address) securityHooks;
    mapping(uint256 => address) clearingHouse;
  }

  struct ListUnderlyingForSaleParams {
    ILienToken.Stack[] stack;
    uint256 listPrice;
    uint56 maxDuration;
  }

  enum FileType {
    NotSupported,
    AstariaRouter,
    SecurityHook,
    FlashEnabled,
    Seaport,
    OpenSeaFees
  }

  struct File {
    FileType what;
    bytes data;
  }

  /**
   * @notice Sets universal protocol parameters or changes the addresses for deployed contracts.
   * @param files Structs to file.
   */
  function fileBatch(File[] calldata files) external;

  /**
   * @notice Sets universal protocol parameters or changes the addresses for deployed contracts.
   * @param incoming The incoming File.
   */
  function file(File calldata incoming) external;

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

  function getClearingHouse(uint256) external view returns (address);

  struct AuctionVaultParams {
    address settlementToken;
    uint256 collateralId;
    uint256 maxDuration;
    uint256 startingPrice;
    uint256 endingPrice;
  }

  /**
   * @notice Send a CollateralToken to a Seaport auction on liquidation.
   * @param params The auction data.
   */
  function auctionVault(AuctionVaultParams calldata params)
    external
    returns (OrderParameters memory);

  /**
   * @notice Clears the auction for a CollateralToken.
   * @param collateralId The ID of the CollateralToken.
   */
  function settleAuction(uint256 collateralId) external;

  function SEAPORT() external view returns (ConsiderationInterface);

  function getOpenSeaData()
    external
    view
    returns (
      address,
      uint16,
      uint16
    );

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

  /**
   * @notice Permissionless hook which returns the underlying NFT for a CollateralToken to the liquidator after an auction.
   * @param params The Seaport data from the liquidation.
   */
  function liquidatorNFTClaim(OrderParameters memory params) external;

  error UnsupportedFile();
  error InvalidCollateral();
  error InvalidSender();
  error InvalidCollateralState(InvalidCollateralStates);
  error ProtocolPaused();
  error ListPriceTooLow();
  error InvalidConduitKey();
  error InvalidZone();

  enum InvalidCollateralStates {
    NO_AUTHORITY,
    NO_AUCTION,
    FLASH_DISABLED,
    AUCTION_ACTIVE,
    INVALID_AUCTION_PARAMS,
    ACTIVE_LIENS
  }

  error FlashActionCallbackFailed();
  error FlashActionSecurityCheckFailed();
  error FlashActionNFTNotReturned();
}
