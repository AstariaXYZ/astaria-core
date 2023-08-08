pragma solidity ^0.8.0;
import "./TestHelpers.t.sol";
import "./utils/SigUtils.sol";

import {
  IERC20Validator,
  ERC20Validator
} from "core/scripts/deployments/strategies/ERC20Validator.sol";
import {TheLocker} from "core/TheLocker.sol";
import "core/ERC20BorrowHelper.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract ERC20Testing is TestHelpers, SigUtils {
  function testERC20Borrow() public {
    //create new public vault

    ERC20Validator validator = new ERC20Validator();
    TheLocker locker = new TheLocker();

    ERC20BorrowHelper borrowHelper = new ERC20BorrowHelper(
      address(WETH9),
      ICollateralToken(COLLATERAL_TOKEN),
      locker,
      IAstariaRouter(ASTARIA_ROUTER)
    );

    ERC20 collateralToken = ERC20(address(erc20s[1]));

    uint256 amount = 5 ether;
    uint256 strategyDuration = 7 days;

    PublicVault vault = PublicVault(
      _createPublicVault(strategistOne, strategistTwo, 10 days)
    );

    _lendToVault(Lender({addr: alice, amountToLend: 50 ether}), payable(vault));

    IERC20Validator.Details memory validatorDetails = IERC20Validator.Details({
      version: validator.VERSION_TYPE(),
      token: address(collateralToken),
      borrower: address(0),
      minBalance: uint256(1 ether),
      lien: standardLienDetails
    });
    bytes memory nlrDetails = abi.encode(validatorDetails);
    bytes32 root = keccak256(nlrDetails);
    bytes32 strategyHash = getTypedDataHash(
      vault.domainSeparator(),
      EIP712Message({
        nonce: vault.getStrategistNonce(),
        root: root,
        deadline: block.timestamp + strategyDuration
      })
    );

    ASTARIA_ROUTER.file(
      IAstariaRouter.File({
        what: IAstariaRouter.FileType.StrategyValidator,
        data: abi.encode(uint8(4), address(validator))
      })
    );

    IAstariaRouter.StrategyDetailsParam memory strategyDetails = IAstariaRouter
      .StrategyDetailsParam({
        version: uint8(0),
        deadline: block.timestamp + strategyDuration,
        vault: payable(address(vault))
      });
    IAstariaRouter.NewLienRequest memory lienRequest = IAstariaRouter
      .NewLienRequest({
        strategy: strategyDetails,
        nlrDetails: nlrDetails,
        root: root,
        proof: new bytes32[](0),
        amount: amount,
        v: 0,
        r: 0,
        s: 0
      });

    (lienRequest.v, lienRequest.r, lienRequest.s) = vm.sign(
      strategistOnePK,
      strategyHash
    );

    erc20s[1].mint(address(this), 50 ether);
    collateralToken.approve(address(borrowHelper), 50 ether);
    borrowHelper.borrow(collateralToken, amount, lienRequest);

    //create new ERC20 token
  }
}
