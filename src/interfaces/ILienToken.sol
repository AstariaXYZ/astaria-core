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
import {ClearingHouse} from "core/ClearingHouse.sol";

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
    mapping(uint256 => LienMeta) lienMeta;
    uint32 buyoutFeeNumerator;
    uint32 buyoutFeeDenominator;
    uint32 durationFeeCapNumerator;
    uint32 durationFeeCapDenominator;
    uint32 minDurationIncrease;
    uint32 minInterestBPS;
    uint32 minLoanDuration;
  }

  struct LienMeta {
    bool atLiquidation;
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
    address vault; //20
    bytes32 strategyRoot; //32
    uint256 collateralId; //32 //contractAddress + tokenId
    Details details; //32 * 5
  }

  struct Point {
    uint256 amount; //11
    uint40 last; //5
    uint40 end; //5
    uint256 lienId; //32
  }

  struct Stack {
    Lien lien;
    Point point;
  }

  struct LienActionEncumber {
    uint256 amount;
    address receiver;
    ILienToken.Lien lien;
  }

  struct LienActionBuyout {
    bool chargeable;
    uint8 position;
    LienActionEncumber encumber;
  }

  struct BuyoutLienParams {
    uint256 lienSlope;
    uint256 lienEnd;
  }

  /**
   * @notice Removes all liens for a given CollateralToken.
   * @param lien The Lien.
   * @return lienId The lienId of the requested Lien, if valid (otherwise, reverts).
   */
  function validateLien(
    Lien calldata lien
  ) external view returns (uint256 lienId);

  /**
   * @notice Computes the rate for a specified lien.
   * @param stack The Lien to compute the slope for.
   * @return slope The rate for the specified lien, in WETH per second.
   */
  function calculateSlope(
    Stack calldata stack
  ) external pure returns (uint256 slope);

  /**
   * @notice Stops accruing interest for all liens against a single CollateralToken.
   * @param collateralId The ID for the  CollateralToken of the NFT used as collateral for the liens.
   */
  function stopLiens(
    uint256 collateralId,
    uint256 auctionWindow,
    Stack calldata stack,
    address liquidator
  ) external;

  /**
   * @notice Removes all liens for a given CollateralToken.
   * @param stack The Lien stack
   * @return the amount owed in uint192 at the current block.timestamp
   */
  function getOwed(Stack calldata stack) external view returns (uint256);

  /**
   * @notice Removes all liens for a given CollateralToken.
   * @param stack The Lien
   * @param timestamp the timestamp you want to inquire about
   * @return the amount owed in uint192
   */
  function getOwed(
    Stack calldata stack,
    uint256 timestamp
  ) external view returns (uint256);

  /**
   * @notice Public view function that computes the interest for a LienToken since its last payment.
   * @param stack the Lien
   */
  function getInterest(Stack calldata stack) external returns (uint256);

  /**
   * @notice Retrieves a lienCount for specific collateral
   * @param collateralId the Lien to compute a point for
   */
  function getCollateralState(
    uint256 collateralId
  ) external view returns (bytes32);

  /**
   * @notice Retrieves a specific point by its lienId.
   * @param stack the Lien to compute a point for
   */
  function getAmountOwingAtLiquidation(
    ILienToken.Stack calldata stack
  ) external view returns (uint256);

  /**
   * @notice Creates a new lien against a CollateralToken.
   * @param params LienActionEncumber data containing CollateralToken information and lien parameters (rate, duration, and amount, rate, and debt caps).
   */
  function createLien(
    LienActionEncumber calldata params
  ) external returns (uint256 lienId, Stack memory stack, uint256 slope);

  /**
   * @notice Called by the ClearingHouse (through Seaport) to pay back debt with auction funds.
   * @param collateralId The CollateralId of the liquidated NFT.
   * @param payment The payment amount.
   */
  function payDebtViaClearingHouse(
    address token,
    uint256 collateralId,
    uint256 payment,
    ClearingHouse.AuctionStack memory auctionStack
  ) external;

  /**
   * @notice Make a payment for the debt against a CollateralToken.
   * @param stack the stack to pay against
   */
  function makePayment(Stack memory stack) external;

  /**
   * @notice Retrieves the AuctionData for a CollateralToken (The liquidator address and the AuctionStack).
   * @param collateralId The ID of the CollateralToken.
   */
  function getAuctionData(
    uint256 collateralId
  ) external view returns (ClearingHouse.AuctionData memory);

  /**
   * @notice Retrieves the liquidator for a CollateralToken.
   * @param collateralId The ID of the CollateralToken.
   */
  function getAuctionLiquidator(
    uint256 collateralId
  ) external view returns (address liquidator);

  /**
   * @notice Sets addresses for the AuctionHouse, CollateralToken, and AstariaRouter contracts to use.
   * @param file The incoming file to handle.
   */
  function file(File calldata file) external;

  event NewLien(uint256 indexed collateralId, Stack stack);
  event AppendLien(uint256 newLienId, uint256 last);
  event RemoveLien(uint256 removedLienId);
  event ReplaceLien(
    uint256 newLienId,
    uint256 removedLienId,
    uint256 next,
    uint256 last
  );

  event Payment(uint256 indexed lienId, uint256 amount);

  error InvalidFileData();
  error UnsupportedFile();
  error InvalidTokenId(uint256 tokenId);
  error InvalidBuyoutDetails(uint256 lienMaxAmount, uint256 owed);
  error InvalidRefinance();
  error InvalidRefinanceCollateral(uint256);
  error RefinanceBlocked();
  error InvalidLoanState();
  error InvalidSender();
  enum InvalidStates {
    NO_AUTHORITY,
    COLLATERAL_MISMATCH,
    ASSET_MISMATCH,
    NOT_ENOUGH_FUNDS,
    INVALID_LIEN_ID,
    COLLATERAL_AUCTION,
    COLLATERAL_NOT_DEPOSITED,
    LIEN_NO_DEBT,
    DEBT_LIMIT,
    INVALID_HASH,
    INVALID_LIQUIDATION_INITIAL_ASK,
    INITIAL_ASK_EXCEEDED,
    EMPTY_STATE,
    PUBLIC_VAULT_RECIPIENT,
    COLLATERAL_NOT_LIQUIDATED,
    AMOUNT_ZERO,
    MIN_DURATION_NOT_MET
  }

  error InvalidState(InvalidStates);
}
