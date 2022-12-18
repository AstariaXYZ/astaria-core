pragma solidity =0.8.17;
import {IERC165} from "core/interfaces/IERC165.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {IRouterBase} from "core/interfaces/IRouterBase.sol";

interface IWithdrawProxy is IRouterBase, IERC165, IERC4626 {
  function VAULT() external pure returns (address);

  function CLAIMABLE_EPOCH() external pure returns (uint64);

  /**
   * @notice Called at epoch boundary, computes the ratio between the funds of withdrawing liquidity providers and the balance of the underlying PublicVault so that claim() proportionally pays optimized-out to all parties.
   * @param liquidationWithdrawRatio The ratio of withdrawing to remaining LPs for the current epoch boundary.
   */
  function setWithdrawRatio(uint256 liquidationWithdrawRatio) external;

  /**
   * @notice Adds an auction scheduled to end in a new epoch to this WithdrawProxy, to ensure that withdrawing LPs get a proportional share of auction returns.
   * @param newLienExpectedValue The expected auction value for the lien being auctioned.
   * @param finalAuctionDelta The timestamp by which the auction being added is guaranteed to end. As new auctions are added to the WithdrawProxy, this value will strictly increase as all auctions have the same maximum duration.
   */
  function handleNewLiquidation(
    uint256 newLienExpectedValue,
    uint256 finalAuctionDelta
  ) external;

  /**
   * @notice Called by PublicVault if previous epoch's withdrawReserve hasn't been met.
   * @param amount The amount to attempt to drain from the WithdrawProxy.
   * @param withdrawProxy The address of the withdrawProxy to drain to.
   */
  function drain(uint256 amount, address withdrawProxy)
    external
    returns (uint256);

  /**
   * @notice Return any excess funds to the PublicVault, according to the withdrawRatio between withdrawing and remaining LPs.
   */
  function claim() external;

  /**
   * @notice Called when PublicVault sends a payment to the WithdrawProxy
   * to track how much of its WETH balance is from withdrawReserve payments instead of auction repayments
   * @param amount The amount paid by the PublicVault, deducted from its withdrawReserve.
   */
  function increaseWithdrawReserveReceived(uint256 amount) external;

  /**
   * @notice Returns the expected value of auctions tracked by this WithdrawProxy (total debt owed against liquidated collateral).
   */
  function getExpected() external view returns (uint256);

  /**
   * @notice Returns the ratio between the balance of LPs exiting the PublicVault and those remaining.
   */
  function getWithdrawRatio() external view returns (uint256);

  /**
   * Returns the end timestamp of the last auction tracked by this WithdrawProxy. After this timestamp has passed, claim() can be called.
   */
  function getFinalAuctionEnd() external view returns (uint256);

  error NotSupported();
}
