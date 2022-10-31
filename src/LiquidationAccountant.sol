// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;
import {ILienToken} from "./interfaces/ILienToken.sol";
import {Clone} from "clones-with-immutable-args/Clone.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {LiquidationAccountantBase} from "core/LiquidationAccountantBase.sol";
import {PublicVault} from "./PublicVault.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {WithdrawProxy} from "./WithdrawProxy.sol";

/**
 * @title LiquidationAccountant
 * @author santiagogregory
 * @notice This contract collects funds from liquidations that overlap with an epoch boundary where liquidity providers are exiting.
 * When the final auction being tracked by a LiquidationAccountant for a given epoch is completed,
 * claim() proportionally pays out auction funds to withdrawing liquidity providers and the PublicVault.
 */
contract LiquidationAccountant is LiquidationAccountantBase {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for ERC20;

  event Claimed(
    address withdrawProxy,
    uint256 withdrawProxyAmount,
    address publicVault,
    uint256 publicVaultAmount
  );

  bytes32 constant LIQUIDATION_ACCOUNTANT_SLOT =
    keccak256("xyz.astaria.liquidationAccountant.storage.location");

  struct LAStorage {
    uint256 withdrawRatio;
    uint256 expected; // Expected value of auctioned NFTs. yIntercept (virtual assets) of a PublicVault are not modified on liquidation, only once an auction is completed.
    uint256 finalAuctionEnd; // when this is deleted, we know the final auction is over
    bool hasClaimed;
  }

  function _loadSlot() internal pure returns (LAStorage storage s) {
    bytes32 slot = LIQUIDATION_ACCOUNTANT_SLOT;
    assembly {
      s.slot := slot
    }
  }

  function getFinalAuctionEnd() public view returns (uint256) {
    LAStorage storage s = _loadSlot();
    return s.finalAuctionEnd;
  }

  function getWithdrawRatio() public view returns (uint256) {
    LAStorage storage s = _loadSlot();
    return s.withdrawRatio;
  }

  function getExpected() public view returns (uint256) {
    LAStorage storage s = _loadSlot();
    return s.expected;
  }

  function getHasClaimed() public view returns (bool) {
    LAStorage storage s = _loadSlot();
    return s.hasClaimed;
  }

  enum InvalidStates {
    PROCESS_EPOCH_NOT_COMPLETE,
    FINAL_AUCTION_NOT_OVER
  }

  error InvalidState(InvalidStates);

  /**
   * @notice Proportionally sends funds collected from auctions to withdrawing liquidity providers and the PublicVault for this LiquidationAccountant.
   */
  function claim() public {
    LAStorage storage s = _loadSlot();

    if (PublicVault(VAULT()).getCurrentEpoch() < CLAIMABLE_EPOCH()) {
      revert InvalidState(InvalidStates.PROCESS_EPOCH_NOT_COMPLETE);
    }
    if (
      block.timestamp < s.finalAuctionEnd || s.finalAuctionEnd == uint256(0)
    ) {
      revert InvalidState(InvalidStates.FINAL_AUCTION_NOT_OVER);
    }

    require(!s.hasClaimed);

    uint256 balance = ERC20(underlying()).balanceOf(address(this));

    if (balance < s.expected) {
      PublicVault(VAULT()).decreaseYIntercept(
        (s.expected - balance).mulWadDown(1e18 - s.withdrawRatio)
      );
    }

    // would happen if there was no WithdrawProxy for current epoch
    s.hasClaimed = true;

    if (s.withdrawRatio == uint256(0)) {
      ERC20(underlying()).safeTransfer(VAULT(), balance);
    } else {
      transferAmount = s.withdrawRatio.mulDivDown(balance, 1e18);

      if (transferAmount > uint256(0)) {
        ERC20(underlying()).safeTransfer(WITHDRAW_PROXY(), transferAmount);
      }

      unchecked {
        balance -= transferAmount;
      }

      ERC20(underlying()).safeTransfer(VAULT(), balance);
    }

    emit Claimed(WITHDRAW_PROXY(), transferAmount, VAULT(), balance);
  }

  /**
   * @notice Called by PublicVault if previous epoch's withdrawReserve hasn't been met.
   * @param amount The amount to attempt to drain from the LiquidationAccountant
   * @param withdrawProxy The address of the withdrawProxy to drain to.
   */
  function drain(uint256 amount, address withdrawProxy)
    public
    returns (uint256)
  {
    require(msg.sender == VAULT());
    uint256 balance = ERC20(underlying()).balanceOf(address(this));
    if (amount > balance) {
      amount = balance;
    }
    ERC20(underlying()).safeTransfer(withdrawProxy, amount);
    return amount;
  }

  /**
   * @notice Called at epoch boundary, computes the ratio between the funds of withdrawing liquidity providers and the balance of the underlying PublicVault so that claim() proportionally pays out to all parties.
   * @param liquidationWithdrawRatio The ratio of withdrawing to remaining LPs for the current epoch boundary.
   */
  function setWithdrawRatio(uint256 liquidationWithdrawRatio) public {
    require(msg.sender == VAULT());
    _loadSlot().withdrawRatio = liquidationWithdrawRatio;
  }

  /**
   * @notice Adds an auction scheduled to end in a new epoch to this LiquidationAccountant.
   * @param newLienExpectedValue The expected auction value for the lien being auctioned.
   * @param finalAuctionTimestamp The timestamp by which the auction being added is guaranteed to end. As new auctions are added to the LiquidationAccountant, this value will strictly increase as all auctions have the same maximum duration.
   */
  function handleNewLiquidation(
    uint256 newLienExpectedValue,
    uint256 finalAuctionTimestamp
  ) public {
    require(msg.sender == VAULT());
    LAStorage storage s = _loadSlot();
    s.expected += newLienExpectedValue;
    s.finalAuctionEnd = finalAuctionTimestamp;
  }
}
