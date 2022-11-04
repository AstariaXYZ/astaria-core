// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";
import {ERC4626Cloned} from "gpl/ERC4626-Cloned.sol";
import {WithdrawVaultBase} from "core/WithdrawVaultBase.sol";
import {ITokenBase} from "core/interfaces/ITokenBase.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {PublicVault} from "./PublicVault.sol";
/**
 * @title WithdrawProxy
 * @notice This contract collects funds for liquidity providers who are exiting. When a liquidity provider is the first
 * in an epoch to mark that they would like to withdraw their funds, a WithdrawProxy for the liquidity provider's
 * PublicVault is deployed to collect loan repayments until the end of the next epoch. Users are minted WithdrawTokens
 * according to their balance in the protocol which are redeemable 1:1 for the underlying PublicVault asset by the end
 * of the next epoch.
 *
 */
contract WithdrawProxy is ERC4626Cloned, WithdrawVaultBase {
  using SafeTransferLib for ERC20;
  using FixedPointMathLib for uint256;
  using SafeCastLib for uint256;

  event Claimed(
    address withdrawProxy,
    uint256 withdrawProxyAmount,
    address publicVault,
    uint256 publicVaultAmount
  );

  bytes32 constant LIQUIDATION_ACCOUNTANT_SLOT =
    keccak256("xyz.astaria.liquidationAccountant.storage.location"); // TODO change

  enum InvalidStates {
    PROCESS_EPOCH_NOT_COMPLETE,
    FINAL_AUCTION_NOT_OVER,
    NOT_CLAIMED,
    NO_AUCTIONS,
    ALREADY_CLAIMED
  }
  error InvalidState(InvalidStates);

  function totalAssets() public view override returns (uint256) {
    return ERC20(underlying()).balanceOf(address(this));
  }

  /**
   * @notice Public view function to return the name of this WithdrawProxy.
   * @return The name of this WithdrawProxy.
   */
  function name()
    public
    view
    override(ITokenBase, WithdrawVaultBase)
    returns (string memory)
  {
    return
      string(
        abi.encodePacked("AST-WithdrawVault-", ERC20(underlying()).symbol())
      );
  }

  /**
   * @notice Public view function to return the symbol of this WithdrawProxy.
   * @return The symbol of this WithdrawProxy.
   */
  function symbol()
    public
    view
    override(ITokenBase, WithdrawVaultBase)
    returns (string memory)
  {
    return
      string(
        abi.encodePacked("AST-W", owner(), "-", ERC20(underlying()).symbol())
      );
  }

  /**
   * @notice Mints WithdrawTokens for withdrawing liquidity providers, redeemable by the end of the next epoch.
   * @param receiver The receiver of the Withdraw Tokens.
   * @param shares The number of shares to mint.
   */
  function mint(address receiver, uint256 shares) public virtual {
    require(msg.sender == owner(), "only owner can mint");
    _mint(receiver, shares);
  }

  /**
   * @notice Redeem funds collected in the WithdrawProxy.
   * @param shares The number of WithdrawToken shares to redeem.
   * @param receiver The receiver of the underlying asset.
   * @param owner The owner of the WithdrawTokens.
   * @return assets The amount of the underlying asset redeemed.
   */
  function redeem(
    uint256 shares,
    address receiver,
    address owner
  ) public virtual override returns (uint256 assets) {
    LAStorage storage s = _loadSlot();
    // If auction funds have been collected to the WithdrawProxy
    // but the PublicVault hasn't claimed its share, too much money will be sent to LPs
    if (s.finalAuctionEnd != 0 && !s.hasClaimed) { // if finalAuctionEnd is 0, no auctions were added
      revert InvalidState(InvalidStates.NOT_CLAIMED);
    }

    super.redeem(shares, receiver, owner);
  }

  /////////////////////////////LIQUIDATIONACCOUNTANT LOGIC///////////////////////////
  struct LAStorage {
    uint88 withdrawRatio;
    uint88 expected; // Expected value of auctioned NFTs. yIntercept (virtual assets) of a PublicVault are not modified on liquidation, only once an auction is completed.
    uint40 finalAuctionEnd; // when this is deleted, we know the final auction is over
    bool hasClaimed;
    uint256 withdrawReserveReceived; // amount received from PublicVault. The WETH balance of this contract - withdrawReserveReceived = amount received from liquidations.
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

  function increaseWithdrawReserveReceived(uint256 amount) public {
    require(msg.sender == VAULT(), "only vault can call");
    LAStorage storage s = _loadSlot();
    s.withdrawReserveReceived += amount;
  }

  /**
   * @notice Proportionally sends funds collected from auctions to withdrawing liquidity providers and the PublicVault for this LiquidationAccountant.
   */
  function claim() public {
    LAStorage storage s = _loadSlot();

    if(s.finalAuctionEnd == 0) {
      revert InvalidState(InvalidStates.NO_AUCTIONS);
    }

    if (PublicVault(VAULT()).getCurrentEpoch() < CLAIMABLE_EPOCH()) {
      revert InvalidState(InvalidStates.PROCESS_EPOCH_NOT_COMPLETE);
    }
    if (
      block.timestamp < s.finalAuctionEnd
      // || s.finalAuctionEnd == uint256(0)
    ) {
      revert InvalidState(InvalidStates.FINAL_AUCTION_NOT_OVER);
    }

    if(s.hasClaimed) {
      revert InvalidState(InvalidStates.ALREADY_CLAIMED);
    }
    uint256 transferAmount = 0;
    uint256 balance = ERC20(underlying()).balanceOf(address(this)) - s.withdrawReserveReceived;

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
      transferAmount = uint256(s.withdrawRatio).mulDivDown(balance, 1e18);

      // if (transferAmount > uint256(0)) {
      //   ERC20(underlying()).safeTransfer(WITHDRAW_PROXY(), transferAmount);
      // }

      unchecked {
        balance -= transferAmount;
      }

      ERC20(underlying()).safeTransfer(VAULT(), balance);
    }

    emit Claimed(address(this), transferAmount, VAULT(), balance);
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
    unchecked {
      _loadSlot().withdrawRatio = liquidationWithdrawRatio.safeCastTo88();
    }
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
    unchecked {
      s.expected += newLienExpectedValue.safeCastTo88();
      s.finalAuctionEnd = finalAuctionTimestamp.safeCastTo40();
    }
  }
}
