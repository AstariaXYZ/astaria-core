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

import {IERC721} from "core/interfaces/IERC721.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {
  ConsiderationInterface
} from "seaport-types/src/interfaces/ConsiderationInterface.sol";
import {
  ConduitControllerInterface
} from "seaport-types/src/interfaces/ConduitControllerInterface.sol";
import {IERC1155} from "core/interfaces/IERC1155.sol";
import {
  Order,
  OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

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
    bytes32 auctionHash;
  }

  struct CollateralStorage {
    ITransferProxy TRANSFER_PROXY;
    ILienToken LIEN_TOKEN;
    IAstariaRouter ASTARIA_ROUTER;
    ConsiderationInterface SEAPORT;
    ConduitControllerInterface CONDUIT_CONTROLLER;
    address CONDUIT;
    bytes32 CONDUIT_KEY;
    //mapping of the collateralToken ID and its underlying asset
    mapping(uint256 => Asset) idToUnderlying;
  }

  struct ListUnderlyingForSaleParams {
    ILienToken.Stack stack;
    uint256 listPrice;
    uint56 maxDuration;
  }

  enum FileType {
    NotSupported,
    AstariaRouter,
    Seaport,
    CloseChannel
  }

  struct File {
    FileType what;
    bytes data;
  }

  function fileBatch(File[] calldata files) external;

  function file(File calldata incoming) external;

  function getConduit() external view returns (address);

  function getConduitKey() external view returns (bytes32);

  struct AuctionVaultParams {
    address settlementToken;
    uint256 collateralId;
    uint256 maxDuration;
    uint256 startingPrice;
    uint256 endingPrice;
  }

  function auctionVault(
    AuctionVaultParams calldata params
  ) external returns (OrderParameters memory);

  function SEAPORT() external view returns (ConsiderationInterface);

  function depositERC721(
    address tokenContract,
    uint256 tokenId,
    address from
  ) external;

  function CONDUIT_CONTROLLER()
    external
    view
    returns (ConduitControllerInterface);

  function getUnderlying(
    uint256 collateralId
  ) external view returns (address, uint256);

  function release(uint256 collateralId) external;

  function liquidatorNFTClaim(
    ILienToken.Stack memory stack,
    OrderParameters memory params,
    uint
  ) external;

  error UnsupportedFile();
  error InvalidCollateral();
  error InvalidSender();
  error InvalidOrder();
  error InvalidCollateralState(InvalidCollateralStates);
  error ProtocolPaused();
  error ListPriceTooLow();
  error InvalidConduitKey();
  error InvalidZoneHash();
  error InvalidTarget();
  error InvalidPaymentToken();

  enum InvalidCollateralStates {
    AUCTION_ACTIVE,
    ID_MISMATCH,
    INVALID_AUCTION_PARAMS,
    ACTIVE_LIENS,
    ESCROW_ACTIVE,
    NO_AUCTION
  }
}
