// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import {IERC721} from "core/interfaces/IERC721.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";

import {IPausable} from "core/utils/Pausable.sol";
import {IBeacon} from "core/interfaces/IBeacon.sol";
import {IERC4626RouterBase} from "gpl/interfaces/IERC4626RouterBase.sol";
import {OrderParameters} from "seaport/lib/ConsiderationStructs.sol";

interface IAstariaRouter is IPausable, IBeacon {
  enum FileType {
    FeeTo,
    LiquidationFee,
    ProtocolFee,
    StrategistFee,
    MinInterestBPS,
    MinEpochLength,
    MaxEpochLength,
    MinInterestRate,
    MaxInterestRate,
    BuyoutFee,
    MinDurationIncrease,
    BuyoutInterestWindow,
    AuctionWindow,
    StrategyValidator,
    AuctionHouse,
    Implementation,
    CollateralToken,
    LienToken,
    TransferProxy
  }

  struct File {
    FileType what;
    bytes data;
  }

  event FileUpdated(FileType what, bytes data);

  struct RouterStorage {
    //slot 1
    uint32 auctionWindow;
    uint32 auctionWindowBuffer;
    uint32 liquidationFeeNumerator;
    uint32 liquidationFeeDenominator;
    uint32 maxEpochLength;
    uint32 minEpochLength;
    uint32 protocolFeeNumerator;
    uint32 protocolFeeDenominator;
    //slot 2
    ERC20 WETH; //20
    ICollateralToken COLLATERAL_TOKEN; //20
    ILienToken LIEN_TOKEN; //20
    ITransferProxy TRANSFER_PROXY; //20
    address feeTo; //20
    address BEACON_PROXY_IMPLEMENTATION; //20
    uint88 maxInterestRate; //6
    uint32 minInterestBPS; // was uint64
    //slot 3 +
    address guardian; //20
    address newGuardian; //20
    uint32 buyoutFeeNumerator;
    uint32 buyoutFeeDenominator;
    uint32 strategistFeeDenominator;
    uint32 strategistFeeNumerator; //4
    uint32 minDurationIncrease;
    mapping(uint32 => address) strategyValidators;
    mapping(uint8 => address) implementations;
    //A strategist can have many deployed vaults
    mapping(address => address) vaults;
  }

  enum ImplementationType {
    PrivateVault,
    PublicVault,
    WithdrawProxy,
    ClearingHouse
  }

  enum LienRequestType {
    DEACTIVATED,
    UNIQUE,
    COLLECTION,
    UNIV3_LIQUIDITY
  }

  struct StrategyDetailsParam {
    uint8 version;
    uint256 deadline;
    address vault;
  }

  struct MerkleData {
    bytes32 root;
    bytes32[] proof;
  }

  struct NewLienRequest {
    StrategyDetailsParam strategy;
    ILienToken.Stack[] stack;
    bytes nlrDetails;
    MerkleData merkle;
    uint256 amount;
    uint8 v;
    bytes32 r;
    bytes32 s;
  }

  struct Commitment {
    address tokenContract;
    uint256 tokenId;
    NewLienRequest lienRequest;
  }

  /**
   * @notice Validates the incoming loan commitment.
   * @param commitment The commitment proofs and requested loan data for each loan.
   * @return lien the new Lien data.
   */
  function validateCommitment(
    IAstariaRouter.Commitment calldata commitment,
    uint256 timeToSecondEpochEnd
  ) external returns (ILienToken.Lien memory lien);

  /**
   * @notice Deploys a new PublicVault.
   * @param epochLength The length of each epoch for the new PublicVault.
   * @param delegate The address of the delegate account.
   * @param vaultFee fee for the vault
   * @param allowListEnabled flag for the allowlist
   * @param allowList the starting allowList
   * @param depositCap the deposit cap for the vault if any
   */
  function newPublicVault(
    uint256 epochLength,
    address delegate,
    uint256 vaultFee,
    bool allowListEnabled,
    address[] calldata allowList,
    uint256 depositCap
  ) external returns (address);

  /**
   * @notice Deploys a new PrivateVault.
   * @param delegate The address of the delegate account.
   * @return The address of the new PrivateVault.
   */
  function newVault(address delegate) external returns (address);

  /**
   * @notice Retrieves the address that collects protocol-level fees.
   */
  function feeTo() external returns (address);

  /**
   * @notice Deposits collateral and requests loans for multiple NFTs at once.
   * @param commitments The commitment proofs and requested loan data for each loan.
   * @return lienIds the lienIds for each loan.
   */
  function commitToLiens(Commitment[] memory commitments)
    external
    returns (uint256[] memory, ILienToken.Stack[] memory);

  /**
   * @notice Create a new lien against a CollateralToken.
   * @param params The valid proof and lien details for the new loan.
   * @return The ID of the created lien.
   */
  function requestLienPosition(
    IAstariaRouter.Commitment calldata params,
    address recipient
  )
    external
    returns (
      uint256,
      ILienToken.Stack[] memory,
      uint256
    );

