// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 * 
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import {ERC721} from "solmate/tokens/ERC721.sol";

import {CollateralLookup} from "../libraries/CollateralLookup.sol";
import {IAstariaRouter} from "../interfaces/IAstariaRouter.sol";
import {IStrategyValidator} from "../interfaces/IStrategyValidator.sol";
import {IV3PositionManager} from "../interfaces/IV3PositionManager.sol";

interface IUNI_V3Validator is IStrategyValidator {
  struct Details {
    uint8 version;
    address token;
    address[] assets;
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint128 minLiquidity;
    address borrower;
    IAstariaRouter.LienDetails lien;
  }
}

contract UNI_V3Validator is IUNI_V3Validator {
  using CollateralLookup for address;

  IV3PositionManager V3_NFT_POSITION_MGR =
    IV3PositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

  function assembleLeaf(IUNI_V3Validator.Details memory details)
    public
    pure
    returns (bytes memory)
  {
    return abi.encode(details);
  }

  function getLeafDetails(bytes memory nlrDetails)
    public
    pure
    returns (IUNI_V3Validator.Details memory)
  {
    return abi.decode(nlrDetails, (IUNI_V3Validator.Details));
  }

  function validateAndParse(
    IAstariaRouter.NewLienRequest calldata params,
    address borrower,
    address collateralTokenContract,
    uint256 collateralTokenId
  )
    external
    view
    override
    returns (bytes32 leaf, IAstariaRouter.LienDetails memory ld)
  {
    IUNI_V3Validator.Details memory details = getLeafDetails(params.nlrDetails);

    if (details.borrower != address(0)) {
      require(
        borrower == details.borrower,
        "invalid borrower requesting commitment"
      );
    }

    //ensure its also the correct token
    require(details.token == collateralTokenContract, "invalid token contract");

    (
      ,
      ,
      address token0,
      address token1,
      uint24 fee,
      int24 tickLower,
      int24 tickUpper,
      uint128 liquidity,
      ,
      ,
      ,

    ) = V3_NFT_POSITION_MGR.positions(collateralTokenId);

    if (details.fee != uint24(0)) {
      require(fee == details.fee, "fee mismatch");
    }
    require(
      details.assets[0] == token0 && details.assets[1] == token1,
      "invalid pair"
    );
    require(
      details.tickUpper == tickUpper && details.tickLower == tickLower,
      "invalid range"
    );

    require(details.minLiquidity <= liquidity, "insufficient liquidity");

    leaf = keccak256(assembleLeaf(details));
    ld = details.lien;
  }
}
