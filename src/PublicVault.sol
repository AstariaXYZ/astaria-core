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
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";

import {IERC165} from "core/interfaces/IERC165.sol";
import {IVault} from "gpl/interfaces/IVault.sol";
import {ERC4626Cloned} from "gpl/ERC4626-Cloned.sol";
import {ITokenBase} from "gpl/interfaces/ITokenBase.sol";
import {ERC4626Base} from "gpl/ERC4626Base.sol";
import {AstariaVaultBase} from "gpl/AstariaVaultBase.sol";

import {
  ClonesWithImmutableArgs
} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";

import {LienToken} from "./LienToken.sol";
import {LiquidationAccountant} from "./LiquidationAccountant.sol";
import {VaultImplementation} from "./VaultImplementation.sol";
import {WithdrawProxy} from "./WithdrawProxy.sol";

import {Math} from "./utils/Math.sol";
import {Pausable} from "./utils/Pausable.sol";

interface IPublicVault is IERC165 {
  function beforePayment(uint256 escrowId, uint256 amount) external;

  function decreaseEpochLienCount(uint64 epoch) external;

  function getLienEpoch(uint64 end) external view returns (uint64);

  function afterPayment(uint256 lienId) external;
}

/**
 * @title Vault
 * @author androolloyd
 */
contract Vault is AstariaVaultBase, VaultImplementation, IVault {
  using SafeTransferLib for ERC20;

  function name() public view override returns (string memory) {
    return string(abi.encodePacked("AST-Vault-", ERC20(underlying()).symbol()));
  }

  function symbol() public view override returns (string memory) {
    return
      string(
        abi.encodePacked("AST-V", owner(), "-", ERC20(underlying()).symbol())
      );
  }

  function _handleStrategistInterestReward(uint256 lienId, uint256 shares)
    internal
    virtual
    override
  {}

  function deposit(uint256 amount, address)
    public
    virtual
    override
    returns (uint256)
  {
    require(msg.sender == owner(), "only the appraiser can fund this vault");
    ERC20(underlying()).safeTransferFrom(
      address(msg.sender),
      address(this),
      amount
    );
    return amount;
  }

  function withdraw(uint256 amount) external {
    require(msg.sender == owner(), "only the appraiser can exit this vault");
    ERC20(underlying()).safeTransferFrom(
      address(this),
      address(msg.sender),
      amount
    );
  }
}

/*
 * @title PublicVault
 * @author androolloyd
 * @notice
 */