  function WETH() external view returns (ERC20);

  function LIEN_TOKEN() external view returns (ILienToken);

  function TRANSFER_PROXY() external view returns (ITransferProxy);

  function BEACON_PROXY_IMPLEMENTATION() external view returns (address);

  function COLLATERAL_TOKEN() external view returns (ICollateralToken);

  function maxInterestRate() external view returns (uint256);

  /**
   * @notice Returns the current auction duration.
   * @param includeBuffer Adds the current auctionWindowBuffer if true.
   */
  function getAuctionWindow(bool includeBuffer) external view returns (uint256);

  /**
   * @notice Computes the fee PublicVault strategists earn on loan origination from the strategistFee numerator and denominator.
   */
  function getStrategistFee(uint256) external view returns (uint256);

  /**
   * @notice Computes the fee the protocol earns on loan origination from the protocolFee numerator and denominator.
   */
  function getProtocolFee(uint256) external view returns (uint256);

  /**
   * @notice Computes the fee Vaults earn when a Lien is bought out using the buyoutFee numerator and denominator.
   */
  function getBuyoutFee(uint256) external view returns (uint256);

  /**
   * @notice Computes the fee the users earn on liquidating an expired lien from the liquidationFee numerator and denominator.
   */
  function getLiquidatorFee(uint256) external view returns (uint256);

  /**
   * @notice Liquidate a CollateralToken that has defaulted on one of its liens.
   * @param stack the stack being liquidated
   * @param position The position of the defaulted lien.
   * @return reserve The amount owed on all liens for against the collateral being liquidated, including accrued interest.
   */
  function liquidate(ILienToken.Stack[] calldata stack, uint8 position)
    external
    returns (OrderParameters memory);

  /**
   * @notice Returns whether a specified lien can be liquidated.
   */
  function canLiquidate(ILienToken.Stack calldata) external view returns (bool);

  /**
   * @notice Returns whether a given address is that of a Vault.
   * @param vault The Vault address.
   * @return A boolean representing whether the address exists as a Vault.
   */
  function isValidVault(address vault) external view returns (bool);

  /**
   * @notice Sets universal protocol parameters or changes the addresses for deployed contracts.
   * @param files Structs to file.
   */
  function fileBatch(File[] calldata files) external;

  /**
   * @notice Sets universal protocol parameters or changes the addresses for deployed contracts.
   * @param incoming The incoming File.
   */
  function file(File calldata incoming) external;

  /**
   * @notice Updates the guardian address.
   * @param _guardian The new guardian.
   */
  function setNewGuardian(address _guardian) external;

  /**
   * @notice Specially guarded file().
   * @param file The incoming data to file.
   */
  function fileGuardian(File[] calldata file) external;

  /**
   * @notice Returns the address for the current implementation of a contract from the ImplementationType enum.
   * @return impl The address of the clone implementation.
   */
  function getImpl(uint8 implType) external view returns (address impl);

  /**
   * @notice Returns whether a new lien offers more favorable terms over an old lien.
   * A new lien must have a rate less than or equal to maxNewRate,
   * or a duration lower by minDurationIncrease, provided the other parameter does not get any worse.
   * @param newLien The new Lien for the proposed refinance.
   * @param position The Lien position against the CollateralToken.
   * @param stack The Stack of existing Liens against the CollateralToken.
   */
  function isValidRefinance(
    ILienToken.Lien calldata newLien,
    uint8 position,
    ILienToken.Stack[] calldata stack
  ) external view returns (bool);

  event Liquidation(uint256 collateralId, uint256 position);
  event NewVault(
    address strategist,
    address delegate,
    address vault,
    uint8 vaultType
  );

  error InvalidFileData();
  error InvalidEpochLength(uint256);
  error InvalidRefinanceRate(uint256);
  error InvalidRefinanceDuration(uint256);
  error InvalidRefinanceCollateral(uint256);
  error InvalidVaultState(VaultState);
  error InvalidSenderForCollateral(address, uint256);
  error InvalidLienState(LienState);
  error InvalidCollateralState(CollateralStates);
  error InvalidCommitmentState(CommitmentState);
  error InvalidStrategy(uint16);
  error InvalidVault(address);
  error UnsupportedFile();

  enum LienState {
    HEALTHY,
    AUCTION
  }

  enum CollateralStates {
    AUCTION,
    NO_AUCTION,
    NO_DEPOSIT,
    NO_LIENS
  }

  enum CommitmentState {
    INVALID,
    INVALID_RATE,
    INVALID_AMOUNT,
    EXPIRED,
    COLLATERAL_AUCTION,
    COLLATERAL_NO_DEPOSIT
  }

  enum VaultState {
    UNINITIALIZED,
    CLOSED,
    LIQUIDATED
  }
}
