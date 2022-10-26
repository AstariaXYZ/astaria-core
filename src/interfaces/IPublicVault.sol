pragma solidity ^0.8.17;

import {IERC165} from "./IERC165.sol";
import {IVault} from "gpl/interfaces/IVault.sol";

interface IPublicVault is IERC165, IVault {
  function beforePayment(uint256 escrowId, uint256 amount) external;

  function decreaseEpochLienCount(uint64 epoch) external;

  function getLienEpoch(uint64 end) external view returns (uint64);

  function afterPayment(uint256 lienId) external;

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
}
