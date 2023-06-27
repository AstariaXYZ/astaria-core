pragma solidity =0.8.17;

pragma experimental ABIEncoderV2;
import {ILienToken} from "core/interfaces/ILienToken.sol";
import "openzeppelin/token/ERC20/IERC20.sol";

/// @title Interface for WETH9
interface IWETH9 is IERC20 {
  /// @notice Deposit ether to get wrapped ether
  function deposit() external payable;

  /// @notice Withdraw wrapped ether to get ether
  function withdraw(uint256) external;
}

contract RepaymentHelper {
  IWETH9 public immutable WETH;
  ILienToken public lienToken;
  address public transferProxy;

  constructor(address _WETH9, address _lienToken, address _transferProxy) {
    WETH = IWETH9(_WETH9);
    lienToken = ILienToken(_lienToken);
    transferProxy = _transferProxy;
  }

  function makePayment(ILienToken.Stack calldata stack) external payable {
    uint256 owing = lienToken.getOwed(stack);
    if (owing > msg.value) {
      revert("not enough funds");
    }

    try WETH.deposit{value: owing}() {
      WETH.approve(transferProxy, owing);
      // make payment
      lienToken.makePayment(stack);
      // check balance
      if (address(this).balance > 0) {
        // withdraw
        payable(msg.sender).transfer(address(this).balance);
      }
    } catch {
      revert();
    }
  }

  receive() external payable {}
}
