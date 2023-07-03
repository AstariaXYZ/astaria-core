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

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";

interface ILienToken is IERC721 {
  enum FileType {
    NotSupported,
    CollateralToken,
    AstariaRouter,
    BuyoutFee,
    BuyoutFeeDurationCap,
    MinInterestBPS,
    MinDurationIncrease,
    MinLoanDuration
  }

  struct File {
    FileType what;
    bytes data;
  }

  event FileUpdated(FileType what, bytes data);

  struct LienStorage {
    ITransferProxy TRANSFER_PROXY;
    IAstariaRouter ASTARIA_ROUTER;
    ICollateralToken COLLATERAL_TOKEN;
    mapping(uint256 => bytes32) collateralStateHash;
    mapping(uint256 => AuctionData) collateralLiquidator;
  }
  struct AuctionData {
    uint256 amountOwed;
    address liquidator;
  }

  struct Details {
    uint256 maxAmount;
    uint256 rate; //rate per second
    uint256 duration;
    uint256 maxPotentialDebt;
    uint256 liquidationInitialAsk;
  }

  struct Lien {
    uint8 collateralType;
    address token; //20
    address payable vault; //20
    uint256 collateralId; //32 //contractAddress + tokenId
    Details details; //32 * 5
  }

  struct Point {
    uint256 amount; //11
    uint40 last; //5
    uint40 end; //5
  }

  struct Stack {
    Lien lien;
    Point point;
  }

  struct LienActionEncumber {
    address borrower;
    uint256 amount;
    address receiver;
    ILienToken.Lien lien;
    address feeTo;
    uint256 fee;
  }

  function calculateSlope(
    Stack calldata stack
  ) external pure returns (uint256 slope);

  function handleLiquidation(
    uint256 auctionWindow,
    Stack calldata stack,
    address liquidator
  ) external;

  function getOwed(Stack calldata stack) external view returns (uint256);

  function getOwed(
    Stack calldata stack,
    uint256 timestamp
  ) external view returns (uint256);

  function getInterest(Stack calldata stack) external returns (uint256);

  function getCollateralState(
    uint256 collateralId
  ) external view returns (bytes32);

  function createLien(
    LienActionEncumber calldata params
  ) external returns (uint256 lienId, Stack memory stack, uint256 owingAtEnd);

  function makePayment(Stack memory stack) external;

  function getAuctionLiquidator(
    uint256 collateralId
  ) external view returns (address liquidator);

  function file(File calldata file) external;

  event NewLien(uint256 indexed collateralId, Stack stack);
  event Payment(uint256 indexed lienId, uint256 amount);

  error InvalidFileData();
  error UnsupportedFile();
  error InvalidTokenId(uint256 tokenId);
  error InvalidLoanState();
  error InvalidSender();
  enum InvalidLienStates {
    INVALID_LIEN_ID,
    INVALID_HASH,
    INVALID_LIQUIDATION_INITIAL_ASK,
    PUBLIC_VAULT_RECIPIENT,
    COLLATERAL_NOT_LIQUIDATED,
    AMOUNT_ZERO,
    MIN_DURATION_NOT_MET
  }

  error InvalidLienState(InvalidLienStates);
}
