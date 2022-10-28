// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.15;

import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {IERC721} from "core/interfaces/IERC721.sol";
import "./IAstariaRouter.sol";

interface ICollateralToken is IERC721 {
  function auctionVault(
    uint256,
    address,
    uint256
  ) external;

  function AUCTION_HOUSE() external view returns (IAuctionHouse);

  function ASTARIA_ROUTER() external view returns (IAstariaRouter);

  function auctionWindow() external view returns (uint256);

  function securityHooks(address) external view returns (address);

  function getUnderlying(uint256) external view returns (address, uint256);

  error InvalidCollateral();
  error InvalidSender();
  error InvalidCollateralState(InvalidCollateralStates);
  error ProtocolPaused();

  enum InvalidCollateralStates {
    NO_AUCTION,
    AUCTION,
    ACTIVE_LIENS
  }

  error FlashActionCallbackFailed();
  error FlashActionSecurityCheckFailed();
  error FlashActionNFTNotReturned();
}
