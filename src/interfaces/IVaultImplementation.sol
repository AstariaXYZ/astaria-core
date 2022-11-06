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

interface IVaultImplementation {
  enum InvalidRequestReason {
    INVALID_SIGNATURE,
    INVALID_COMMITMENT,
    INVALID_AMOUNT,
    INSUFFICIENT_FUNDS,
    INVALID_RATE,
    INVALID_POTENTIAL_DEBT
  }

  error InvalidRequest(InvalidRequestReason);

  struct InitParams {
    address delegate;
    bool allowListEnabled;
    address[] allowList;
    uint256 depositCap; // max amount of tokens that can be deposited
  }

  struct VIData {
    uint32 strategistNonce;
    uint88 depositCap;
    address delegate;
    bool allowListEnabled;
    mapping(address => bool) allowList;
  }

  event NewLien(
    bytes32 strategyRoot,
    address tokenContract,
    uint256 tokenId,
    uint256 amount
  );

  event NewVault(address appraiser, address vault);
  event IncrementNonce(uint32 nonce);

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
    IAstariaRouter.StrategyDetails calldata strategy,
    bytes32 root
  ) external view returns (bytes memory);

  function domainSeparator() external view returns (bytes32);

  function modifyDepositCap(uint256 newCap) external;

  function getStrategistNonce() external view returns (uint32);

  function STRATEGY_TYPEHASH() external view returns (bytes32);
}