contract PublicVault is Vault, IPublicVault, ERC4626Cloned {
  using FixedPointMathLib for uint256;
  using SafeTransferLib for ERC20;
  using SafeCastLib for uint256;
  // epoch seconds when yIntercept was calculated last
  uint256 public last;
  // sum of all LienToken amounts
  uint256 public yIntercept;
  // sum of all slopes of each LienToken
  uint256 public slope;

  // block.timestamp of first epoch
  uint256 public withdrawReserve = 0;
  uint256 liquidationWithdrawRatio = 0;
  uint256 strategistUnclaimedShares = 0;
  uint64 public currentEpoch = 0;

  //epoch data
  struct EpochData {
    uint256 liensOpenForEpoch;
    uint256 liquidationsExpectedAtBoundary;
    address withdrawProxy;
    address liquidationAccountant;
  }

  //epoch => epochData
  mapping(uint256 => EpochData) public epochData;

  event YInterceptChanged(uint256 newYintercept);
  event WithdrawReserveTransferred(uint256 amount);

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
    assets = redeemFutureEpoch(shares, receiver, owner, currentEpoch);
  }

  function withdraw(
    uint256 assets,
    address receiver,
    address owner
  ) public virtual override returns (uint256 shares) {
    shares = previewWithdraw(assets);
    redeemFutureEpoch(shares, receiver, owner, currentEpoch);
  }

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
  ) public virtual returns (uint256 assets) {
    // check to ensure that the requested epoch is not the current epoch or in the past
    require(epoch >= currentEpoch, "Exit epoch too low");

    require(msg.sender == owner, "Only the owner can redeem");
    // check for rounding error since we round down in previewRedeem.

    ERC20(address(this)).safeTransferFrom(owner, address(this), shares);

    // Deploy WithdrawProxy if no WithdrawProxy exists for the specified epoch
    _deployWithdrawProxyIfNotDeployed(epoch);

    emit Withdraw(msg.sender, receiver, owner, assets, shares);

    // WithdrawProxy shares are minted 1:1 with PublicVault shares
    WithdrawProxy(epochData[epoch].withdrawProxy).mint(receiver, shares); // was withdrawProxies[withdrawEpoch]
  }

  function getWithdrawProxy(uint64 epoch) public view returns (address) {
    return epochData[epoch].withdrawProxy;
  }

  function getLiquidationAccountant(uint64 epoch)
    public
    view
    returns (address)
  {
    return epochData[epoch].liquidationAccountant;
  }

  function getLiquidationsExpected(uint64 epoch) public view returns (uint256) {
    return epochData[epoch].liquidationsExpectedAtBoundary;
  }

  function _deployWithdrawProxyIfNotDeployed(uint64 epoch) internal {
    if (epochData[epoch].withdrawProxy == address(0)) {
      address proxy = ClonesWithImmutableArgs.clone(
        IAstariaRouter(ROUTER()).WITHDRAW_IMPLEMENTATION(),
        abi.encodePacked(
          address(this), //owner
          underlying() //token
        )
      );
      epochData[epoch].withdrawProxy = proxy;
    }
  }

  /**
   * @notice Deposit funds into the PublicVault.
   * @param amount The amount of funds to deposit.
   * @param receiver The receiver of the resulting VaultToken shares.
   */
  function deposit(uint256 amount, address receiver)
    public
    override(Vault, ERC4626Cloned)
    whenNotPaused
    returns (uint256)
  {
    // yIntercept+=amount;
    return super.deposit(amount, receiver);
  }

  /**
   * @notice Retrieve the domain separator.
   * @return The domain separator.
   */
  function computeDomainSeparator() internal view override returns (bytes32) {
    return super.domainSeparator();
  }

  /**
   * @notice Rotate epoch boundary. This must be called before the next epoch can begin.
   */
  function processEpoch() public {
    // check to make sure epoch is over
    require(getEpochEnd(currentEpoch) < block.timestamp, "Epoch has not ended");
    require(withdrawReserve == 0, "Withdraw reserve not empty");
    address currentLA = getLiquidationAccountant(currentEpoch);
    if (currentLA != address(0)) {
      require(
        LiquidationAccountant(currentLA).getFinalAuctionEnd() < block.timestamp,
        "Final auction not ended"
      );
    }

    // split funds from previous LiquidationAccountant between PublicVault and WithdrawProxy if hasn't been already
    if (currentEpoch != 0) {
      address prevLa = getLiquidationAccountant(currentEpoch - 1);
      if (prevLa != address(0) && !LiquidationAccountant(prevLa).hasClaimed()) {
        LiquidationAccountant(prevLa).claim();
      }
    }

    require(
      epochData[currentEpoch].liensOpenForEpoch == uint64(0),
      "loans are still open for this epoch"
    );

    // reset liquidationWithdrawRatio to prepare for re calcualtion
    liquidationWithdrawRatio = 0;

    // check if there are LPs withdrawing this epoch
    address withdrawProxy = getWithdrawProxy(currentEpoch);
    if ((withdrawProxy != address(0))) {
      uint256 proxySupply = WithdrawProxy(withdrawProxy).totalSupply();

      liquidationWithdrawRatio = proxySupply.mulDivDown(1e18, totalSupply());

      if (currentLA != address(0)) {
        LiquidationAccountant(currentLA).setWithdrawRatio(
          liquidationWithdrawRatio
        );
      }
      uint256 expected = getLiquidationsExpected(currentEpoch);
      withdrawReserve = (totalAssets() - expected).mulDivDown(
        liquidationWithdrawRatio,
        1e18
      );

      _decreaseYIntercept(
        totalAssets().mulDivDown(liquidationWithdrawRatio, 1e18)
      );
      // burn the tokens of the LPs withdrawing
      _burn(address(this), proxySupply);
    }

    // increment epoch
    currentEpoch++;
  }

  /**
   * @notice Deploys a LiquidationAccountant for the WithdrawProxy for the upcoming epoch boundary.
   * @return accountant The address of the deployed LiquidationAccountant.
   */
  function deployLiquidationAccountant() public returns (address accountant) {
    require(
      getLiquidationAccountant(currentEpoch) == address(0),
      "cannot deploy two liquidation accountants for the same epoch"
    );

    _deployWithdrawProxyIfNotDeployed(currentEpoch);

    accountant = ClonesWithImmutableArgs.clone(
      IAstariaRouter(ROUTER()).LIQUIDATION_IMPLEMENTATION(),
      abi.encodePacked(
        underlying(),
        ROUTER(),
        address(this),
        address(LIEN_TOKEN()),
        address(getWithdrawProxy(currentEpoch))
      )
    );
    epochData[currentEpoch].liquidationAccountant = accountant;
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

  /**
   * @notice Transfers funds from the PublicVault to the WithdrawProxy.
   */

  function transferWithdrawReserve() public {
    // check the available balance to be withdrawn
    uint256 withdrawBalance = ERC20(underlying()).balanceOf(address(this));

    // prevent transfer of more assets then are available
    if (withdrawReserve <= withdrawBalance) {
      withdrawBalance = withdrawReserve;
      withdrawReserve = 0;
    } else {
      withdrawReserve -= withdrawBalance;
    }
    //todo: check on current epoch is 0?
    address currentWithdrawProxy = getWithdrawProxy(currentEpoch - 1);
    // prevents transfer to a non-existent WithdrawProxy
    // withdrawProxies are indexed by the epoch where they're deployed
    if (currentWithdrawProxy != address(0)) {
      ERC20(underlying()).safeTransfer(currentWithdrawProxy, withdrawBalance);
      emit WithdrawReserveTransferred(withdrawBalance);
    }
  }

  function _beforeCommitToLien(
    IAstariaRouter.Commitment calldata params,
    address receiver
  ) internal virtual override(VaultImplementation) {
    if (timeToEpochEnd() == uint256(0)) {
      processEpoch();
    }
  }

  /**
   * @dev Hook for updating the slope of the PublicVault after a LienToken is issued.
   * @param lienId The ID of the lien.
   * @param amount The amount of debt
   */
  function _afterCommitToLien(uint256 lienId, uint256 amount)
    internal
    virtual
    override
  {
    uint256 delta_t = block.timestamp - last;

    yIntercept += delta_t.mulDivDown(slope, 1);

    // increment slope for the new lien
    unchecked {
      slope += LIEN_TOKEN().calculateSlope(lienId);
    }

    ILienToken.Lien memory lien = LIEN_TOKEN().getLien(lienId);

    uint256 epoch = Math.ceilDiv(lien.end - START(), EPOCH_LENGTH()) - 1;

    _increaseOpenLiens(getLienEpoch(lien.end));
    if (last == 0) {
      last = block.timestamp;
    }
    emit LienOpen(lienId, epoch);
  }

  event LienOpen(uint256 lienId, uint256 epoch);

  /**
   * @notice Retrieves the address of the LienToken contract for this PublicVault.
   * @return The LienToken address.
   */

  function LIEN_TOKEN() public view returns (ILienToken) {
    return IAstariaRouter(ROUTER()).LIEN_TOKEN();
  }

  /**
   * @notice Computes the implied value of this PublicVault. This includes interest payments that have not yet been made.
   * @return The implied value for this PublicVault.
   */

  function totalAssets() public view virtual override returns (uint256) {
    if (last == 0 || yIntercept == 0) {
      return ERC20(underlying()).balanceOf(address(this));
    }
    // uint256 delta_t = (last == 0) ? last : block.timestamp - last;
    uint256 delta_t = block.timestamp - last;

    return slope.mulDivDown(delta_t, 1) + yIntercept;
  }

  function totalSupply() public view virtual override returns (uint256) {
    return _totalSupply + strategistUnclaimedShares;
  }

  /**
   * @notice Mints earned fees by the strategist to the strategist address.
   */
  function claim() external onlyOwner {
    uint256 unclaimed = strategistUnclaimedShares;
    strategistUnclaimedShares = 0;
    _mint(owner(), unclaimed);
  }

  /**
   * @notice Hook to update the slope and yIntercept of the PublicVault on payment.
   * The rate for the LienToken is subtracted from the total slope of the PublicVault, and recalculated in afterPayment().
   * @param lienId The ID of the lien.
   * @param amount The amount paid off to deduct from the yIntercept of the PublicVault.
   */
  function beforePayment(uint256 lienId, uint256 amount) public {
    require(msg.sender == address(LIEN_TOKEN()));
    _handleStrategistInterestReward(lienId, amount);
    uint256 lienSlope = LIEN_TOKEN().calculateSlope(lienId);
    if (lienSlope > slope) {
      slope = 0;
    } else {
      slope -= lienSlope;
    }
    last = block.timestamp;
  }

  /** @notice
   * hook to modify the liens open for then given epoch
   * @param epoch epoch to decrease liens of
   */
  function decreaseEpochLienCount(uint64 epoch) external {
    require(
      msg.sender == address(ROUTER()) || msg.sender == address(LIEN_TOKEN()),
      "only router or lien token"
    );
    unchecked {
      epochData[epoch].liensOpenForEpoch--;
    }
  }

  /** @notice
   * hook to increase the amount of debt currently liquidated to discount in processEpoch
   * @param amount the amount of debt liquidated
   */
  function increaseLiquidationsExpectedAtBoundary(uint256 amount) external {
    require(msg.sender == ROUTER(), "only router");
    unchecked {
      epochData[currentEpoch].liquidationsExpectedAtBoundary += amount
        .safeCastTo64();
    }
  }

  /** @notice
   * helper to return the LienEpoch for a given end date
   * @param end time to compute the end for
   */
  function getLienEpoch(uint64 end) public pure returns (uint64) {
    return
      uint256(Math.ceilDiv(end - uint64(START()), EPOCH_LENGTH()) - 1)
        .safeCastTo64();
  }

  function getEpochEnd(uint256 epoch) public pure returns (uint64) {
    return uint256(START() + (epoch + 1) * EPOCH_LENGTH()).safeCastTo64();
  }

  function _increaseOpenLiens() internal {
    epochData[currentEpoch].liensOpenForEpoch++;
  }

  function _increaseOpenLiens(uint64 epoch) internal {
    epochData[epoch].liensOpenForEpoch++;
  }

  /**
   * @notice Hook to recalculate the slope of a lien after a payment has been made.
   * @param lienId The ID of the lien.
   */
  function afterPayment(uint256 lienId) public {
    require(msg.sender == address(LIEN_TOKEN()));
    slope += LIEN_TOKEN().calculateSlope(lienId);
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
    yIntercept += assets;
    emit YInterceptChanged(yIntercept);
  }

  /**
   * @dev Handles the dilutive fees (on lien repayments) for strategists in VaultTokens.
   * @param lienId The ID of the lien that received a payment.
   * @param amount The amount that was paid.
   */
  function _handleStrategistInterestReward(uint256 lienId, uint256 amount)
    internal
    virtual
    override
  {
    if (VAULT_FEE() != uint256(0)) {
      uint256 interestOwing = LIEN_TOKEN().getInterest(lienId);
      uint256 x = (amount > interestOwing) ? interestOwing : amount;
      uint256 fee = x.mulDivDown(VAULT_FEE(), 1000); //VAULT_FEE is a basis point
      strategistUnclaimedShares += convertToShares(fee);
    }
  }

  function updateVaultAfterLiquidation(
    uint256 debtAccruedSinceLastPayment,
    uint256 accrued,
    uint256 lienSlope
  ) public {
    require(msg.sender == ROUTER(), "can only be called by the router");
    slope -= lienSlope;
    last = block.timestamp;
    yIntercept += accrued;
    yIntercept -= debtAccruedSinceLastPayment;
  }

  function getYIntercept() public view returns (uint256) {
    return yIntercept;
  }

  function _decreaseYIntercept(uint256 amount) internal {
    yIntercept -= amount;
    emit YInterceptChanged(yIntercept);
  }

  function decreaseYIntercept(uint256 amount) public {
    require(
      msg.sender == AUCTION_HOUSE() ||
        (currentEpoch != 0 &&
          msg.sender == epochData[currentEpoch - 1].liquidationAccountant),
      "msg sender only from auction house or liquidation accountant"
    );
    _decreaseYIntercept(amount);
  }

  function getCurrentEpoch() public view returns (uint64) {
    return currentEpoch;
  }

  /**
   * @notice Computes the time until the current epoch is over.
   * @return Seconds until the current epoch ends.
   */
  function timeToEpochEnd() public view returns (uint256) {
    uint256 epochEnd = START() + ((currentEpoch + 1) * EPOCH_LENGTH());

    if (block.timestamp >= epochEnd) {
      return uint256(0);
    }

    return epochEnd - block.timestamp;
  }
}
