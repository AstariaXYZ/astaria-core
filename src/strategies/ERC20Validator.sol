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
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

interface IERC20Validator is IStrategyValidator {
  struct Details {
    uint8 version;
    address token;
    address borrower;
    uint256 minAmount;
    // ratio of borrow tokens to collateral tokens expressed is 1e18
    uint256 ratioToUnderlying;
    ILienToken.Details lien;
  }
}

contract ERC20Validator is IERC20Validator {
  using FixedPointMathLib for uint256;
  address immutable THE_LOCKER;
  uint8 public constant VERSION_TYPE = uint8(4);

  constructor(address _THE_LOCKER) {
    THE_LOCKER = _THE_LOCKER;
  }

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

    ILocker.Deposit memory deposit = ILocker(THE_LOCKER).getDeposit(
      collateralTokenId
    );
    require(cd.token == deposit.token, "invalid token contract");
    require(
      deposit.amount >= cd.minAmount && cd.minAmount != 0,
      "invalid min balance"
    );
    require(cd.ratioToUnderlying != 0, "invalid ratioToUnderlying");
    leaf = keccak256(params.nlrDetails);
    ld = cd.lien;
    uint256 maxAmount = cd.ratioToUnderlying.mulWadDown(deposit.amount);
    require(maxAmount <= cd.lien.maxAmount, "deposit too large");
    ld.maxAmount = maxAmount;
  }
}
