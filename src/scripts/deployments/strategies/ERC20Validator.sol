// SPDX-License-Identifier: BUSL-1.1

/**
 *  █████╗ ███████╗████████╗ █████╗ ██████╗ ██╗ █████╗
 * ██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██║██╔══██╗
 * ███████║███████╗   ██║   ███████║██████╔╝██║███████║
 * ██╔══██║╚════██║   ██║   ██╔══██║██╔══██╗██║██╔══██║
 * ██║  ██║███████║   ██║   ██║  ██║██║  ██║██║██║  ██║
 * ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝
 *
 * Astaria Labs, Inc
 */

pragma solidity =0.8.17;

import {ERC721} from "solmate/tokens/ERC721.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IStrategyValidator} from "core/interfaces/IStrategyValidator.sol";
import {ILocker} from "core/TheLocker.sol";

interface IERC20Validator is IStrategyValidator {
  struct Details {
    uint8 version;
    address token;
    address borrower;
    uint256 minBalance;
    ILienToken.Details lien;
  }
}

contract ERC20Validator is IERC20Validator {
  uint8 public constant VERSION_TYPE = uint8(4);

  function getLeafDetails(
    bytes memory nlrDetails
  ) public pure returns (IERC20Validator.Details memory) {
    return abi.decode(nlrDetails, (IERC20Validator.Details));
  }

  function assembleLeaf(
    IERC20Validator.Details memory details
  ) public pure returns (bytes memory) {
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
    IERC20Validator.Details memory cd = getLeafDetails(params.nlrDetails);

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

    ILocker.Deposit memory deposit = ILocker(collateralTokenContract)
      .getDeposit(collateralTokenId);

    require(deposit.amount >= cd.minBalance, "invalid min balance");
    leaf = keccak256(params.nlrDetails);
    ld = cd.lien;
    ld.maxAmount = cd.lien.maxAmount * deposit.amount;
  }
}
