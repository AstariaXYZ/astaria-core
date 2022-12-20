// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {IAstariaVaultBase} from "core/interfaces/IAstariaVaultBase.sol";
import {IERC165} from "core/interfaces/IERC165.sol";

interface IVaultImplementation is IAstariaVaultBase, IERC165 {
  enum InvalidRequestReason {
    NO_AUTHORITY,
    INVALID_SIGNATURE,
    INVALID_COMMITMENT,
    INVALID_AMOUNT,
    INSUFFICIENT_FUNDS,
    INVALID_RATE,
    INVALID_POTENTIAL_DEBT,
    SHUTDOWN,
    PAUSED
  }

  error InvalidRequest(InvalidRequestReason reason);

  struct InitParams {
    address delegate;
    bool allowListEnabled;
    address[] allowList;
    uint256 depositCap; // max amount of tokens that can be deposited
  }

  struct VIData {
    uint88 depositCap;
    address delegate;
    bool allowListEnabled;
    bool isShutdown;
    uint256 strategistNonce;
    mapping(address => bool) allowList;
  }

  event AllowListUpdated(address, bool);

  event AllowListEnabled(bool);

  event DelegateUpdated(address);

  event NonceUpdated(uint256 nonce);

  event IncrementNonce(uint256 nonce);

  event VaultShutdown();

  function getShutdown() external view returns (bool);

  function shutdown() external;

  function incrementNonce() external;

  function commitToLien(
    IAstariaRouter.Commitment calldata params,
    address receiver
  ) external returns (uint256 lienId, ILienToken.Stack[] memory stack);

  function buyoutLien(
    uint256 collateralId,
    uint8 position,
    IAstariaRouter.Commitment calldata incomingTerms,
    ILienToken.Stack[] calldata stack
  ) external returns (ILienToken.Stack[] memory, ILienToken.Stack memory);

  function recipient() external view returns (address);

  function setDelegate(address delegate_) external;

  function init(InitParams calldata params) external;

  function encodeStrategyData(
    IAstariaRouter.StrategyDetailsParam calldata strategy,
    bytes32 root
  ) external view returns (bytes memory);

  function domainSeparator() external view returns (bytes32);

  function modifyDepositCap(uint256 newCap) external;

  function getStrategistNonce() external view returns (uint256);

  function STRATEGY_TYPEHASH() external view returns (bytes32);
}
