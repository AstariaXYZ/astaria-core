pragma solidity =0.8.17;
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ILocker} from "core/TheLocker.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import "./test/utils/ERC721Recipient.sol";

contract ERC20BorrowHelper is ERC721Recipient {
  using SafeTransferLib for ERC20;

  address public immutable WETH;
  ICollateralToken public CT;
  ILocker public immutable LOCKER;
  IAstariaRouter public immutable ROUTER;

  constructor(
    address _WETH9,
    ICollateralToken _CT,
    ILocker _LOCKER,
    IAstariaRouter _ROUTER
  ) {
    WETH = _WETH9;
    CT = _CT;
    LOCKER = _LOCKER;
    ROUTER = _ROUTER;
  }

  function borrow(
    ERC20 collateral,
    uint256 amount,
    IAstariaRouter.NewLienRequest calldata newLienRequest
  ) external payable {
    collateral.safeTransferFrom(msg.sender, address(this), amount);
    collateral.safeApprove(address(LOCKER), amount);
    uint256 newId = LOCKER.deposit(collateral, amount);
    LOCKER.approve(address(ROUTER), newId);
    (, ILienToken.Stack memory newStack) = ROUTER.commitToLien(
      IAstariaRouter.Commitment({
        tokenContract: address(LOCKER),
        tokenId: newId,
        lienRequest: newLienRequest
      })
    );
    if (newStack.lien.token == WETH) {
      msg.sender.call{value: newStack.point.amount}("");
    } else {
      ERC20(newStack.lien.token).safeTransfer(
        msg.sender,
        newStack.point.amount
      );
    }
    CT.safeTransferFrom(address(this), msg.sender, newStack.lien.collateralId);
  }

  receive() external payable {}
}
