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
import {IERC721} from "core/interfaces/IERC721.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {
  ClonesWithImmutableArgs
} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

import {CollateralLookup} from "core/libraries/CollateralLookup.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IStrategyValidator} from "core/interfaces/IStrategyValidator.sol";

import {IPublicVault, PublicVault} from "core/PublicVault.sol";
import {IVault, VaultImplementation} from "core/VaultImplementation.sol";
import {LiquidationAccountant} from "core/LiquidationAccountant.sol";

import {MerkleProofLib} from "core/utils/MerkleProofLib.sol";
import {Pausable} from "core/utils/Pausable.sol";

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
  uint256 public liquidationFeeNumerator;
  uint256 public liquidationFeeDenominator;
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
    liquidationFeeNumerator = 130;
    liquidationFeeDenominator = 1000;
    minInterestBPS = (uint256(1e15) * 5) / (365 days);
    minEpochLength = 7 days;
    maxEpochLength = 45 days;
    maxInterestRate = 63419583966; // 200% apy / second
    strategistFeeNumerator = 200;
    strategistFeeDenominator = 1000;
    buyoutFeeNumerator = 200;
    buyoutFeeDenominator = 1000;
    minDurationIncrease = 5 days;
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

  struct File {
    bytes32 what;
    bytes data;
  }

  /**
   * @notice Sets universal protocol parameters or changes the addresses for deployed contracts.
   * @param files structs to file
   */
  function fileBatch(File[] calldata files) external requiresAuth {
    for (uint256 i = 0; i < files.length; i++) {
      file(files[i]);
    }
  }

  function file(File calldata incoming) public requiresAuth {
    bytes32 what = incoming.what;
    bytes memory data = incoming.data;
    if (what == "setLiquidationFee") {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      liquidationFeeNumerator = numerator;
      liquidationFeeDenominator = denominator;
    } else if (what == "setStrategistFee") {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      strategistFeeNumerator = numerator;
      strategistFeeDenominator = denominator;
    } else if (what == "setProtocolFee") {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      protocolFeeNumerator = numerator;
      protocolFeeDenominator = denominator;
    } else if (what == "setBuyoutFee") {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      buyoutFeeNumerator = numerator;
      buyoutFeeDenominator = denominator;
    } else if (what == "MIN_INTEREST_BPS") {
      uint256 value = abi.decode(data, (uint256));
      minInterestBPS = uint256(value);
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
      MerkleProofLib.verify(
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
   * @return lienIds the lienIds for each loan.
   */
  function commitToLiens(IAstariaRouter.Commitment[] calldata commitments)
    external
    whenNotPaused
    returns (uint256[] memory lienIds)
  {
    uint256 totalBorrowed = 0;
    lienIds = new uint256[](commitments.length);
    for (uint256 i = 0; i < commitments.length; ++i) {
      _transferAndDepositAsset(
        commitments[i].tokenContract,
        commitments[i].tokenId
      );
      lienIds[i] = _executeCommitment(commitments[i]);
      totalBorrowed += commitments[i].lienRequest.amount;

      uint256 collateralId = commitments[i].tokenContract.computeId(
        commitments[i].tokenId
      );
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
        ILienToken.LienActionEncumber({
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

    return (lien.end <= block.timestamp && lien.amount > 0);
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

      address owner = LIEN_TOKEN.getPayee(currentLien);
      if (
        IPublicVault(owner).supportsInterface(type(IPublicVault).interfaceId)
      ) {
        // update the public vault state and get the liquidation accountant back if any
        address accountantIfAny = PublicVault(owner)
          .updateVaultAfterLiquidation(currentLien);

        if (accountantIfAny != address(0)) {
          LIEN_TOKEN.setPayee(currentLien, accountantIfAny);
        }
      }
    }

    reserve = COLLATERAL_TOKEN.auctionVault(collateralId, address(msg.sender));

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
   * @notice Retrieves the fee the liquidator earns for processing auctions
   * @return The numerator and denominator used to compute the percentage fee taken by the liquidator
   */
  function getLiquidatorFee(uint256 amountIn) external view returns (uint256) {
    return
      amountIn.mulDivDown(liquidationFeeNumerator, liquidationFeeDenominator);
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
  ) external returns (bool) {
    uint256 minNewRate = uint256(lien.rate) - minInterestBPS;

    if (newLien.rate < minNewRate) {
      return false;
    }

    if (block.timestamp + newLien.duration - lien.end < minDurationIncrease) {
      return false;
    }

    return true;
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
        address(this),
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
    return
      VaultImplementation(c.lienRequest.strategy.vault).commitToLien(
        c,
        receiver
      );
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
