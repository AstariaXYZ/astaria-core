// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import {IERC721} from "gpl/interfaces/IERC721.sol";

import {IAstariaRouter} from "./IAstariaRouter.sol";

interface ILienBase {
  struct Lien {
    uint256 amount; //32
    uint256 collateralId; //32
    address payee; // 20
    uint32 start; // 4
    uint32 last; // 4
    uint32 duration; // 4
    uint240 rate; // 30
    bool active; // 1
    uint8 position; // 1
  }

  struct LienActionEncumber {
    address tokenContract;
    uint256 tokenId;
    IAstariaRouter.LienDetails terms;
    bytes32 strategyRoot;
    uint256 amount;
    address vault;
  }

  struct LienActionBuyout {
    IAstariaRouter.Commitment incoming;
    uint256 position;
    address receiver;
  }

  function calculateSlope(uint256 lienId) external returns (uint256 slope);

  function changeInSlope(uint256 lienId, uint256 paymentAmount)
    external
    view
    returns (uint256 slope);

  function stopLiens(uint256 collateralId)
    external
    returns (uint256 reserve, uint256[] memory lienIds);

  function getBuyout(uint256 collateralId, uint256 index)
    external
    view
    returns (uint256, uint256);

  function removeLiens(uint256 collateralId, uint256[] memory remainingLiens)
    external;

  function getInterest(uint256 collateralId, uint256 position)
    external
    view
    returns (uint256);

  function getInterest(uint256) external view returns (uint256);

  function getLiens(uint256 _collateralId)
    external
    view
    returns (uint256[] memory);

  function getLien(uint256 lienId) external view returns (Lien memory);

  function getLien(uint256 collateralId, uint256 position)
    external
    view
    returns (Lien memory);

  function createLien(LienActionEncumber calldata params)
    external
    returns (uint256 lienId);

  function buyoutLien(LienActionBuyout calldata params) external;

  function makePayment(uint256 collateralId, uint256 paymentAmount) external;

  function makePayment(
    uint256 collateralId,
    uint256 totalCapitalAvailable,
    uint8 position,
    address payer
  ) external;

  function getTotalDebtForCollateralToken(uint256 collateralId)
    external
    view
    returns (uint256 totalDebt);

  function getTotalDebtForCollateralToken(
    uint256 collateralId,
    uint256 timestamp
  ) external view returns (uint256 totalDebt);

  function getPayee(uint256 lienId) external view returns (address);

  function setPayee(uint256 lienId, address payee) external;

  event NewLien(uint256 indexed lienId, Lien lien);
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

  enum InvalidStates {
    AUCTION,
    NO_DEPOSIT,
    DEBT_LIMIT
  }

  error InvalidCollateralState(InvalidStates);
}

interface ILienToken is ILienBase, IERC721 {}
