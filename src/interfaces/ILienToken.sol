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
  struct LienStorage {
    uint256 maxLiens;
    address WETH;
    ITransferProxy TRANSFER_PROXY;
    IAuctionHouse AUCTION_HOUSE;
    IAstariaRouter ASTARIA_ROUTER;
    ICollateralToken COLLATERAL_TOKEN;
    mapping(uint256 => bytes32) collateralStateHash;
    mapping(uint256 => LienMeta) lienMeta;
  }

  struct LienMeta {
    address payee;
    uint88 amountAtLiquidation;
  }

  struct Details {
    uint256 maxAmount;
    uint256 rate; //rate per second
    uint256 duration;
    uint256 maxPotentialDebt;
  }

  struct Lien {
    Details details;
    bytes32 strategyRoot;
    uint256 collateralId;
    address vault;
    address token;
  }

  struct Point {
    uint256 lienId;
    uint88 amount;
    uint8 position;
    uint40 last;
    uint40 end;
  }

  struct Stack {
    Lien lien;
    Point point;
  }

  struct LienActionEncumber {
    uint256 collateralId;
    uint256 amount;
    address receiver;
    ILienToken.Lien lien;
    Stack[] stack;
  }

  struct LienActionBuyout {
    IAstariaRouter.Commitment incoming;
    uint8 position;
    LienActionEncumber encumber;
  }

  /**
   * @notice Removes all liens for a given CollateralToken.
   * @param lien The Lien
   * @return lienId the lienId if valid otherwise reverts
   */
  function validateLien(Lien calldata lien)
    external
    view
    returns (uint256 lienId);

  function AUCTION_HOUSE() external view returns (IAuctionHouse);

  function ASTARIA_ROUTER() external view returns (IAstariaRouter);

  function COLLATERAL_TOKEN() external view returns (ICollateralToken);

  /**
   * @notice Computes the rate for a specified lien.
   * @param stack The Lien to compute the slope for.
   * @return slope The rate for the specified lien, in WETH per second.
   */
  function calculateSlope(Stack calldata stack)
    external
    returns (uint256 slope);

  /**
   * @notice Stops accruing interest for all liens against a single CollateralToken.
   * @param collateralId The ID for the  CollateralToken of the NFT used as collateral for the liens.
   */
  function stopLiens(
    uint256 collateralId,
    uint256 auctionWindow,
    ILienToken.Stack[] memory stack
  ) external returns (uint256 reserve, uint256[] memory);

  /**
   * @notice Computes and returns the buyout amount for a Lien.
   * @param stack the lien
   * @return The outstanding debt for the lien and the buyout amount for the Lien.
   */
  function getBuyout(Stack calldata stack)
    external
    view
    returns (uint256, uint256);

  /**
   * @notice Removes all liens for a given CollateralToken.
   * @param collateralId The ID for the underlying CollateralToken.
   * @param remainingLiens The IDs for the unpaid liens
   */
  function removeLiens(uint256 collateralId, uint256[] memory remainingLiens)
    external;

  /**
   * @notice Removes all liens for a given CollateralToken.
   * @param stack The Lien stack
   * @return the amount owed in uint192 at the current block.timestamp
   */
  function getOwed(Stack calldata stack) external view returns (uint192);

  /**
   * @notice Removes all liens for a given CollateralToken.
   * @param stack The Lien
   * @param timestamp the timestamp you want to inquire about
   * @return the amount owed in uint192
   */
  function getOwed(Stack calldata stack, uint256 timestamp)
    external
    view
    returns (uint192);

  /**
   * @notice Public view function that computes the interest for a LienToken since its last payment.
   * @param stack the Lien
   */
  function getInterest(Stack calldata stack) external returns (uint256);

  /**
   * @notice Retrieves a lienCount for specific collateral
   * @param collateralId the Lien to compute a point for
   */
  function getCollateralState(uint256 collateralId)
    external
    view
    returns (bytes32);

  /**
   * @notice Retrieves a specific point by its lienId.
   * @param stack the Lien to compute a point for
   */
  function getAmountOwingAtLiquidation(ILienToken.Stack calldata stack)
    external
    view
    returns (uint256);

  /**
   * @notice Retrieves a specific point by its lienId.
   * @param lienId the ID to get the point for
   */
  function getAmountOwingAtLiquidation(uint256 lienId)
    external
    view
    returns (uint256);

  /**
   * @notice Creates a new lien against a CollateralToken.
   * @param params LienActionEncumber data containing CollateralToken information and lien parameters (rate, duration, and amount, rate, and debt caps).
   */
  function createLien(LienActionEncumber memory params)
    external
    returns (
      uint256 lienId,
      Stack[] memory stack,
      uint256 slope
    );

  /**
   * @notice Purchase a LienToken for its buyout price.
   * @param params The LienActionBuyout data specifying the lien position, receiver address, and underlying CollateralToken information of the lien.
   */
  function buyoutLien(LienActionBuyout memory params)
    external
    returns (Stack[] memory, Stack memory);

  /**
   * @notice Make a payment for the debt against a CollateralToken.
   * @param stack the stack to pay against
   * @param amount The amount to pay against the debt.
   */
  function makePayment(Stack[] memory stack, uint256 amount)
    external
    returns (Stack[] memory newStack);

  /**
   * @notice Make a payment for the debt against a CollateralToken for a specific lien.
   * @param stack the stack to repay
   * @param collateralId the Lien to make a payment towards
   * @param paymentAmount The amount to pay against the debt.
   * @param payer the account paying
   * @return the amount of the payment that was applied to the lien
   */
  function makePaymentAuctionHouse(
    uint256[] memory stack,
    uint256 collateralId,
    uint256 paymentAmount,
    address payer
  ) external returns (uint256[] memory, uint256);

  function getMaxPotentialDebtForCollateral(ILienToken.Stack[] memory)
    external
    view
    returns (uint256);

  /**
   * @notice Retrieve the payee (address that receives payments and auction funds) for a specified Lien.
   * @param lienId The ID of the Lien.
   * @return The address of the payee for the Lien.
   */
  function getPayee(uint256 lienId) external view returns (address);

  /**
   * @notice Change the payee for a specified Lien.
   * @param lien the lienevent
   * @param newPayee The new Lien payee.
   */
  function setPayee(Lien calldata lien, address newPayee) external;

  /**
   * @notice Sets addresses for the AuctionHouse, CollateralToken, and AstariaRouter contracts to use.
   * @param what The identifier for what is being filed.
   * @param data The encoded address data to be decoded and filed.
   */
  function file(bytes32 what, bytes calldata data) external;

  event AddLien(uint256 indexed collateralId, uint256 lienId, uint8 position);
  event LienStackUpdated(uint256 indexed collateralId, Stack[] stack);
  event RemovedLien(uint256 indexed collateralId, uint8 position);
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
