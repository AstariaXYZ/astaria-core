// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity =0.8.17;

import {IERC165} from "core/interfaces/IERC165.sol";
import {IVaultImplementation} from "core/interfaces/IVaultImplementation.sol";

interface IPublicVault is IVaultImplementation {
  struct EpochData {
    uint64 liensOpenForEpoch;
    address withdrawProxy;
  }

  struct VaultData {
    uint88 yIntercept;
    uint48 slope;
    uint40 last;
    uint64 currentEpoch;
    uint88 withdrawReserve;
    uint88 liquidationWithdrawRatio;
    uint88 strategistUnclaimedShares;
    mapping(uint64 => EpochData) epochData;
  }

  struct BeforePaymentParams {
    uint256 lienSlope;
    uint256 amount;
    uint256 interestOwed;
  }

  struct BuyoutLienParams {
    uint256 lienSlope;
    uint256 lienEnd;
    uint256 increaseYIntercept;
  }

  struct AfterLiquidationParams {
    uint256 lienSlope;
    uint256 newAmount;
    uint40 lienEnd;
  }

  struct LiquidationPaymentParams {
    uint256 lienEnd;
  }

  function updateAfterLiquidationPayment(
    LiquidationPaymentParams calldata params
  ) external;

  /**
   * @notice Signal a withdrawal of funds (redeeming for underlying asset) in an arbitrary future epoch.
   * @param shares The number of VaultToken shares to redeem.
   * @param receiver The receiver of the WithdrawTokens (and eventual underlying asset)
   * @param owner The owner of the VaultTokens.
   * @param epoch The epoch to withdraw for.
   * @return assets The amount of the underlying asset redeemed.
   */
  function redeemFutureEpoch(
    uint256 shares,
    address receiver,
    address owner,
    uint64 epoch
  ) external returns (uint256 assets);

  /**
   * @notice Hook to update the slope and yIntercept of the PublicVault on payment.
   * The rate for the LienToken is subtracted from the total slope of the PublicVault, and recalculated in afterPayment().
   * @param params The params to adjust things
   */
  function beforePayment(BeforePaymentParams calldata params) external;

  /** @notice
   * hook to modify the liens open for then given epoch
   * @param epoch epoch to decrease liens of
   */
  function decreaseEpochLienCount(uint64 epoch) external;

  /** @notice
   * helper to return the LienEpoch for a given end date
   * @param end time to compute the end for
   */
  function getLienEpoch(uint64 end) external view returns (uint64);

  /**
   * @notice Hook to recalculate the slope of a lien after a payment has been made.
   * @param computedSlope The ID of the lien.
   */
  function afterPayment(uint256 computedSlope) external;

  /**
   * @notice Mints earned fees by the strategist to the strategist address.
   */
  function claim() external;

  /**
   * @return Seconds until the current epoch ends.
   */
  function timeToEpochEnd() external view returns (uint256);

  function timeToSecondEpochEnd() external view returns (uint256);

  /**
   * @notice Transfers funds from the PublicVault to the WithdrawProxy.
   */
  function transferWithdrawReserve() external;

  /**
   * @notice Rotate epoch boundary. This must be called before the next epoch can begin.
   */
  function processEpoch() external;

  /**
   * @notice Increase the PublicVault yIntercept.
   * @param amount newYIntercept The increase in yIntercept.
   */
  function increaseYIntercept(uint256 amount) external;

  /**
   * @notice Decrease the PublicVault yIntercept.
   * @param amount newYIntercept The decrease in yIntercept.
   */
  function decreaseYIntercept(uint256 amount) external;

  /**
   * Hook to update the PublicVault's slope, YIntercept, and last timestamp on a LienToken buyout.
   * @param params The lien buyout parameters (lienSlope, lienEnd, and increaseYIntercept)
   */
  function handleBuyoutLien(BuyoutLienParams calldata params) external;

  /**
   * Hook to update the PublicVault owner of a LienToken when it is sent to liquidation.
   * @param auctionWindow The auction duration.
   * @param params Liquidation data (lienSlope amount to deduct from the PublicVault slope, newAmount, and lienEnd timestamp)
   */
  function updateVaultAfterLiquidation(
    uint256 auctionWindow,
    AfterLiquidationParams calldata params
  ) external returns (address withdrawProxyIfNearBoundary);

  // ERRORS

  error InvalidState(InvalidStates);

  enum InvalidStates {
    EPOCH_TOO_LOW,
    EPOCH_TOO_HIGH,
    EPOCH_NOT_OVER,
    WITHDRAW_RESERVE_NOT_ZERO,
    LIENS_OPEN_FOR_EPOCH_NOT_ZERO,
    LIQUIDATION_ACCOUNTANT_FINAL_AUCTION_OPEN,
    LIQUIDATION_ACCOUNTANT_ALREADY_DEPLOYED_FOR_EPOCH,
    DEPOSIT_CAP_EXCEEDED
  }

  event StrategistFee(uint88 feeInShares);
  event YInterceptChanged(uint88 newYintercept);
  event WithdrawReserveTransferred(uint256 amount);
  event LienOpen(uint256 lienId, uint256 epoch);
}
