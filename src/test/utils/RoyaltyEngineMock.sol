// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IRoyaltyEngine} from "core/interfaces/IRoyaltyEngine.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC165} from "core/interfaces/IERC165.sol";

contract RoyaltyEngineMock is IRoyaltyEngine {
  using FixedPointMathLib for uint256;

  function supportsInterface(bytes4 interfaceId)
    external
    pure
    override
    returns (bool)
  {
    return
      interfaceId == type(IRoyaltyEngine).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  constructor() {}

  function getRoyalty(
    address tokenAddress,
    uint256 tokenId,
    uint256 value
  )
    external
    returns (address payable[] memory recipients, uint256[] memory amounts)
  {
    if (tokenId == uint256(99)) {
      recipients = new address payable[](1);
      amounts = new uint256[](1);
      recipients[0] = payable(address(tx.origin));
      amounts[0] = value.mulDivDown(250, 10000);
    }
  }

  /**
   * View only version of getRoyalty
   *
   * @param tokenAddress - The address of the token
   * @param tokenId      - The id of the token
   * @param value        - The value you wish to get the royalty of
   *
   * returns Two arrays of equal length, royalty recipients and the corresponding amount each recipient should get
   */
  function getRoyaltyView(
    address tokenAddress,
    uint256 tokenId,
    uint256 value
  )
    external
    view
    returns (address payable[] memory recipients, uint256[] memory amounts)
  {
    if (tokenId == uint256(99)) {
      recipients = new address payable[](1);
      amounts = new uint256[](1);
      recipients[0] = payable(address(tx.origin));
      amounts[0] = value.mulDivDown(250, 10000);
    }
  }
}
