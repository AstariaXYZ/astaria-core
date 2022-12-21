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

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IStrategyValidator} from "core/interfaces/IStrategyValidator.sol";

interface ICollectionValidator is IStrategyValidator {
  struct Details {
    uint8 version;
    address token;
    address borrower;
    ILienToken.Details lien;
  }
}

contract CollectionValidator is ICollectionValidator {
  uint8 public constant VERSION_TYPE = uint8(2);

  function getLeafDetails(bytes memory nlrDetails)
    public
    pure
    returns (ICollectionValidator.Details memory)
  {
    return abi.decode(nlrDetails, (ICollectionValidator.Details));
  }

  function assembleLeaf(ICollectionValidator.Details memory details)
    public
    pure
    returns (bytes memory)
  {
    return abi.encode(details);
  }

  function validateAndParse(
    IAstariaRouter.NewLienRequest calldata params,
    address borrower,
    address collateralTokenContract,
    uint256 // collateralTokenId
  )
    external
    pure
    override
    returns (bytes32 leaf, ILienToken.Details memory ld)
  {
    ICollectionValidator.Details memory cd = getLeafDetails(params.nlrDetails);

    if (cd.version != VERSION_TYPE) {
      revert("invalid type");
    }
    if (cd.borrower != address(0)) {
      require(
        borrower == cd.borrower,
        "invalid borrower requesting commitment"
      );
    }
    require(cd.token == collateralTokenContract, "invalid token contract");

    leaf = keccak256(params.nlrDetails);
    ld = cd.lien;
  }
}
