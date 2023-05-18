pragma solidity =0.8.17;

import {PublicVault} from "src/PublicVault.sol";
import {WithdrawProxy} from "src/WithdrawProxy.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract WithdrawKit {
  error MinAmountError();
  error LiensOpenForEpoch(uint256 epoch, uint256 liensOpenForEpoch);
  error FinalAuctionNotEnded(uint256 finalAuctionEnd);

  event log_named_uint(string name, uint256 value);

  function redeem(WithdrawProxy withdrawProxy, uint256 minAmountOut) external {
    PublicVault publicVault = PublicVault(address(withdrawProxy.VAULT()));

    uint64 currentEpoch = publicVault.getCurrentEpoch();
    uint64 claimableEpoch = withdrawProxy.CLAIMABLE_EPOCH();
    if (claimableEpoch > currentEpoch) {
      uint64 epochDelta = withdrawProxy.CLAIMABLE_EPOCH() - currentEpoch;

      uint64 j;
      for (; j < epochDelta; ) {
        (uint256 liensOpenForEpoch, ) = publicVault.getEpochData(
          currentEpoch + j
        );
        //this is as far as we could get if we proceeded
        // if you cannot process epoch but have no liens open
        if (liensOpenForEpoch != 0) {
          revert LiensOpenForEpoch(currentEpoch + j, liensOpenForEpoch);
        }
        publicVault.transferWithdrawReserve();
        publicVault.processEpoch();

        unchecked {
            ++j;
        }
      }
    }
    publicVault.transferWithdrawReserve();

    uint256 finalAuctionEnd = withdrawProxy.getFinalAuctionEnd();
    if (block.timestamp < finalAuctionEnd) {
      revert FinalAuctionNotEnded(finalAuctionEnd);
    }
    // if final auctionend is 0 you can call claim, if not, then you must wait before exiting
    if (finalAuctionEnd != 0) {
      withdrawProxy.claim();
    }

    uint256 shareBalance = withdrawProxy.balanceOf(msg.sender);
    uint256 maxRedeem = withdrawProxy.maxRedeem(msg.sender);
    uint256 amountShares = maxRedeem < shareBalance ? maxRedeem : shareBalance;
    if (
      (withdrawProxy.redeem(amountShares, msg.sender, msg.sender)) <
      minAmountOut
    ) {
      revert MinAmountError();
    }
  }
}
