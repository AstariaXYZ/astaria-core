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

interface IVaultImplementation {
  enum InvalidRequestReason {
    INVALID_SIGNATURE,
    INVALID_STRATEGIST,
    INVALID_COMMITMENT,
    INVALID_AMOUNT,
    INSUFFICIENT_FUNDS,
    INVALID_RATE,
    INVALID_POTENTIAL_DEBT
  }

  error InvalidRequest(InvalidRequestReason);

  //epoch data
  struct EpochData {
    uint256 liensOpenForEpoch;
    address withdrawProxy;
    address liquidationAccountant;
  }

  struct VaultData {
    uint256 last;
    uint256 yIntercept;
    uint256 slope;
    uint256 withdrawReserve;
    uint256 liquidationWithdrawRatio;
    uint256 strategistUnclaimedShares;
    uint64 currentEpoch;
    mapping(uint256 => EpochData) epochData;
  }
}
