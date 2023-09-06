pragma solidity ^0.8.0;
import "./TestHelpers.t.sol";
import "./utils/SigUtils.sol";
import {
  IERC20Validator,
  ERC20Validator
} from "core/strategies/ERC20Validator.sol";
import {TheLocker} from "core/TheLocker.sol";
import "core/ERC20BorrowHelper.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract ERC20Testing is TestHelpers, SigUtils {
  // happy path of a borrow
  function testERC20Borrow() public {
    //create new public vault

    ERC20BorrowHelper borrowHelper = new ERC20BorrowHelper(
      address(WETH9),
      ICollateralToken(COLLATERAL_TOKEN),
      THE_LOCKER,
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
      version: uint8(4),
      token: address(collateralToken),
      borrower: address(0),
      minAmount: uint256(1 ether),
      ratioToUnderlying: uint256(1 ether),
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

    uint256 balanceBefore = address(this).balance;
    erc20s[1].mint(address(this), 5 ether);
    collateralToken.approve(address(borrowHelper), 5 ether);
    borrowHelper.borrow(collateralToken, amount, lienRequest);

    assertEq(
      address(this).balance - balanceBefore,
      amount,
      "borrow balance incorrect"
    );
  }

  // Strategist provides and invalid amount for a minAmount in the LienRequest of 0
  function testERC20InvalidMinAmountOfZero() public {
    //create new public vault

    ERC20BorrowHelper borrowHelper = new ERC20BorrowHelper(
      address(WETH9),
      ICollateralToken(COLLATERAL_TOKEN),
      THE_LOCKER,
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
      version: uint8(4),
      token: address(collateralToken),
      borrower: address(0),
      minAmount: 0,
      ratioToUnderlying: uint256(1 ether),
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

    uint256 balanceBefore = address(this).balance;
    erc20s[1].mint(address(this), 5 ether);
    collateralToken.approve(address(borrowHelper), 5 ether);
    vm.expectRevert("invalid min balance");
    borrowHelper.borrow(collateralToken, amount, lienRequest);
  }

  // borrower provides less than the minAmount of the deposit token specified in the LienRequest
  function testERC20InvalidMinAmountOfProvided() public {
    //create new public vault

    ERC20BorrowHelper borrowHelper = new ERC20BorrowHelper(
      address(WETH9),
      ICollateralToken(COLLATERAL_TOKEN),
      THE_LOCKER,
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
      version: uint8(4),
      token: address(collateralToken),
      borrower: address(0),
      minAmount: uint256(5 ether) + 1,
      ratioToUnderlying: uint256(1 ether),
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

    uint256 balanceBefore = address(this).balance;
    erc20s[1].mint(address(this), 5 ether);
    collateralToken.approve(address(borrowHelper), 5 ether);
    vm.expectRevert("invalid min balance");
    borrowHelper.borrow(collateralToken, amount, lienRequest);
  }

  // Strategist provides and invalid ratioToUnderlying in the LienRequest of 0
  function testERC20InvalidRatioToUnderlying() public {
    //create new public vault

    ERC20BorrowHelper borrowHelper = new ERC20BorrowHelper(
      address(WETH9),
      ICollateralToken(COLLATERAL_TOKEN),
      THE_LOCKER,
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
      version: uint8(4),
      token: address(collateralToken),
      borrower: address(0),
      minAmount: uint256(1 ether),
      ratioToUnderlying: 0,
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

    uint256 balanceBefore = address(this).balance;
    erc20s[1].mint(address(this), 5 ether);
    collateralToken.approve(address(borrowHelper), 5 ether);
    vm.expectRevert("invalid ratioToUnderlying");
    borrowHelper.borrow(collateralToken, amount, lienRequest);
  }

  // the amount requested to borrow exceeds the maxAmount in the LienRequest
  function testERC20ExceedsMaxAmount() public {
    //create new public vault

    ERC20BorrowHelper borrowHelper = new ERC20BorrowHelper(
      address(WETH9),
      ICollateralToken(COLLATERAL_TOKEN),
      THE_LOCKER,
      IAstariaRouter(ASTARIA_ROUTER)
    );

    ERC20 collateralToken = ERC20(address(erc20s[1]));

    uint256 amount = 5 ether;
    uint256 strategyDuration = 7 days;

    PublicVault vault = PublicVault(
      _createPublicVault(strategistOne, strategistTwo, 10 days)
    );

    _lendToVault(Lender({addr: alice, amountToLend: 50 ether}), payable(vault));

    standardLienDetails.maxAmount = 5 ether - 1;
    IERC20Validator.Details memory validatorDetails = IERC20Validator.Details({
      version: uint8(4),
      token: address(collateralToken),
      borrower: address(0),
      minAmount: uint256(1 ether),
      ratioToUnderlying: uint256(1 ether),
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

    uint256 balanceBefore = address(this).balance;
    erc20s[1].mint(address(this), 5 ether);
    collateralToken.approve(address(borrowHelper), 5 ether);
    vm.expectRevert("deposit too large");
    borrowHelper.borrow(collateralToken, amount, lienRequest);
  }

  // depost token (TheLocker) and the token in the LienRequest are mismatched
  function testERC20InvalidDepositToken() public {
    //create new public vault

    ERC20BorrowHelper borrowHelper = new ERC20BorrowHelper(
      address(WETH9),
      ICollateralToken(COLLATERAL_TOKEN),
      THE_LOCKER,
      IAstariaRouter(ASTARIA_ROUTER)
    );

    // ERC20 collateralToken = ERC20(address(erc20s[2]));
    uint256 amount = 5 ether;

    PublicVault vault = PublicVault(
      _createPublicVault(strategistOne, strategistTwo, 10 days)
    );

    _lendToVault(Lender({addr: alice, amountToLend: 50 ether}), payable(vault));

    IERC20Validator.Details memory validatorDetails = IERC20Validator.Details({
      version: uint8(4),
      token: address(erc20s[2]),
      borrower: address(0),
      minAmount: uint256(1 ether),
      ratioToUnderlying: uint256(1 ether),
      lien: standardLienDetails
    });
    bytes memory nlrDetails = abi.encode(validatorDetails);
    bytes32 root = keccak256(nlrDetails);
    bytes32 strategyHash = getTypedDataHash(
      vault.domainSeparator(),
      EIP712Message({
        nonce: vault.getStrategistNonce(),
        root: root,
        deadline: block.timestamp + 7 days
      })
    );

    IAstariaRouter.StrategyDetailsParam memory strategyDetails = IAstariaRouter
      .StrategyDetailsParam({
        version: uint8(0),
        deadline: block.timestamp + 7 days,
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

    erc20s[1].mint(address(this), 5 ether);
    ERC20(address(erc20s[1])).approve(address(THE_LOCKER), 5 ether);
    uint256 tokenId = THE_LOCKER.deposit(ERC20(address(erc20s[1])), amount);
    THE_LOCKER.approve(address(ASTARIA_ROUTER), tokenId);
    vm.expectRevert("invalid token contract");
    ASTARIA_ROUTER.commitToLien(
      IAstariaRouter.Commitment({
        tokenContract: address(THE_LOCKER),
        tokenId: tokenId,
        lienRequest: lienRequest
      })
    );
  }
}
