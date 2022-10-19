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

import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {IERC721} from "gpl/interfaces/IERC721.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {
  ClonesWithImmutableArgs
} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

import {CollateralLookup} from "./libraries/CollateralLookup.sol";

import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "./interfaces/ICollateralToken.sol";
import {ILienBase, ILienToken} from "./interfaces/ILienToken.sol";
import {IStrategyValidator} from "./interfaces/IStrategyValidator.sol";

import {IPublicVault, PublicVault} from "./PublicVault.sol";
import {IVault, VaultImplementation} from "./VaultImplementation.sol";
import {LiquidationAccountant} from "./LiquidationAccountant.sol";

import {MerkleProof} from "./utils/MerkleProof.sol";
import {Pausable} from "./utils/Pausable.sol";

/**
 * @title AstariaRouter
 * @notice This contract manages the deployment of Vaults and universal Astaria actions.
 */
contract AstariaRouter is Auth, Pausable, IAstariaRouter {
  using SafeTransferLib for ERC20;
  using SafeCastLib for uint256;
  using CollateralLookup for address;
  using FixedPointMathLib for uint256;

  ERC20 public immutable WETH;
  ICollateralToken public immutable COLLATERAL_TOKEN;
  ILienToken public immutable LIEN_TOKEN;
  ITransferProxy public immutable TRANSFER_PROXY;

  address public LIQUIDATION_IMPLEMENTATION;
  address public SOLO_IMPLEMENTATION;
  address public VAULT_IMPLEMENTATION;
  address public WITHDRAW_IMPLEMENTATION;
  address public feeTo;
  uint256 public liquidationFeePercent;
  uint256 public maxInterestRate;
  uint256 public maxEpochLength;
  uint256 public minEpochLength;
  uint256 public minInterestBPS; // was uint64
  uint256 public protocolFeeNumerator;
  uint256 public protocolFeeDenominator;
  uint256 public strategistFeeNumerator;
  uint256 public strategistFeeDenominator;
  uint256 public buyoutFeeNumerator;
  uint256 public buyoutFeeDenominator;
  uint32 public minDurationIncrease;
  uint32 public buyoutInterestWindow;

  //A strategist can have many deployed vaults
  mapping(address => address) public vaults;
  mapping(address => uint256) public strategistNonce;
  mapping(uint16 => address) public strategyValidators;

  /**
   * @dev Setup transfer authority and set up addresses for deployed CollateralToken, LienToken, TransferProxy contracts, as well as PublicVault and SoloVault implementations to clone.
   * @param _AUTHORITY The authority manager.
   * @param _WETH The WETH address to use for transfers.
   * @param _COLLATERAL_TOKEN The address of the deployed CollateralToken contract.
   * @param _LIEN_TOKEN The address of the deployed LienToken contract.
   * @param _TRANSFER_PROXY The address of the deployed TransferProxy contract.
   * @param _VAULT_IMPL The address of a base implementation of VaultImplementation for cloning.
   * @param _SOLO_IMPL The address of a base implementation of a PrivateVault for cloning.
   */
  constructor(
    Authority _AUTHORITY,
    address _WETH,
    ICollateralToken _COLLATERAL_TOKEN,
    ILienToken _LIEN_TOKEN,
    ITransferProxy _TRANSFER_PROXY,
    address _VAULT_IMPL,
    address _SOLO_IMPL
  ) Auth(address(msg.sender), _AUTHORITY) {
    WETH = ERC20(_WETH);
    COLLATERAL_TOKEN = _COLLATERAL_TOKEN;
    LIEN_TOKEN = _LIEN_TOKEN;
    TRANSFER_PROXY = _TRANSFER_PROXY;
    VAULT_IMPLEMENTATION = _VAULT_IMPL;
    SOLO_IMPLEMENTATION = _SOLO_IMPL;
    liquidationFeePercent = 13;
    minInterestBPS = uint256(0.0005 ether) / uint256(365 days); //5 bips / second
    minEpochLength = 7 days;
    maxEpochLength = 45 days;
    maxInterestRate = 63419583966; // 200% apy / second
    strategistFeeNumerator = 200;
    strategistFeeDenominator = 1000;
    minDurationIncrease = 14 days;
    buyoutInterestWindow = 60 days;
  }

  /**
   * @dev Enables _pause, freezing functions with the whenNotPaused modifier.
   */
  function __emergencyPause() external requiresAuth whenNotPaused {
    _pause();
  }

  /**
   * @dev Disables _pause, un-freezing functions with the whenNotPaused modifier.
   */
  function __emergencyUnpause() external requiresAuth whenPaused {
    _unpause();
  }

  function incrementNonce() external {
    strategistNonce[msg.sender]++;
  }

  /**
   * @notice Sets universal protocol parameters or changes the addresses for deployed contracts.
   * @param what The identifier for what is being filed.
   * @param data The encoded address data to be decoded and filed.
   */
  function fileBatch(bytes32[] memory what, bytes[] calldata data)
    external
    requiresAuth
  {
    require(what.length == data.length, "data length mismatch");
    for (uint256 i = 0; i < what.length; i++) {
      file(what[i], data[i]);
    }
  }

  function file(bytes32 what, bytes calldata data) public requiresAuth {
    if (what == "LIQUIDATION_FEE_PERCENT") {
      uint256 value = abi.decode(data, (uint256));
      liquidationFeePercent = value;
    } else if (what == "MIN_INTEREST_BPS") {
      uint256 value = abi.decode(data, (uint256));
      minInterestBPS = uint256(value);
    } else if (what == "APPRAISER_NUMERATOR") {
      uint256 value = abi.decode(data, (uint256));
      strategistFeeNumerator = value;
    } else if (what == "APPRAISER_ORIGINATION_FEE_BASE") {
      uint256 value = abi.decode(data, (uint256));
      strategistFeeDenominator = value;
    } else if (what == "MIN_DURATION_INCREASE") {
      uint256 value = abi.decode(data, (uint256));
      minDurationIncrease = value.safeCastTo32();
    } else if (what == "WITHDRAW_IMPLEMENTATION") {
      address addr = abi.decode(data, (address));
      WITHDRAW_IMPLEMENTATION = addr;
    } else if (what == "LIQUIDATION_IMPLEMENTATION") {
      address addr = abi.decode(data, (address));
      LIQUIDATION_IMPLEMENTATION = addr;
    } else if (what == "VAULT_IMPLEMENTATION") {
      address addr = abi.decode(data, (address));
      VAULT_IMPLEMENTATION = addr;
    } else if (what == "SOLO_IMPLEMENTATION") {
      address addr = abi.decode(data, (address));
      SOLO_IMPLEMENTATION = addr;
    } else if (what == "MIN_EPOCH_LENGTH") {
      minEpochLength = abi.decode(data, (uint256));
    } else if (what == "MAX_EPOCH_LENGTH") {
      maxEpochLength = abi.decode(data, (uint256));
    } else if (what == "MAX_INTEREST_RATE") {
      maxInterestRate = abi.decode(data, (uint256));
    } else if (what == "feeTo") {
      address addr = abi.decode(data, (address));
      feeTo = addr;
    } else if (what == "setBuyoutInterestWindow") {
      uint256 value = abi.decode(data, (uint256));
      buyoutInterestWindow = value.safeCastTo32();
    } else if (what == "setStrategyValidator") {
      (uint8 TYPE, address addr) = abi.decode(data, (uint8, address));
      strategyValidators[TYPE] = addr;
    } else {
      revert("unsupported/file");
    }
  }

  // MODIFIERS
  modifier onlyVaults() {
    require(
      vaults[msg.sender] != address(0),
      "this vault has not been initialized"
    );
    _;
  }

  //PUBLIC

  function validateCommitment(IAstariaRouter.Commitment calldata commitment)
    public
    returns (bool valid, IAstariaRouter.LienDetails memory ld)
  {
    require(
      commitment.lienRequest.strategy.deadline >= block.timestamp,
      "deadline passed"
    );

    require(
      strategyValidators[commitment.lienRequest.nlrType] != address(0),
      "invalid strategy type"
    );

    bytes32 leaf;
    (leaf, ld) = IStrategyValidator(
      strategyValidators[commitment.lienRequest.nlrType]
    ).validateAndParse(
        commitment.lienRequest,
        COLLATERAL_TOKEN.ownerOf(
          commitment.tokenContract.computeId(commitment.tokenId)
        ),
        commitment.tokenContract,
        commitment.tokenId
      );

    return (
      MerkleProof.verifyCalldata(
        commitment.lienRequest.merkle.proof,
        commitment.lienRequest.merkle.root,
        leaf
      ),
      ld
    );
  }

  /**
   * @notice Deposits collateral and requests loans for multiple NFTs at once.
   * @param commitments The commitment proofs and requested loan data for each loan.
   * @return totalBorrowed The total amount borrowed by the requested loans.
   */
  function commitToLiens(IAstariaRouter.Commitment[] calldata commitments)
    external
    whenNotPaused
    returns (uint256 totalBorrowed)
  {
    totalBorrowed = 0;
    for (uint256 i = 0; i < commitments.length; ++i) {
      _transferAndDepositAsset(
        commitments[i].tokenContract,
        commitments[i].tokenId
      );
      totalBorrowed += _executeCommitment(commitments[i]);

      uint256 collateralId = commitments[i].tokenContract.computeId(
        commitments[i].tokenId
      );
      _returnCollateral(collateralId, address(msg.sender));
    }
    WETH.safeApprove(address(TRANSFER_PROXY), totalBorrowed);
    TRANSFER_PROXY.tokenTransferFrom(
      address(WETH),
      address(this),
      address(msg.sender),
      totalBorrowed
    );
  }

  /**
   * @notice Deploys a new PrivateVault.
   * @return The address of the new PrivateVault.
   */
  function newVault(address delegate) external whenNotPaused returns (address) {
    return _newVault(uint256(0), delegate, uint256(0));
  }

  /**
   * @notice Deploys a new PublicVault.
   * @param epochLength The length of each epoch for the new PublicVault.
   */
  function newPublicVault(
    uint256 epochLength,
    address delegate,
    uint256 vaultFee
  ) external whenNotPaused returns (address) {
    return _newVault(epochLength, delegate, vaultFee);
  }

  /**
   * @notice Create a new lien against a CollateralToken.
   * @param terms the decoded lien details from the commitment
   * @param params The valid proof and lien details for the new loan.
   * @return The ID of the created lien.
   */
  function requestLienPosition(
    IAstariaRouter.LienDetails memory terms,
    IAstariaRouter.Commitment calldata params
  ) external whenNotPaused onlyVaults returns (uint256) {
    return
      LIEN_TOKEN.createLien(
        ILienBase.LienActionEncumber({
          tokenContract: params.tokenContract,
          tokenId: params.tokenId,
          terms: terms,
          strategyRoot: params.lienRequest.merkle.root,
          amount: params.lienRequest.amount,
          vault: address(msg.sender)
        })
      );
  }

  /**
   * @notice Lend to a PublicVault.
   * @param vault The address of the PublicVault.
   * @param amount The amount to lend.
   */
  function lendToVault(IVault vault, uint256 amount) external whenNotPaused {
    TRANSFER_PROXY.tokenTransferFrom(
      address(WETH),
      address(msg.sender),
      address(this),
      amount
    );

    require(
      vaults[address(vault)] != address(0),
      "lendToVault: vault doesn't exist"
    );
    WETH.safeApprove(address(vault), amount);
    vault.deposit(amount, address(msg.sender));
  }

  /**
   * @notice Returns whether a specific lien can be liquidated.
   * @param collateralId The ID of the underlying CollateralToken.
   * @param position The specified lien position.
   * @return A boolean value indicating whether the specified lien can be liquidated.
   */
  function canLiquidate(uint256 collateralId, uint256 position)
    public
    view
    returns (bool)
  {
    ILienToken.Lien memory lien = LIEN_TOKEN.getLien(collateralId, position);

    return (lien.start + lien.duration <= block.timestamp && lien.amount > 0);
  }

  /**
   * @notice Liquidate a CollateralToken that has defaulted on one of its liens.
   * @param collateralId The ID of the CollateralToken.
   * @param position The position of the defaulted lien.
   * @return reserve The amount owed on all liens for against the collateral being liquidated, including accrued interest.
   */
  function liquidate(uint256 collateralId, uint256 position)
    external
    returns (uint256 reserve)
  {
    require(
      canLiquidate(collateralId, position),
      "liquidate: borrow is healthy"
    );

    // if expiration will be past epoch boundary, then create a LiquidationAccountant

    uint256[] memory liens = LIEN_TOKEN.getLiens(collateralId);
    for (uint256 i = 0; i < liens.length; ++i) {
      uint256 currentLien = liens[i];

      ILienToken.Lien memory lien = LIEN_TOKEN.getLien(currentLien);

      address owner = LIEN_TOKEN.ownerOf(currentLien);
      if (
        IPublicVault(owner).supportsInterface(type(IPublicVault).interfaceId)
      ) {
        // subtract slope from PublicVault

        PublicVault(owner).updateVaultAfterLiquidation(
          LIEN_TOKEN.calculateSlope(currentLien)
        );
        if (
          PublicVault(owner).timeToEpochEnd() <=
          COLLATERAL_TOKEN.auctionWindow()
        ) {
          uint64 currentEpoch = PublicVault(owner).getCurrentEpoch();
          address accountant = PublicVault(owner).getLiquidationAccountant(
            currentEpoch
          );
          uint256 lienEpoch = PublicVault(owner).getLienEpoch(
            lien.start + lien.duration
          );
          PublicVault(owner).decreaseEpochLienCount(lienEpoch);

          // only deploy a LiquidationAccountant for the next set of withdrawing LPs if the previous set of LPs have been repaid
          if (PublicVault(owner).withdrawReserve() == 0) {
            if (accountant == address(0)) {
              accountant = PublicVault(owner).deployLiquidationAccountant();
            }
            LIEN_TOKEN.setPayee(currentLien, accountant);
            LiquidationAccountant(accountant).handleNewLiquidation(
              lien.amount,
              COLLATERAL_TOKEN.auctionWindow() + 1 days
            );
            PublicVault(owner).increaseLiquidationsExpectedAtBoundary(
              lien.amount
            );
          }
        }
      }
    }

    reserve = COLLATERAL_TOKEN.auctionVault(
      collateralId,
      address(msg.sender),
      liquidationFeePercent
    );

    emit Liquidation(collateralId, position, reserve);
  }

  /**
   * @notice Retrieves the fee PublicVault strategists earn on loan origination.
   * @return The numerator and denominator used to compute the percentage fee strategists earn by receiving minted vault shares.
   */
  function getStrategistFee(uint256 amountIn) external view returns (uint256) {
    return
      amountIn.mulDivDown(strategistFeeNumerator, strategistFeeDenominator);
  }

  /**
   * @notice Retrieves the fee the protocol earns on loan origination.
   * @return The numerator and denominator used to compute the percentage fee taken by the protocol
   */
  function getProtocolFee(uint256 amountIn) external view returns (uint256) {
    return amountIn.mulDivDown(protocolFeeNumerator, protocolFeeDenominator);
  }

  /**
   * @notice Retrieves the fee the protocol earns on loan origination.
   * @return The numerator and denominator used to compute the percentage fee taken by the protocol
   */

  function getBuyoutFee(uint256 remainingInterestIn)
    external
    view
    returns (uint256)
  {
    return
      remainingInterestIn.mulDivDown(buyoutFeeNumerator, buyoutFeeDenominator);
  }

  /**
   * @notice Retrieves the time window for computing maxbuyout costs
   * @return The numerator and denominator used to compute the percentage fee taken by the protocol
   */
  function getBuyoutInterestWindow() external view returns (uint32) {
    return buyoutInterestWindow;
  }

  /**
   * @notice Returns whether a given address is that of a Vault.
   * @param vault The Vault address.
   * @return A boolean representing whether the address exists as a Vault.
   */
  function isValidVault(address vault) external view returns (bool) {
    return vaults[vault] != address(0);
  }

  /**
   * @notice Determines whether a potential refinance meets the minimum requirements for replacing a lien.
   * @param lien The Lien to be refinanced.
   * @param newLien The new Lien to replace the existing one.
   * @return A boolean representing whether the potential refinance is valid.
   */
  function isValidRefinance(
    ILienToken.Lien memory lien,
    LienDetails memory newLien
  ) external view returns (bool) {
    uint256 minNewRate = uint256(lien.rate) - minInterestBPS;

    return (newLien.rate >= minNewRate &&
      ((block.timestamp + newLien.duration - lien.start - lien.duration) >=
        minDurationIncrease));
  }

  //INTERNAL FUNCS

  /**
   * @dev Deploys a new PublicVault.
   * @param epochLength The length of each epoch for the new PublicVault.
   * @return The address for the new PublicVault.
   */
  function _newVault(
    uint256 epochLength,
    address delegate,
    uint256 vaultFee
  ) internal returns (address) {
    uint8 vaultType;

    address implementation;
    if (epochLength > uint256(0)) {
      require(
        epochLength >= minEpochLength && epochLength <= maxEpochLength,
        "epochLength must be greater than or equal to MIN_EPOCH_LENGTH and less than MAX_EPOCH_LENGTH"
      );
      implementation = VAULT_IMPLEMENTATION;
      vaultType = uint8(VaultType.PUBLIC);
    } else {
      implementation = SOLO_IMPLEMENTATION;
      vaultType = uint8(VaultType.SOLO);
    }

    //immutable data
    address vaultAddr = ClonesWithImmutableArgs.clone(
      implementation,
      abi.encodePacked(
        address(msg.sender),
        address(WETH),
        address(COLLATERAL_TOKEN),
        address(this),
        address(COLLATERAL_TOKEN.AUCTION_HOUSE()),
        block.timestamp,
        epochLength,
        vaultType,
        vaultFee
      )
    );

    //mutable data
    VaultImplementation(vaultAddr).init(
      VaultImplementation.InitParams(delegate)
    );

    vaults[vaultAddr] = msg.sender;

    emit NewVault(msg.sender, vaultAddr);

    return vaultAddr;
  }

  /**
   * @dev validates msg sender is owner
   * @param c The commitment Data
   * @return the amount borrowed
   */
  function _executeCommitment(IAstariaRouter.Commitment memory c)
    internal
    returns (uint256)
  {
    uint256 collateralId = c.tokenContract.computeId(c.tokenId);
    require(
      msg.sender == COLLATERAL_TOKEN.ownerOf(collateralId),
      "invalid sender for collateralId"
    );
    return _borrow(c, address(this));
  }

  function _borrow(IAstariaRouter.Commitment memory c, address receiver)
    internal
    returns (uint256)
  {
    //router must be approved for the collateral to take a loan,
    VaultImplementation(c.lienRequest.strategy.vault).commitToLien(c, receiver);
    if (receiver == address(this)) {
      return c.lienRequest.amount;
    } else {
      return uint256(0);
    }
  }

  function _transferAndDepositAsset(address tokenContract, uint256 tokenId)
    internal
  {
    IERC721(tokenContract).safeTransferFrom(
      address(msg.sender),
      address(COLLATERAL_TOKEN),
      tokenId,
      ""
    );
  }

  function _returnCollateral(uint256 collateralId, address receiver) internal {
    COLLATERAL_TOKEN.transferFrom(address(this), receiver, collateralId);
  }
}
