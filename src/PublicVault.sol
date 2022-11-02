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
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {IERC165} from "core/interfaces/IERC165.sol";
import {ERC4626Cloned} from "gpl/ERC4626-Cloned.sol";
import {ITokenBase} from "gpl/interfaces/ITokenBase.sol";
import {ERC4626Base} from "gpl/ERC4626Base.sol";

import {
  ClonesWithImmutableArgs
} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {IVault} from "gpl/interfaces/IVault.sol";

import {LienToken} from "./LienToken.sol";
import {LiquidationAccountant} from "./LiquidationAccountant.sol";
import {VaultImplementation} from "./VaultImplementation.sol";
import {WithdrawProxy} from "./WithdrawProxy.sol";

import {Math} from "./utils/Math.sol";
import {IPublicVault} from "./interfaces/IPublicVault.sol";
import {Vault} from "./Vault.sol";
import {AstariaVaultBase} from "gpl/AstariaVaultBase.sol";

/*
 * @title PublicVault
 * @author androolloyd
 * @notice
 */
contract PublicVault is Vault, IPublicVault, ERC4626Cloned {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for ERC20;
  using SafeCastLib for uint256;

  bytes32 constant PUBLIC_VAULT_SLOT =
    keccak256("xyz.astaria.core.PublicVault.storage.location");

  function underlying()
    public
    pure
    virtual
    override(ERC4626Base, AstariaVaultBase)
    returns (address)
  {
    return super.underlying();
  }

  /**
   * @notice Signal a withdrawal of funds (redeeming for underlying asset) in the next epoch.
   * @param shares The number of VaultToken shares to redeem.
   * @param receiver The receiver of the WithdrawTokens (and eventual underlying asset)
   * @param owner The owner of the VaultTokens.
   * @return assets The amount of the underlying asset redeemed.
   */
  function redeem(
    uint256 shares,
    address receiver,
    address owner
  ) public virtual override returns (uint256 assets) {
    VaultData storage s = _loadStorageSlot();
    assets = redeemFutureEpoch(shares, receiver, owner, s.currentEpoch);
  }

  function withdraw(
    uint256 assets,
    address receiver,
    address owner
  ) public virtual override returns (uint256 shares) {
    shares = previewWithdraw(assets);
    VaultData storage s = _loadStorageSlot();

    redeemFutureEpoch(shares, receiver, owner, s.currentEpoch);
  }

  function redeemFutureEpoch(
    uint256 shares,
    address receiver,
    address owner,
    uint64 epoch
  ) public virtual returns (uint256 assets) {
    // check to ensure that the requested epoch is not the current epoch or in the past
    require(msg.sender == owner);
    VaultData storage s = _loadStorageSlot();

    if (epoch < s.currentEpoch) {
      revert InvalidState(InvalidStates.EPOCH_TOO_LOW);
    }

    // check for rounding error since we round down in previewRedeem.

    ERC20(address(this)).safeTransferFrom(owner, address(this), shares);

    // Deploy WithdrawProxy if no WithdrawProxy exists for the specified epoch
    _deployWithdrawProxyIfNotDeployed(s, epoch);

    emit Withdraw(msg.sender, receiver, owner, assets, shares);

    // WithdrawProxy shares are minted 1:1 with PublicVault shares
    WithdrawProxy(s.epochData[epoch].withdrawProxy).mint(receiver, shares); // was withdrawProxies[withdrawEpoch]
  }

  function getWithdrawProxy(uint64 epoch) public view returns (address) {
    VaultData storage s = _loadStorageSlot();

    return s.epochData[epoch].withdrawProxy;
  }

  function getCurrentEpoch() public view returns (uint64) {
    VaultData storage s = _loadStorageSlot();

    return s.currentEpoch;
  }

  function getSlope() public view returns (uint256) {
    VaultData storage s = _loadStorageSlot();

    return uint256(s.slope);
  }

  function getWithdrawReserve() public view returns (uint256) {
    VaultData storage s = _loadStorageSlot();

    return s.withdrawReserve;
  }

  function getLiquidationWithdrawRatio() public view returns (uint256) {
    VaultData storage s = _loadStorageSlot();

    return s.liquidationWithdrawRatio;
  }

  function getYIntercept() public view returns (uint256) {
    VaultData storage s = _loadStorageSlot();

    return s.yIntercept;
  }

  function getLiquidationAccountant(uint64 epoch)
    public
    view
    returns (address)
  {
    VaultData storage s = _loadStorageSlot();
    return s.epochData[epoch].liquidationAccountant;
  }

  function _deployWithdrawProxyIfNotDeployed(VaultData storage s, uint64 epoch)
    internal
  {
    if (s.epochData[epoch].withdrawProxy == address(0)) {
      s.epochData[epoch].withdrawProxy = ClonesWithImmutableArgs.clone(
        IAstariaRouter(ROUTER()).BEACON_PROXY_IMPLEMENTATION(),
        abi.encodePacked(
          address(ROUTER()), // router is the beacon
          uint8(IAstariaRouter.ImplementationType.WithdrawProxy),
          address(this), //owner
          underlying() //token
        )
      );
    }
  }

  /**
   * @notice Deposit funds into the PublicVault.
   * @param amount The amount of funds to deposit.
   * @param receiver The receiver of the resulting VaultToken shares.
   */
  function deposit(uint256 amount, address receiver)
    public
    override(IVault, Vault, ERC4626Cloned)
    whenNotPaused
    returns (uint256)
  {
    VIData storage s = _loadVISlot();
    if (s.allowListEnabled) {
      require(s.allowList[receiver]);
    }

    uint256 assets = totalAssets();
    if (s.depositCap != 0 && assets >= s.depositCap) {
      revert InvalidState(InvalidStates.DEPOSIT_CAP_EXCEEDED);
    }

    return super.deposit(amount, receiver);
  }

  /**
   * @notice Retrieve the domain separator.
   * @return The domain separator.
   */
  function computeDomainSeparator() internal view override returns (bytes32) {
    return super.domainSeparator();
  }

  function processEpoch() public {
    // check to make sure epoch is over
    if (timeToEpochEnd() > 0) {
      revert InvalidState(InvalidStates.EPOCH_NOT_OVER);
    }
    VaultData storage s = _loadStorageSlot();

    if (s.withdrawReserve > 0) {
      revert InvalidState(InvalidStates.WITHDRAW_RESERVE_NOT_ZERO);
    }

    address currentLA = s.epochData[s.currentEpoch].liquidationAccountant;

    if (currentLA != address(0)) {
      if (
        LiquidationAccountant(currentLA).getFinalAuctionEnd() > block.timestamp
      ) {
        revert InvalidState(
          InvalidStates.LIQUIDATION_ACCOUNTANT_FINAL_AUCTION_OPEN
        );
      }
    }

    // split funds from previous LiquidationAccountant between PublicVault and WithdrawProxy if hasn't been already
    if (s.currentEpoch != 0) {
      address prevLa = s.epochData[s.currentEpoch - 1].liquidationAccountant;
      if (
        prevLa != address(0) && !LiquidationAccountant(prevLa).getHasClaimed()
      ) {
        LiquidationAccountant(prevLa).claim();
      }
    }

    if (s.epochData[s.currentEpoch].liensOpenForEpoch > 0) {
      revert InvalidState(InvalidStates.LIENS_OPEN_FOR_EPOCH_NOT_ZERO);
    }

    // reset liquidationWithdrawRatio to prepare for re calcualtion
    s.liquidationWithdrawRatio = 0;

    // check if there are LPs withdrawing this epoch
    address withdrawProxy = getWithdrawProxy(s.currentEpoch);
    if ((withdrawProxy != address(0))) {
      uint256 proxySupply = WithdrawProxy(withdrawProxy).totalSupply();

      s.liquidationWithdrawRatio = proxySupply.mulDivDown(1e18, totalSupply());

      if (currentLA != address(0)) {
        LiquidationAccountant(currentLA).setWithdrawRatio(
          s.liquidationWithdrawRatio
        );
      }

      uint256 expected = 0;
      if (currentLA != address(0)) {
        expected = LiquidationAccountant(currentLA).getExpected();
      }

      if (totalAssets() > expected) {
        s.withdrawReserve = (totalAssets() - expected).mulWadDown(
          s.liquidationWithdrawRatio
        );
      } else {
        s.withdrawReserve = 0;
      }
      _decreaseYIntercept(
        s,
        totalAssets().mulDivDown(s.liquidationWithdrawRatio, 1e18)
      );
      // burn the tokens of the LPs withdrawing
      _burn(address(this), proxySupply);
    }

    // increment epoch
    s.currentEpoch++;
  }

  /**
   * @notice Deploys a LiquidationAccountant for the WithdrawProxy for the upcoming epoch boundary.
   * @return accountant The address of the deployed LiquidationAccountant.
   */
  function _deployLiquidationAccountant(VaultData storage s, uint64 epoch)
    internal
    returns (address accountant)
  {
    if (s.epochData[epoch].liquidationAccountant != address(0)) {
      revert InvalidState(
        InvalidStates.LIQUIDATION_ACCOUNTANT_ALREADY_DEPLOYED_FOR_EPOCH
      );
    }

    _deployWithdrawProxyIfNotDeployed(s, epoch);

    accountant = ClonesWithImmutableArgs.clone(
      IAstariaRouter(ROUTER()).BEACON_PROXY_IMPLEMENTATION(),
      abi.encodePacked(
        address(ROUTER()),
        uint8(IAstariaRouter.ImplementationType.LiquidationAccountant),
        underlying(),
        address(this),
        address(LIEN_TOKEN()),
        address(getWithdrawProxy(epoch)),
        epoch + 1
      )
    );
    s.epochData[epoch].liquidationAccountant = accountant;
  }

  function supportsInterface(bytes4 interfaceId)
    public
    pure
    override(IERC165)
    returns (bool)
  {
    return
      interfaceId == type(IPublicVault).interfaceId ||
      interfaceId == type(IVault).interfaceId ||
      interfaceId == type(ERC4626Cloned).interfaceId ||
      interfaceId == type(ERC4626).interfaceId ||
      interfaceId == type(ERC20).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  function transferWithdrawReserve() public {
    VaultData storage s = _loadStorageSlot();

    if (s.currentEpoch > uint64(0)) {
      // check the available balance to be withdrawn
      uint256 withdrawBalance = ERC20(underlying()).balanceOf(address(this));

      // prevent transfer of more assets then are available
      if (s.withdrawReserve <= withdrawBalance) {
        withdrawBalance = s.withdrawReserve;
        s.withdrawReserve = 0;
      } else {
        s.withdrawReserve -= withdrawBalance;
      }
      address currentWithdrawProxy = s
        .epochData[s.currentEpoch - 1]
        .withdrawProxy;
      // prevents transfer to a non-existent WithdrawProxy
      // withdrawProxies are indexed by the epoch where they're deployed
      if (currentWithdrawProxy != address(0)) {
        ERC20(underlying()).safeTransfer(currentWithdrawProxy, withdrawBalance);
        emit WithdrawReserveTransferred(withdrawBalance);
      }
    }

    address accountant = s.epochData[s.currentEpoch].liquidationAccountant;
    if (
      s.withdrawReserve > 0 && timeToEpochEnd() == 0 && accountant != address(0)
    ) {
      s.withdrawReserve -= LiquidationAccountant(accountant).drain(
        s.withdrawReserve,
        s.epochData[s.currentEpoch - 1].withdrawProxy
      );
    }
  }

  function _beforeCommitToLien(
    IAstariaRouter.Commitment calldata params,
    address receiver
  ) internal virtual override(VaultImplementation) {
    VaultData storage s = _loadStorageSlot();

    if (timeToEpochEnd() == uint256(0)) {
      processEpoch();
    } else if (s.withdrawReserve > uint256(0)) {
      transferWithdrawReserve();
    }
  }

  function _loadStorageSlot() internal pure returns (VaultData storage s) {
    bytes32 slot = PUBLIC_VAULT_SLOT;
    assembly {
      s.slot := slot
    }
  }

  /**
   * @dev Hook for updating the slope of the PublicVault after a LienToken is issued.
   * @param lienId The ID of the lien.
   * @param amount The amount of debt
   */
  function _afterCommitToLien(
    uint40 lienEnd,
    uint256 lienId,
    uint256 amount,
    uint256 lienSlope
  ) internal virtual override {
    VaultData storage s = _loadStorageSlot();

    // increment slope for the new lien
    _accrue(s);
    unchecked {
      s.slope += lienSlope.safeCastTo48();
    }

    uint256 epoch = Math.ceilDiv(lienEnd - START(), EPOCH_LENGTH()) - 1;

    _increaseOpenLiens(s, getLienEpoch(lienEnd));
    if (s.last == 0) {
      s.last = block.timestamp.safeCastTo40();
    }
    emit LienOpen(lienId, epoch);
  }

  function accrue() public returns (uint256) {
    return _accrue(_loadStorageSlot());
  }

  function _accrue(VaultData storage s) internal returns (uint256) {
    unchecked {
      s.yIntercept += uint256(block.timestamp - s.last)
        .mulDivDown(uint256(s.slope), 1)
        .safeCastTo88();
      emit YInterceptChanged(s.yIntercept);
      s.last = block.timestamp.safeCastTo40();
    }
    return s.yIntercept;
  }

  /**
   * @notice Computes the implied value of this PublicVault. This includes interest payments that have not yet been made.
   * @return The implied value for this PublicVault.
   */
  function totalAssets() public view virtual override returns (uint256) {
    VaultData storage s = _loadStorageSlot();
    uint256 delta_t = block.timestamp - s.last;
    return uint256(s.slope).mulDivDown(delta_t, 1) + uint256(s.yIntercept);
  }

  function totalSupply() public view virtual override returns (uint256) {
    return
      _loadERC20Slot()._totalSupply +
      _loadStorageSlot().strategistUnclaimedShares;
  }

  function claim() external onlyOwner {
    VaultData storage s = _loadStorageSlot();
    uint256 unclaimed = s.strategistUnclaimedShares;
    s.strategistUnclaimedShares = 0;
    _mint(owner(), unclaimed);
  }

  function beforePayment(BeforePaymentParams calldata params) public {
    require(msg.sender == address(LIEN_TOKEN()));
    VaultData storage s = _loadStorageSlot();
    _accrue(s);
    unchecked {
      s.slope -= params.lienSlope.safeCastTo48();
    }
    _handleStrategistInterestReward(s, params.interestOwed, params.amount);
  }

  function decreaseEpochLienCount(uint64 epoch) public {
    require(
      msg.sender == address(ROUTER()) || msg.sender == address(LIEN_TOKEN())
    );
    VaultData storage s = _loadStorageSlot();
    _decreaseEpochLienCount(s, epoch);
  }

  function _decreaseEpochLienCount(VaultData storage s, uint64 epoch) internal {
    unchecked {
      s.epochData[epoch].liensOpenForEpoch--;
    }
  }

  function getLienEpoch(uint64 end) public pure returns (uint64) {
    return
      uint256(Math.ceilDiv(end - uint64(START()), EPOCH_LENGTH()) - 1)
        .safeCastTo64();
  }

  function getEpochEnd(uint256 epoch) public pure returns (uint64) {
    return uint256(START() + (epoch + 1) * EPOCH_LENGTH()).safeCastTo64();
  }

  function _increaseOpenLiens(VaultData storage s, uint64 epoch) internal {
    unchecked {
      s.epochData[epoch].liensOpenForEpoch++;
    }
  }

  function afterPayment(uint256 computedSlope) public {
    VaultData storage s = _loadStorageSlot();
    require(msg.sender == address(LIEN_TOKEN()));
    unchecked {
      s.slope += computedSlope.safeCastTo48();
    }
  }

  /**
   * @notice After-deposit hook to update the yIntercept of the PublicVault to reflect a capital contribution.
   * @param assets The amount of assets deposited to the PublicVault.
   * @param shares The resulting amount of VaultToken shares that were issued.
   */
  function afterDeposit(uint256 assets, uint256 shares)
    internal
    virtual
    override
  {
    VaultData storage s = _loadStorageSlot();

    s.yIntercept += assets.safeCastTo88();

    emit YInterceptChanged(s.yIntercept);
  }

  /**
   * @dev Handles the dilutive fees (on lien repayments) for strategists in VaultTokens.
   * @param interestOwing the owingInterest for the lien
   * @param amount The amount that was paid.
   */
  function _handleStrategistInterestReward(
    VaultData storage s,
    uint256 interestOwing,
    uint256 amount
  ) internal virtual {
    if (VAULT_FEE() != uint256(0)) {
      uint256 x = (amount > interestOwing) ? interestOwing : amount;
      uint256 fee = x.mulDivDown(VAULT_FEE(), 1000); //TODO: make const VAULT_FEE is a basis point
      s.strategistUnclaimedShares += convertToShares(fee);
    }
  }

  function LIEN_TOKEN() public view returns (ILienToken) {
    return ROUTER().LIEN_TOKEN();
  }

  function updateVaultAfterLiquidation(
    uint256 auctionWindow,
    AfterLiquidationParams calldata params
  ) public returns (address accountantIfAny) {
    require(msg.sender == address(LIEN_TOKEN())); // can only be called by router
    VaultData storage s = _loadStorageSlot();

    accountantIfAny = address(0);
    s.yIntercept += uint256(s.slope)
      .mulDivDown(block.timestamp - s.last, 1)
      .safeCastTo88();
    s.slope -= params.lienSlope.safeCastTo48();
    s.last = block.timestamp.safeCastTo40();

    if (s.currentEpoch != 0) {
      transferWithdrawReserve();
    }
    uint64 lienEpoch = getLienEpoch(params.lienEnd);
    _decreaseEpochLienCount(s, lienEpoch);

    if (timeToEpochEnd() <= auctionWindow) {
      accountantIfAny = s.epochData[lienEpoch].liquidationAccountant;

      // only deploy a LiquidationAccountant for the next set of withdrawing LPs if the previous set of LPs have been repaid
      if (accountantIfAny == address(0)) {
        accountantIfAny = _deployLiquidationAccountant(s, lienEpoch);
      }

      LiquidationAccountant(accountantIfAny).handleNewLiquidation(
        params.newAmount,
        auctionWindow + 1 days
      );
    }
  }

  function _decreaseYIntercept(VaultData storage s, uint256 amount) internal {
    s.yIntercept -= amount.safeCastTo88();
    emit YInterceptChanged(s.yIntercept);
  }

  function decreaseYIntercept(uint256 amount) public {
    VaultData storage s = _loadStorageSlot();
    uint256 currentEpoch = s.currentEpoch;
    require(
      msg.sender == address(LIEN_TOKEN()) ||
        (currentEpoch != 0 &&
          msg.sender == s.epochData[currentEpoch - 1].liquidationAccountant)
    );
    _decreaseYIntercept(s, amount);
  }

  function timeToEpochEnd() public view returns (uint256) {
    VaultData storage s = _loadStorageSlot();

    uint256 epochEnd = START() + ((s.currentEpoch + 1) * EPOCH_LENGTH());

    if (block.timestamp >= epochEnd) {
      return uint256(0);
    }

    return epochEnd - block.timestamp;
  }
}
