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

import {ICollateralToken} from "./ICollateralToken.sol";
import {ILienToken} from "./ILienToken.sol";

import {IPausable} from "core/utils/Pausable.sol";
import {IBeacon} from "./IBeacon.sol";

interface IAstariaRouter is IPausable, IBeacon {
  enum ImplementationType {
    PrivateVault,
    PublicVault,
    LiquidationAccountant,
    WithdrawProxy
  }

  //  struct LienDetails {
  //    uint256 maxAmount;
  //    uint256 rate; //rate per second
  //    uint256 duration;
  //    uint256 maxPotentialDebt;
  //  }

  enum LienRequestType {
    UNIQUE,
    COLLECTION,
    UNIV3_LIQUIDITY
  }

  struct StrategyDetails {
    uint8 version;
    address strategist;
    uint256 deadline;
    address vault;
  }

  struct MerkleData {
    bytes32 root;
    bytes32[] proof;
  }

  struct NewLienRequest {
    StrategyDetails strategy;
    ILienToken.LienEvent[] stack;
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

  struct RefinanceCheckParams {
    uint256 position;
    Commitment incoming;
  }

  function strategistNonce(address strategist) external view returns (uint256);

  function validateCommitment(Commitment calldata)
    external
    returns (bool, ILienToken.Details memory);

  function newPublicVault(
    uint256,
    address,
    uint256,
    bool,
    address[] calldata,
    uint256
  ) external returns (address);

  function newVault(address) external returns (address);

  function feeTo() external returns (address);

  function commitToLiens(Commitment[] calldata)
    external
    returns (uint256[] memory, ILienToken.LienEvent[] memory);

  function requestLienPosition(
    ILienToken.Details memory,
    IAstariaRouter.Commitment calldata
  ) external returns (uint256, ILienToken.LienEvent[] memory);

  function LIEN_TOKEN() external view returns (ILienToken);

  function TRANSFER_PROXY() external view returns (ITransferProxy);

  function BEACON_PROXY_IMPLEMENTATION() external view returns (address);

  //
  //  function LIQUIDATION_IMPLEMENTATION() external view returns (address);
  //
  //  function VAULT_IMPLEMENTATION() external view returns (address);

  function COLLATERAL_TOKEN() external view returns (ICollateralToken);

  function maxInterestRate() external view returns (uint256);

  function getStrategistFee(uint256) external view returns (uint256);

  function getProtocolFee(uint256) external view returns (uint256);

  function getBuyoutFee(uint256) external view returns (uint256);

  function getLiquidatorFee(uint256) external view returns (uint256);

  function getBuyoutInterestWindow() external view returns (uint32);

  function lendToVault(IVault vault, uint256 amount) external;

  function liquidate(
    uint256 collateralId,
    uint256 position,
    ILienToken.LienEvent[] memory stack
  ) external returns (uint256 reserve);

  function canLiquidate(
    uint256 collateralId,
    uint256 position,
    ILienToken.LienEvent[] memory stack
  ) external view returns (bool);

  function isValidVault(address) external view returns (bool);

  function isValidRefinance(ILienToken.Lien memory, ILienToken.Details memory)
    external
    view
    returns (bool);

  event Liquidation(uint256 collateralId, uint256 position, uint256 reserve);
  event NewVault(address appraiser, address vault);

  error InvalidEpochLength(uint256);
  error InvalidRefinanceRate(uint256);
  error InvalidRefinanceDuration(uint256);
  error InvalidVaultState(VaultState);
  error InvalidSenderForCollateral(address, uint256);
  error InvalidLienState(LienState);
  enum LienState {
    HEALTHY,
    AUCTION
  }
  error InvalidCommitmentState(CommitmentState);
  error InvalidStrategy(uint16);
  enum CommitmentState {
    INVALID,
    EXPIRED
  }

  enum VaultState {
    UNINITIALIZED,
    CLOSED,
    LIQUIDATED
  }
}
