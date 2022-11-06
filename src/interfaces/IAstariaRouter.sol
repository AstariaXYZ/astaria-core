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
import {IVault} from "gpl/ERC4626-Cloned.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";

import {IPausable} from "core/utils/Pausable.sol";
import {IBeacon} from "./IBeacon.sol";

interface IAstariaRouter is IPausable, IBeacon {
  struct RouterStorage {
    //slot 1
    uint32 minInterestBPS; // was uint64
    uint32 auctionWindow;
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
    IAuctionHouse AUCTION_HOUSE; //20
    address feeTo; //20
    address BEACON_PROXY_IMPLEMENTATION; //20
    uint88 maxInterestRate; //6
    mapping(uint32 => address) strategyValidators;
    //slot 3 +
    address guardian; //20
    uint32 buyoutFeeNumerator;
    uint32 buyoutFeeDenominator;
    uint32 strategistFeeDenominator;
    uint32 strategistFeeNumerator; //4
    uint32 minDurationIncrease;
    uint32 buyoutInterestWindow;
    mapping(uint8 => address) implementations;
    //A strategist can have many deployed vaults
    mapping(address => address) vaults;
  }

  enum ImplementationType {
    PrivateVault,
    PublicVault,
    WithdrawProxy
  }

  enum LienRequestType {
    UNIQUE,
    COLLECTION,
    UNIV3_LIQUIDITY
  }

  struct StrategyDetails {
    uint8 version;
    uint256 deadline;
    address vault;
  }

  struct MerkleData {
    bytes32 root;
    bytes32[] proof;
  }

  struct NewLienRequest {
    StrategyDetails strategy;
    ILienToken.Stack[] stack;
    uint8 nlrType;
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
   * @notice Validates the incoming commitment
   * @param commitment The commitment proofs and requested loan data for each loan.
   * @return lien the new Lien data
   */
  function validateCommitment(IAstariaRouter.Commitment calldata commitment)
    external
    returns (ILienToken.Lien memory lien);

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

  function LIEN_TOKEN() external view returns (ILienToken);

  function AUCTION_HOUSE() external view returns (IAuctionHouse);

  function TRANSFER_PROXY() external view returns (ITransferProxy);

  function BEACON_PROXY_IMPLEMENTATION() external view returns (address);

  function COLLATERAL_TOKEN() external view returns (ICollateralToken);

  function maxInterestRate() external view returns (uint256);

  function getAuctionWindow() external view returns (uint256);

  function getStrategistFee(uint256) external view returns (uint256);

  function getProtocolFee(uint256) external view returns (uint256);

  function getBuyoutFee(uint256) external view returns (uint256);

  function getLiquidatorFee(uint256) external view returns (uint256);

  function getBuyoutInterestWindow() external view returns (uint32);

  /**
   * @notice Lend to a PublicVault.
   * @param vault The address of the PublicVault.
   * @param amount The amount to lend.
   */
  function lendToVault(IVault vault, uint256 amount) external;

  /**
   * @notice Liquidate a CollateralToken that has defaulted on one of its liens.
   * @param collateralId The ID of the CollateralToken.
   * @param position The position of the defaulted lien.
   * @return reserve The amount owed on all liens for against the collateral being liquidated, including accrued interest.
   */
  function liquidate(
    uint256 collateralId,
    uint8 position,
    ILienToken.Stack[] calldata stack
  ) external returns (uint256 reserve);

  function canLiquidate(ILienToken.Stack calldata) external view returns (bool);

  function isValidVault(address) external view returns (bool);

  function isValidRefinance(
    ILienToken.Lien calldata newLien,
    uint8 position,
    ILienToken.Stack[] calldata stack
  ) external view returns (bool);

  /**
   * @notice Cancels the auction for a CollateralToken and returns the NFT to the borrower.
   * @param tokenId The ID of the CollateralToken to cancel the auction for.
   */
  function cancelAuction(uint256 tokenId) external;

  /**
   * @notice Ends the auction for a CollateralToken.
   * @param tokenId The ID of the CollateralToken to stop the auction for.
   */
  function endAuction(uint256 tokenId) external;

  event Liquidation(uint256 collateralId, uint256 position, uint256 reserve);
  event NewVault(address appraiser, address vault);

  error InvalidEpochLength(uint256);
  error InvalidRefinanceRate(uint256);
  error InvalidRefinanceDuration(uint256);
  error InvalidVaultState(VaultState);
  error InvalidSenderForCollateral(address, uint256);
  error InvalidLienState(LienState);
  error InvalidCollateralState(CollateralStates);
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
  error InvalidCommitmentState(CommitmentState);
  error InvalidStrategy(uint16);
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
