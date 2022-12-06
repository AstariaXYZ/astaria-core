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

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IStrategyValidator} from "core/interfaces/IStrategyValidator.sol";

interface IChickenBondValidator is IStrategyValidator {
  struct Details {
    uint8 version;
    address token;
    uint256 tokenId;
    address borrower;
    ILienToken.Details lien;
  }
}

interface IChickenBondInterface {
  function getBondData(uint256 _bondID)
    external
    view
    returns (
      uint256 lusdAmount,
      uint64 claimedBLUSD,
      uint64 startTime,
      uint64 endTime,
      uint8 status
    );
}

contract ChickenBondValidator is IChickenBondValidator {
  uint8 public constant VERSION_TYPE = uint8(3);

  address public constant CHICKEN_BOND_MGR =
    0x57619FE9C539f890b19c61812226F9703ce37137;

  function getLeafDetails(bytes memory nlrDetails)
    public
    pure
    returns (IChickenBondValidator.Details memory)
  {
    return abi.decode(nlrDetails, (IChickenBondValidator.Details));
  }

  function assembleLeaf(IChickenBondValidator.Details memory details)
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
    uint256 collateralTokenId
  )
    external
    view
    override
    returns (bytes32 leaf, ILienToken.Details memory ld)
  {
    IChickenBondValidator.Details memory cd = getLeafDetails(params.nlrDetails);

    (, , , uint64 endTime, uint8 bondStatus) = IChickenBondInterface(
      CHICKEN_BOND_MGR
    ).getBondData(cd.tokenId);

    if (block.timestamp > endTime) {
      revert("Bond has expired");
    }
    if (bondStatus != uint8(1)) {
      revert("Bond is not active");
    }
    if (cd.version != VERSION_TYPE) {
      revert("Invalid version");
    }
    if (cd.token != collateralTokenContract) {
      revert("Invalid token");
    }

    if (cd.borrower != borrower) {
      revert("Invalid borrower");
    }

    leaf = keccak256(assembleLeaf(cd));
    ld = cd.lien;
  }
}
