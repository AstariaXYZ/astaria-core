pragma solidity 0.8.17;

import {IPublicVault} from "core/interfaces/IPublicVault.sol";
import {IWithdrawProxy} from "core/interfaces/IWithdrawProxy.sol";

contract WithdrawKit {
  error WithdrawReserveNotZero(uint64 epoch, uint256 reserve);
  error MinAmountError();
  error ProcessEpochError(uint64 epoch, bytes reason);
  error LiensOpenForEpoch(uint64 epoch, uint256 liensOpenForEpoch);
  error FinalAuctionNotEnded(uint256 finalAuctionEnd);

  function redeem(IWithdrawProxy withdrawProxy, uint256 minAmountOut) external {
    IPublicVault publicVault = IPublicVault(address(withdrawProxy.VAULT()));
    uint64 currentEpoch = publicVault.getCurrentEpoch();
    uint64 claimableEpoch = withdrawProxy.CLAIMABLE_EPOCH();

    if (claimableEpoch > currentEpoch) {
      uint64 epochDelta = claimableEpoch - currentEpoch;

      for (uint64 j = 0; j < epochDelta; j++) {
        (uint256 liensOpenForEpoch, ) = publicVault.getEpochData(
          currentEpoch + j
        );
        if (liensOpenForEpoch != 0) {
          revert LiensOpenForEpoch(currentEpoch + j, liensOpenForEpoch);
        }

        publicVault.transferWithdrawReserve();
        try publicVault.processEpoch() {} catch Error(string memory reason) {
          revert(reason);
        } catch (bytes memory reason) {
          revert ProcessEpochError(currentEpoch + j, reason);
        }
      }
    } else if (currentEpoch == claimableEpoch) {
      (uint256 liensOpenForEpoch, ) = publicVault.getEpochData(currentEpoch);
      if (liensOpenForEpoch != 0) {
        revert LiensOpenForEpoch(currentEpoch, liensOpenForEpoch);
      }
    }

    publicVault.transferWithdrawReserve();

    uint256 finalAuctionEnd = withdrawProxy.getFinalAuctionEnd();
    if (finalAuctionEnd > block.timestamp) {
      revert FinalAuctionNotEnded(finalAuctionEnd);
    }

    (, , , , uint256 withdrawReserve, , ) = publicVault.getPublicVaultState();
    if (withdrawReserve > 0) {
      revert WithdrawReserveNotZero(claimableEpoch, withdrawReserve);
    }

    if (finalAuctionEnd != 0) {
      withdrawProxy.claim();
    }

    uint256 shareBalance = withdrawProxy.balanceOf(msg.sender);
    uint256 maxRedeem = withdrawProxy.maxRedeem(msg.sender);
    uint256 amountShares = maxRedeem < shareBalance ? maxRedeem : shareBalance;
    if (
      withdrawProxy.redeem(amountShares, msg.sender, msg.sender) < minAmountOut
    ) {
      revert MinAmountError();
    }
  }
}
