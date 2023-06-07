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
  IWETH9 WETH;
  ILienToken lienToken;
  address transferProxy;

  constructor(address _WETH9, address _lienToken, address _transferProxy) {
    WETH = IWETH9(_WETH9);
    lienToken = ILienToken(_lienToken);
    transferProxy = _transferProxy;
  }

  function makePayment(
    uint256 collateralId,
    ILienToken.Stack[] calldata stack
  ) external payable returns (ILienToken.Stack[] memory newStack) {
    try WETH.deposit{value: msg.value}() {
      WETH.approve(transferProxy, msg.value);
      WETH.approve(address(lienToken), msg.value);

      // make payment
      newStack = lienToken.makePayment(collateralId, stack, msg.value);

      // check balance
      uint256 balance = WETH.balanceOf(address(this));

      if (balance > 0) {
        // withdraw
        WETH.withdraw(balance);

        // transfer
        payable(msg.sender).transfer(balance);
      }
    } catch {
      revert();
    }
  }

  fallback() external payable {}

  receive() external payable {}
}
