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
}
