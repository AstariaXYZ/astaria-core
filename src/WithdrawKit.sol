pragma solidity =0.8.17;

import {PublicVault} from "src/PublicVault.sol";
import {WithdrawProxy} from "src/WithdrawProxy.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract WithdrawKit {
  error MinAmountError();
  error LiensOpenForEpoch(uint256 epoch);
  error FinalAuctionNotEnded(uint256 finalAuctionEnd);

  function redeem(WithdrawProxy withdrawProxy, uint256 minAmountOut) external {
    PublicVault publicVault = PublicVault(address(withdrawProxy.VAULT()));

    //    ERC20 asset = publicVault.asset();

    uint256 timedEpoch = getVaultEpochByBlockTime(publicVault);

    uint256 epochDelta = withdrawProxy.CLAIMABLE_EPOCH() -
      publicVault.getCurrentEpoch();
    //epoch delta is the length of the epochdata array
    (uint256 currentEpoch, , , , uint256 withdrawReserve, , ) = publicVault
      .getPublicVaultState();

    for (uint64 j = 0; j < epochDelta; j++) {
      uint64 targetEpoch = publicVault.getCurrentEpoch() + j;
      (uint256 liensOpenForEpoch, ) = publicVault.getEpochData(targetEpoch);
      //this is as far as we could get if we proceeded
      // if you cannot process epoch but have no liens open
      // if final auctionend is 0 you can call claim, if not, then you must wait before exiting
      if (liensOpenForEpoch != 0) {
        revert LiensOpenForEpoch(targetEpoch);
      }
      publicVault.transferWithdrawReserve();
      publicVault.processEpoch();
    }
    publicVault.transferWithdrawReserve();

    uint256 finalAuctionEnd = withdrawProxy.getFinalAuctionEnd();
    if (block.timestamp < finalAuctionEnd) {
      revert FinalAuctionNotEnded(finalAuctionEnd);
    }

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

  function getVaultEpochByBlockTime(
    PublicVault publicVault
  ) internal view returns (uint256 epoch) {
    uint256 start = publicVault.START();
    uint256 epochLength = publicVault.EPOCH_LENGTH();

    return (block.timestamp - start) / epochLength;
  }
}
