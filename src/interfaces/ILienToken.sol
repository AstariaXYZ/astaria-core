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
    MinDurationIncrease
  }

  struct File {
    FileType what;
    bytes data;
  }

  event FileUpdated(FileType what, bytes data);

  struct LienStorage {
    uint8 maxLiens;
    address WETH;
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
  }

  struct LienMeta {
    address payee;
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
    Stack[] stack;
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

  function ASTARIA_ROUTER() external view returns (IAstariaRouter);

  function COLLATERAL_TOKEN() external view returns (ICollateralToken);

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
    Stack[] calldata stack,
    address liquidator
  ) external;

  /**
   * @notice Computes the fee Vaults earn when a Lien is bought out using the buyoutFee numerator and denominator.
   */
  function getBuyoutFee(
    uint256 remainingInterestIn,
    uint256 end,
    uint256 duration
  ) external view returns (uint256);

  /**
   * @notice Computes and returns the buyout amount for a Lien.
   * @param stack the lien
   */
  function getBuyout(
    Stack calldata stack
  ) external view returns (uint256 owed, uint256 buyout);

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
    LienActionEncumber memory params
  ) external returns (uint256 lienId, Stack[] memory stack, uint256 slope);

  /**
   * @notice Returns whether a new lien offers more favorable terms over an old lien.
   * A new lien must have a rate less than or equal to maxNewRate,
   * or a duration lower by minDurationIncrease, provided the other parameter does not get any worse.
   * @param newLien The new Lien for the proposed refinance.
   * @param position The Lien position against the CollateralToken.
   * @param stack The Stack of existing Liens against the CollateralToken.
   */
  function isValidRefinance(
    Lien calldata newLien,
    uint8 position,
    Stack[] calldata stack,
    uint256 owed,
    uint256 buyout,
    bool chargeable
  ) external view returns (bool);

  /**
   * @notice Purchase a LienToken for its buyout price.
   * @param params The LienActionBuyout data specifying the lien position, receiver address, and underlying CollateralToken information of the lien.
   */
  function buyoutLien(
    LienActionBuyout memory params
  )
    external
    returns (
      Stack[] memory stacks,
      Stack memory newStack,
      BuyoutLienParams memory buyoutParams
    );

  /**
   * @notice Called by the ClearingHouse (through Seaport) to pay back debt with auction funds.
   * @param collateralId The CollateralId of the liquidated NFT.
   * @param payment The payment amount.
   */
  function payDebtViaClearingHouse(
    address token,
    uint256 collateralId,
    uint256 payment,
    ClearingHouse.AuctionStack[] memory auctionStack
  ) external;

  /**
   * @notice Make a payment for the debt against a CollateralToken.
   * @param stack the stack to pay against
   * @param amount The amount to pay against the debt.
   */
  function makePayment(
    uint256 collateralId,
    Stack[] memory stack,
    uint256 amount
  ) external returns (Stack[] memory newStack);

  function makePayment(
    uint256 collateralId,
    Stack[] calldata stack,
    uint8 position,
    uint256 amount
  ) external returns (Stack[] memory newStack);

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
   * Calculates the debt accrued by all liens against a CollateralToken, assuming no payments are made until the end timestamp in the stack.
   * @param stack The stack data for active liens against the CollateralToken.
   */
  function getMaxPotentialDebtForCollateral(
    ILienToken.Stack[] memory stack
  ) external view returns (uint256);

  /**
   * Calculates the debt accrued by all liens against a CollateralToken, assuming no payments are made until the provided timestamp.
   * @param stack The stack data for active liens against the CollateralToken.
   * @param end The timestamp to accrue potential debt until.
   */
  function getMaxPotentialDebtForCollateral(
    ILienToken.Stack[] memory stack,
    uint256 end
  ) external view returns (uint256);

  /**
   * @notice Retrieve the payee (address that receives payments and auction funds) for a specified Lien.
   * @param lienId The ID of the Lien.
   * @return The address of the payee for the Lien.
   */
  function getPayee(uint256 lienId) external view returns (address);

  /**
   * @notice Sets addresses for the AuctionHouse, CollateralToken, and AstariaRouter contracts to use.
   * @param file The incoming file to handle.
   */
  function file(File calldata file) external;

  event AddLien(
    uint256 indexed collateralId,
    uint8 position,
    uint256 indexed lienId,
    Stack stack
  );
  enum StackAction {
    CLEAR,
    ADD,
    REMOVE,
    REPLACE
  }
  event LienStackUpdated(
    uint256 indexed collateralId,
    uint8 position,
    StackAction action,
    uint8 stackLength
  );
  event RemovedLiens(uint256 indexed collateralId);
  event Payment(uint256 indexed lienId, uint256 amount);
  event BuyoutLien(address indexed buyer, uint256 lienId, uint256 buyout);
  event PayeeChanged(uint256 indexed lienId, address indexed payee);

  error InvalidFileData();
  error UnsupportedFile();
  error InvalidTokenId(uint256 tokenId);
  error InvalidBuyoutDetails(uint256 lienMaxAmount, uint256 owed);
  error InvalidTerms();
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
    EXPIRED_LIEN,
    DEBT_LIMIT,
    MAX_LIENS,
    INVALID_HASH,
    INVALID_LIQUIDATION_INITIAL_ASK,
    INITIAL_ASK_EXCEEDED,
    EMPTY_STATE,
    PUBLIC_VAULT_RECIPIENT,
    COLLATERAL_NOT_LIQUIDATED
  }

  error InvalidState(InvalidStates);
  error InvalidCollateralState(InvalidStates);
}
