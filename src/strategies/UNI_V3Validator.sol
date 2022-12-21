// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity =0.8.17;

import {ERC721} from "solmate/tokens/ERC721.sol";

import {CollateralLookup} from "core/libraries/CollateralLookup.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IStrategyValidator} from "core/interfaces/IStrategyValidator.sol";
import {IV3PositionManager} from "core/interfaces/IV3PositionManager.sol";
import {IUniswapV3Factory} from "gpl/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3PoolState} from "gpl/interfaces/IUniswapV3PoolState.sol";
import {TickMath} from "gpl/utils/TickMath.sol";
import {LiquidityAmounts} from "gpl/utils/LiquidityAmounts.sol";

interface IUNI_V3Validator is IStrategyValidator {
  struct Details {
    uint8 version;
    address lp;
    address borrower;
    address token0;
    address token1;
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint128 minLiquidity;
    uint256 amount0Min;
    uint256 amount1Min;
    ILienToken.Details lien;
  }
}

contract UNI_V3Validator is IUNI_V3Validator {
  using CollateralLookup for address;

  error InvalidFee();
  error InvalidType();
  error InvalidBorrower();
  error InvalidCollateral();
  error InvalidPair();
  error InvalidAmounts();
  error InvalidRange();
  error InvalidLiquidity();

  uint8 public constant VERSION_TYPE = uint8(3);

  IV3PositionManager public V3_NFT_POSITION_MGR =
    IV3PositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
  IUniswapV3Factory public V3_FACTORY =
    IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

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
    returns (bytes32 leaf, ILienToken.Details memory ld)
  {
    IUNI_V3Validator.Details memory details = getLeafDetails(params.nlrDetails);

    if (details.version != VERSION_TYPE) {
      revert InvalidType();
    }
    if (details.borrower != address(0) && borrower != details.borrower) {
      revert InvalidBorrower();
    }

    //ensure its also the correct token
    if (details.lp != collateralTokenContract) {
      revert InvalidCollateral();
    }

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

    if (details.fee != uint24(0) && fee != details.fee) {
      revert InvalidFee();
    }

    if (details.token0 != token0 || details.token1 != token1) {
      revert InvalidPair();
    }

    //get pool from factory

    //get pool state
    //get slot 0
    (uint160 poolSQ96, , , , , , ) = IUniswapV3PoolState(
      V3_FACTORY.getPool(token0, token1, fee)
    ).slot0();

    (uint256 amount0, uint256 amount1) = LiquidityAmounts
      .getAmountsForLiquidity(
        poolSQ96,
        TickMath.getSqrtRatioAtTick(tickLower),
        TickMath.getSqrtRatioAtTick(tickUpper),
        liquidity
      );

    if (details.amount0Min > amount0 || details.amount1Min > amount1) {
      revert InvalidAmounts();
    }
    if (details.tickUpper != tickUpper || details.tickLower != tickLower) {
      revert InvalidRange();
    }

    if (details.minLiquidity > liquidity) {
      revert InvalidLiquidity();
    }

    leaf = keccak256(params.nlrDetails);
    ld = details.lien;
  }
}
