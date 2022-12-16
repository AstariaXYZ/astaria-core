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
import {IWithdrawProxy} from "core/interfaces/IWithdrawProxy.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {PublicVault} from "core/PublicVault.sol";
import {IERC20Metadata} from "core/interfaces/IERC20Metadata.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";

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

  uint256 private constant WITHDRAW_PROXY_SLOT =
    uint256(keccak256("xyz.astaria.WithdrawProxy.storage.location")) - 1;

  struct WPStorage {
    uint88 withdrawRatio;
    uint88 expected; // The sum of the remaining debt (amountOwed) accrued against the NFT at the timestamp when it is liquidated. yIntercept (virtual assets) of a PublicVault are not modified on liquidation, only once an auction is completed.
    uint40 finalAuctionEnd; // when this is deleted, we know the final auction is over
    uint256 withdrawReserveReceived; // amount received from PublicVault. The WETH balance of this contract - withdrawReserveReceived = amount received from liquidations.
  }

  enum InvalidStates {
    PROCESS_EPOCH_NOT_COMPLETE,
    FINAL_AUCTION_NOT_OVER,
    NOT_CLAIMED,
    CANT_CLAIM
  }
  error InvalidState(InvalidStates);

  function minDepositAmount()
    public
    view
    virtual
    override(ERC4626Cloned)
    returns (uint256)
  {
    return 0;
  }

  function decimals() public pure override returns (uint8) {
    return 18;
  }

  function asset()
    public
    pure
    override(ERC4626Cloned, WithdrawVaultBase)
    returns (address)
  {
    return super.asset();
  }

  function totalAssets()
    public
    view
    override(ERC4626Cloned, IERC4626)
    returns (uint256)
  {
    return ERC20(asset()).balanceOf(address(this));
  }

  /**
   * @notice Public view function to return the name of this WithdrawProxy.
   * @return The name of this WithdrawProxy.
   */
  function name()
    public
    view
    override(IERC20Metadata, WithdrawVaultBase)
    returns (string memory)
  {
    return
      string(abi.encodePacked("AST-WithdrawVault-", ERC20(asset()).symbol()));
  }

  /**
   * @notice Public view function to return the symbol of this WithdrawProxy.
   * @return The symbol of this WithdrawProxy.
   */
  function symbol()
    public
    view
    override(IERC20Metadata, WithdrawVaultBase)
    returns (string memory)
  {
    return
      string(abi.encodePacked("AST-W", VAULT(), "-", ERC20(asset()).symbol()));
  }

  /**
   * @notice Mints WithdrawTokens for withdrawing liquidity providers, redeemable by the end of the next epoch.
   * @param receiver The receiver of the Withdraw Tokens.
   * @param shares The number of shares to mint.
   */
  function mint(uint256 shares, address receiver)
    public
    virtual
    override(ERC4626Cloned, IERC4626)
    returns (uint256 assets)
  {
    require(msg.sender == VAULT(), "only vault can mint");
    _mint(receiver, shares);
    return shares;
  }

  function deposit(uint256 assets, address receiver)
    public
    virtual
    override(ERC4626Cloned, IERC4626)
    returns (uint256 shares)
  {
    revert NotSupported();
  }

  function withdraw(
    uint256 assets,
    address receiver,
    address owner
  ) public virtual override(ERC4626Cloned, IERC4626) returns (uint256 shares) {
    WPStorage storage s = _loadSlot();
    // If auction funds have been collected to the WithdrawProxy
    // but the PublicVault hasn't claimed its share, too much money will be sent to LPs
    if (s.finalAuctionEnd != 0) {
      // if finalAuctionEnd is 0, no auctions were added
      revert InvalidState(InvalidStates.NOT_CLAIMED);
    }

    return super.withdraw(assets, receiver, owner);
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
  ) public virtual override(ERC4626Cloned, IERC4626) returns (uint256 assets) {
    WPStorage storage s = _loadSlot();
    // If auction funds have been collected to the WithdrawProxy
    // but the PublicVault hasn't claimed its share, too much money will be sent to LPs
    if (s.finalAuctionEnd != 0) {
      // if finalAuctionEnd is 0, no auctions were added
      revert InvalidState(InvalidStates.NOT_CLAIMED);
    }

    return super.redeem(shares, receiver, owner);
  }

  function supportsInterface(bytes4 interfaceId)
    external
    view
    virtual
    returns (bool)
  {
    return interfaceId == type(IWithdrawProxy).interfaceId;
  }

  function _loadSlot() internal pure returns (WPStorage storage s) {
    uint256 slot = WITHDRAW_PROXY_SLOT;

    assembly {
      s.slot := slot
    }
  }

  function getFinalAuctionEnd() public view returns (uint256) {
    WPStorage storage s = _loadSlot();
    return s.finalAuctionEnd;
  }

  function getWithdrawRatio() public view returns (uint256) {
    WPStorage storage s = _loadSlot();
    return s.withdrawRatio;
  }

  function getExpected() public view returns (uint256) {
    WPStorage storage s = _loadSlot();
    return s.expected;
  }

  function increaseWithdrawReserveReceived(uint256 amount) public {
    require(msg.sender == VAULT(), "only vault can call");
    WPStorage storage s = _loadSlot();
    s.withdrawReserveReceived += amount;
  }

  function claim() public {
    WPStorage storage s = _loadSlot();

    if (s.finalAuctionEnd == 0) {
      revert InvalidState(InvalidStates.CANT_CLAIM);
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

    uint256 transferAmount = 0;
    uint256 balance = ERC20(asset()).balanceOf(address(this)) -
      s.withdrawReserveReceived; // will never underflow because withdrawReserveReceived is always increased by the transfer amount from the PublicVault

    if (balance < s.expected) {
      PublicVault(VAULT()).decreaseYIntercept(
        (s.expected - balance).mulWadDown(1e18 - s.withdrawRatio)
      );
    } else {
      PublicVault(VAULT()).increaseYIntercept(
        (balance - s.expected).mulWadDown(1e18 - s.withdrawRatio)
      );
    }

    if (s.withdrawRatio == uint256(0)) {
      ERC20(asset()).safeTransfer(VAULT(), balance);
    } else {
      transferAmount = uint256(s.withdrawRatio).mulDivDown(
        balance,
        10**ERC20(asset()).decimals()
      );

      unchecked {
        balance -= transferAmount;
      }

      if (balance > 0) {
        ERC20(asset()).safeTransfer(VAULT(), balance);
      }
    }
    s.finalAuctionEnd = 0;

    emit Claimed(address(this), transferAmount, VAULT(), balance);
  }

  function drain(uint256 amount, address withdrawProxy)
    public
    returns (uint256)
  {
    require(msg.sender == VAULT());
    uint256 balance = ERC20(asset()).balanceOf(address(this));
    if (amount > balance) {
      amount = balance;
    }
    ERC20(asset()).safeTransfer(withdrawProxy, amount);
    return amount;
  }

  function setWithdrawRatio(uint256 liquidationWithdrawRatio) public {
    require(msg.sender == VAULT());
    unchecked {
      _loadSlot().withdrawRatio = liquidationWithdrawRatio.safeCastTo88();
    }
  }

  function handleNewLiquidation(
    uint256 newLienExpectedValue,
    uint256 finalAuctionDelta
  ) public {
    require(msg.sender == VAULT());
    WPStorage storage s = _loadSlot();

    unchecked {
      s.expected += newLienExpectedValue.safeCastTo88();
      uint40 auctionEnd = (block.timestamp + finalAuctionDelta).safeCastTo40();
      if (auctionEnd > s.finalAuctionEnd) s.finalAuctionEnd = auctionEnd;
    }
  }
}
