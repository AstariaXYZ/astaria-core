// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import {IERC721} from "core/interfaces/IERC721.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";

interface ILienToken is IERC721 {
  struct Lien {
    uint256 amount; //32
    uint256 collateralId; //32
    address payee; // 20
    uint64 last; // 8
    uint8 position; // 1
    uint64 end; // 8
    uint192 rate; // 24
  }
  //uint256 amount; //32
  //    address payee; // 20
  //    uint64 last; // 8
  //    uint8 position; // 1
  //    uint40 end; // 8
  //    uint256 rate; // 24
  //  }
  struct Details {
    uint256 maxAmount;
    uint256 rate; //rate per second
    uint256 duration;
    uint256 maxPotentialDebt;
  }

  struct LienStorage {
    address WETH;
    ITransferProxy TRANSFER_PROXY;
    IAuctionHouse AUCTION_HOUSE;
    IAstariaRouter ASTARIA_ROUTER;
    ICollateralToken COLLATERAL_TOKEN;
    uint256 maxLiens;
    mapping(uint256 => LienDataPoint) lienData;
    mapping(uint256 => uint8) lienCount;
    mapping(uint256 => address) payee;
  }

  struct LienDataPoint {
    uint192 amount;
    uint40 last;
    bool active;
  }

  struct LienEvent {
    uint256 collateralId;
    address vault;
    address token;
    uint8 position;
    bytes32 strategyRoot;
    uint40 end;
    Details details;
  }

  struct LienActionEncumber {
    uint256 collateralId;
    ILienToken.Details terms;
    bytes32 strategyRoot;
    uint256 amount;
    address vault;
    LienEvent[] stack;
  }

  struct LienActionBuyout {
    IAstariaRouter.Commitment incoming;
    uint256 position;
    address receiver;
    ILienToken.LienEvent[] stack;
    ILienToken.LienEvent newLien;
  }

  function validateLien(LienEvent calldata lienEvent)
    external
    view
    returns (uint256 lienId);

  function AUCTION_HOUSE() external view returns (IAuctionHouse);

  function ASTARIA_ROUTER() external view returns (IAstariaRouter);

  function COLLATERAL_TOKEN() external view returns (ICollateralToken);

  function calculateSlope(ILienToken.LienEvent calldata)
    external
    returns (uint256 slope);

  function stopLiens(
    uint256 collateralId,
    ILienToken.LienEvent[] calldata stack
  ) external returns (uint256 reserve);

  //  function getBuyout(uint256 collateralId, uint256 index)
  //    external
  //    view
  //    returns (uint256, uint256);

  function removeLiens(uint256 collateralId, uint256[] memory remainingLiens)
    external;

  function getOwed(LienEvent calldata lien) external view returns (uint192);

  function getOwed(LienEvent calldata lien, uint256 timestamp)
    external
    view
    returns (uint192);

  //  function getAccruedSinceLastPayment(uint256 lienId)
  //    external
  //    view
  //    returns (uint256);

  //  function getInterest(uint256 collateralId, uint256 position)
  //    external
  //    view
  //    returns (uint256);

  //  function getInterest(uint256) external view returns (uint256);

  function getLienCount(uint256 _collateralId) external view returns (uint256);

  //  function getLien(uint256 lienId) external view returns (Lien memory);

  //  function getPoint(uint256 collateralId, uint8 position)
  //    external
  //    view
  //    returns (LienDataPoint memory);

  function getPoint(uint256 lienId)
    external
    view
    returns (LienDataPoint memory);

  function getPoint(ILienToken.LienEvent calldata)
    external
    view
    returns (LienDataPoint memory);

  function createLien(LienActionEncumber calldata params)
    external
    returns (uint256 lienId, LienEvent[] memory stack);

  //  function buyoutLien(LienActionBuyout calldata params) external;

  function makePayment(LienEvent[] calldata stack, uint256) external;

  function makePayment(LienEvent calldata, uint256) external;

  function makePaymentAuctionHouse(
    uint256 lienId,
    uint256 collateralId,
    uint256 paymentAmount,
    uint8 position,
    address payer
  ) external returns (uint256);

  //  function getTotalDebtForCollateralToken(uint256 collateralId)
  //    external
  //    view
  //    returns (uint256 totalDebt);

  function getMaxPotentialDebtForCollateral(ILienToken.LienEvent[] memory)
    external
    view
    returns (uint256);

  //  function getTotalDebtForCollateralToken(
  //    uint256 collateralId,
  //    uint256 timestamp
  //  ) external view returns (uint256 totalDebt);

  function getPayee(uint256) external view returns (address);

  function setPayee(LienEvent calldata, address) external;

  event LienStackUpdated(uint256 indexed collateralId, LienEvent[] lien);
  event RemoveLien(
    uint256 indexed lienId,
    uint256 indexed collateralId,
    uint8 position
  );
  event RemovedLiens(uint256 indexed collateralId);
  event Payment(uint256 indexed lienId, uint256 amount);
  event BuyoutLien(address indexed buyer, uint256 lienId, uint256 buyout);
  event PayeeChanged(uint256 indexed lienId, address indexed payee);
  event File(bytes32 indexed what, bytes data);

  error UnsupportedFile();
  error InvalidBuyoutDetails(uint256 lienMaxAmount, uint256 owed);
  error InvalidTerms();
  error InvalidRefinance();
  error InvalidLoanState();
  enum InvalidStates {
    INVALID_LIEN_ID,
    COLLATERAL_AUCTION,
    COLLATERAL_NOT_DEPOSITED,
    LIEN_NO_DEBT,
    DEBT_LIMIT,
    MAX_LIENS
  }

  error InvalidState(InvalidStates);
  error InvalidCollateralState(InvalidStates);
}
