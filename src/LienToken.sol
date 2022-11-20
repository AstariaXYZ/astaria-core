// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

pragma experimental ABIEncoderV2;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {ERC721} from "gpl/ERC721.sol";
import {IERC721} from "core/interfaces/IERC721.sol";
import {IERC165} from "core/interfaces/IERC165.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {Base64} from "core/libraries/Base64.sol";
import {CollateralLookup} from "core/libraries/CollateralLookup.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";

import {IPublicVault} from "core/interfaces/IPublicVault.sol";
import {VaultImplementation} from "./VaultImplementation.sol";
import {IERC1155Receiver} from "core/interfaces/IERC1155Receiver.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

/**
 * @title LienToken
 * @notice This contract handles the creation, payments, buyouts, and liquidations of tokenized NFT-collateralized debt (liens). Vaults which originate loans against supported collateral are issued a LienToken representing the right to loan repayments and auctioned funds on liquidation.
 */
contract LienToken is ERC721, ILienToken, Auth {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeCastLib for uint256;
  using SafeTransferLib for ERC20;
  bytes32 constant LIEN_SLOT = keccak256("xyz.astaria.lien.storage.location");

  /**
   * @dev Setup transfer authority and initialize the buyoutNumerator and buyoutDenominator for the lien buyout premium.
   * @param _AUTHORITY The authority manager.
   * @param _TRANSFER_PROXY The TransferProxy for balance transfers.
   * @param _WETH The WETH address to use for transfers.
   */
  constructor(
    Authority _AUTHORITY,
    ITransferProxy _TRANSFER_PROXY,
    address _WETH
  ) Auth(address(msg.sender), _AUTHORITY) ERC721("Astaria Lien Token", "ALT") {
    LienStorage storage s = _loadLienStorageSlot();
    s.TRANSFER_PROXY = _TRANSFER_PROXY;
    s.WETH = _WETH;
    s.maxLiens = uint8(5);
  }

  function _loadLienStorageSlot()
    internal
    pure
    returns (LienStorage storage s)
  {
    bytes32 slot = LIEN_SLOT;
    assembly {
      s.slot := slot
    }
  }

  function file(File calldata incoming) external requiresAuth {
    FileType what = incoming.what;
    bytes memory data = incoming.data;
    LienStorage storage s = _loadLienStorageSlot();
    if (what == FileType.CollateralToken) {
      address addr = abi.decode(data, (address));
      s.COLLATERAL_TOKEN = ICollateralToken(addr);
    } else if (what == FileType.AstariaRouter) {
      address addr = abi.decode(data, (address));
      s.ASTARIA_ROUTER = IAstariaRouter(addr);
    } else {
      revert UnsupportedFile();
    }
    emit FileUpdated(what, data);
  }

  function supportsInterface(bytes4 interfaceId)
    public
    view
    override(ERC721, IERC165)
    returns (bool)
  {
    return
      interfaceId == type(ILienToken).interfaceId ||
      super.supportsInterface(interfaceId);
  }

  function buyoutLien(ILienToken.LienActionBuyout calldata params)
    external
    validateStack(
      params.encumber.stack[0].lien.collateralId,
      params.encumber.stack
    )
    returns (Stack[] memory, Stack memory newStack)
  {
    if (msg.sender != params.encumber.receiver) {
      require(
        _loadERC721Slot().isApprovedForAll[msg.sender][params.encumber.receiver]
      );
    }

    LienStorage storage s = _loadLienStorageSlot();

    return _buyoutLien(s, params);
  }

  function _buyoutLien(
    LienStorage storage s,
    ILienToken.LienActionBuyout calldata params
  ) internal returns (Stack[] memory, Stack memory newStack) {
    //the borrower shouldn't incur more debt from the buyout than they already owe
    (, newStack) = _createLien(s, params.encumber);
    if (
      !s.ASTARIA_ROUTER.isValidRefinance({
        newLien: params.encumber.lien,
        position: params.position,
        stack: params.encumber.stack
      })
    ) {
      revert InvalidRefinance();
    }

    if (
      s.collateralStateHash[params.encumber.lien.collateralId] ==
      bytes32("ACTIVE_AUCTION")
    ) {
      revert InvalidState(InvalidStates.COLLATERAL_AUCTION);
    }
    (uint256 owed, uint256 buyout) = _getBuyout(
      s,
      params.encumber.stack[params.position]
    );

    if (params.encumber.lien.details.maxAmount < owed) {
      revert InvalidBuyoutDetails(params.encumber.lien.details.maxAmount, owed);
    }

    s.TRANSFER_PROXY.tokenTransferFrom(
      s.WETH,
      address(msg.sender),
      _getPayee(s, params.encumber.stack[params.position].point.lienId),
      buyout
    );

    address payee = _getPayee(
      s,
      params.encumber.stack[params.position].point.lienId
    );
    if (_isPublicVault(s, payee)) {
      IPublicVault(payee).handleBuyoutLien(
        IPublicVault.BuyoutLienParams({
          lienSlope: calculateSlope(params.encumber.stack[params.position]),
          lienEnd: params.encumber.stack[params.position].point.end,
          increaseYIntercept: buyout -
            params.encumber.stack[params.position].point.amount
        })
      );
    }

    return (
      _replaceStackAtPositionWithNewLien(
        s,
        params.encumber.stack,
        params.position,
        newStack,
        params.encumber.stack[params.position].point.lienId,
        newStack.point.lienId
      ),
      newStack
    );
  }

  function _replaceStackAtPositionWithNewLien(
    LienStorage storage s,
    ILienToken.Stack[] calldata stack,
    uint256 position,
    Stack memory newLien,
    uint256 oldLienId,
    uint256 newLienId
  ) internal returns (ILienToken.Stack[] memory newStack) {
    newStack = new ILienToken.Stack[](stack.length);
    for (uint256 i = 0; i < stack.length; i++) {
      if (i == position) {
        newStack[i] = newLien;
        _burn(oldLienId);
        delete s.lienMeta[oldLienId];
      } else {
        newStack[i] = stack[i];
      }
    }
  }

  function getInterest(Stack calldata stack) public view returns (uint256) {
    LienStorage storage s = _loadLienStorageSlot();
    return _getInterest(stack, block.timestamp);
  }

  /**
   * @dev Computes the interest accrued for a lien since its last payment.
   * @param stack The Lien for the loan to calculate interest for.
   * @param timestamp The timestamp at which to compute interest for.
   */
  function _getInterest(Stack memory stack, uint256 timestamp)
    internal
    pure
    returns (uint256)
  {
    uint256 delta_t = timestamp - stack.point.last;

    return
      delta_t.mulDivDown(stack.lien.details.rate, 1).mulWadDown(
        stack.point.amount
      );
  }

  modifier validateStack(uint256 collateralId, Stack[] memory stack) {
    LienStorage storage s = _loadLienStorageSlot();
    bytes32 stateHash = s.collateralStateHash[collateralId];
    if (stateHash != bytes32(0)) {
      require(keccak256(abi.encode(stack)) == stateHash, "invalid hash");
    }
    _;
  }

  function stopLiens(
    uint256 collateralId,
    uint256 auctionWindow,
    Stack[] calldata stack,
    address liquidator
  )
    external
    validateStack(collateralId, stack)
    requiresAuth
    returns (uint256 reserve)
  {
    return
      _stopLiens(
        _loadLienStorageSlot(),
        collateralId,
        auctionWindow,
        stack,
        liquidator
      );
  }

  function _stopLiens(
    LienStorage storage s,
    uint256 collateralId,
    uint256 auctionWindow,
    Stack[] calldata stack,
    address liquidator
  ) internal returns (uint256 reserve) {
    reserve = 0;
    s.auctionData[collateralId].liquidator = liquidator;
    for (uint256 i = 0; i < stack.length; ++i) {
      AuctionStack memory auctionStack;

      auctionStack.lienId = stack[i].point.lienId;
      auctionStack.end = stack[i].point.end;
      uint88 owed;
      unchecked {
        owed = _getOwed(stack[i], block.timestamp);
        reserve += owed;
        auctionStack.amountOwed = owed;
        s.lienMeta[auctionStack.lienId].atLiquidation = true;
      }
      s.auctionData[collateralId].stack.push(auctionStack);
      address payee = _getPayee(s, auctionStack.lienId);
      if (_isPublicVault(s, payee)) {
        // update the public vault state and get the liquidation accountant back if any
        address withdrawProxyIfNearBoundary = IPublicVault(payee)
          .updateVaultAfterLiquidation(
            auctionWindow,
            IPublicVault.AfterLiquidationParams({
              lienSlope: calculateSlope(stack[i]),
              newAmount: owed,
              lienEnd: stack[i].point.end
            })
          );

        if (withdrawProxyIfNearBoundary != address(0)) {
          _setPayee(s, auctionStack.lienId, withdrawProxyIfNearBoundary);
        }
      }
    }
    s.collateralStateHash[collateralId] = bytes32("ACTIVE_AUCTION");
  }

  function tokenURI(uint256 tokenId)
    public
    pure
    override(ERC721, IERC721)
    returns (string memory)
  {
    return "";
  }

  function transferFrom(
    address from,
    address to,
    uint256 id
  ) public override(ERC721, IERC721) {
    LienStorage storage s = _loadLienStorageSlot();
    if (s.lienMeta[id].atLiquidation) {
      revert InvalidState(InvalidStates.COLLATERAL_AUCTION);
    }
    super.transferFrom(from, to, id);
  }

  function ASTARIA_ROUTER() public view returns (IAstariaRouter) {
    return _loadLienStorageSlot().ASTARIA_ROUTER;
  }

  function COLLATERAL_TOKEN() public view returns (ICollateralToken) {
    return _loadLienStorageSlot().COLLATERAL_TOKEN;
  }

  function _exists(uint256 tokenId) internal view returns (bool) {
    return _loadERC721Slot()._ownerOf[tokenId] != address(0);
  }

  function createLien(ILienToken.LienActionEncumber memory params)
    external
    requiresAuth
    validateStack(params.collateralId, params.stack)
    returns (
      uint256 lienId,
      Stack[] memory newStack,
      uint256 lienSlope
    )
  {
    LienStorage storage s = _loadLienStorageSlot();
    //0 - 4 are valid
    Stack memory newStackSlot;
    (lienId, newStackSlot) = _createLien(s, params);

    newStack = _appendStack(s, params.stack, newStackSlot);
    s.collateralStateHash[params.collateralId] = keccak256(
      abi.encode(newStack)
    );

    unchecked {
      lienSlope = calculateSlope(newStackSlot);
    }
    emit AddLien(
      params.collateralId,
      newStackSlot.point.position,
      lienId,
      newStackSlot
    );
    emit LienStackUpdated(
      params.collateralId,
      newStackSlot.point.position,
      StackAction.ADD,
      uint8(newStack.length)
    );
  }

  function _createLien(
    LienStorage storage s,
    ILienToken.LienActionEncumber memory params
  ) internal returns (uint256 newLienId, ILienToken.Stack memory newSlot) {
    if (
      s.collateralStateHash[params.collateralId] == bytes32("ACTIVE_AUCTION")
    ) {
      revert InvalidState(InvalidStates.COLLATERAL_AUCTION);
    }

    if (params.stack.length >= s.maxLiens) {
      revert InvalidState(InvalidStates.MAX_LIENS);
    }
    uint256 maxPotentialDebt = getMaxPotentialDebtForCollateral(params.stack);

    if (maxPotentialDebt > params.lien.details.maxPotentialDebt) {
      revert InvalidState(InvalidStates.DEBT_LIMIT);
    }

    unchecked {
      newLienId = uint256(keccak256(abi.encode(params.lien)));
    }
    Point memory point = Point({
      lienId: newLienId,
      amount: params.amount.safeCastTo88(),
      last: block.timestamp.safeCastTo40(),
      position: uint8(params.stack.length),
      end: (block.timestamp + params.lien.details.duration).safeCastTo40()
    });
    _mint(params.receiver, newLienId);
    return (newLienId, Stack({lien: params.lien, point: point}));
  }

  function _appendStack(
    LienStorage storage s,
    Stack[] memory stack,
    Stack memory newSlot
  ) internal view returns (Stack[] memory newStack) {
    newStack = new Stack[](stack.length + 1);
    for (uint256 i = 0; i < stack.length; ++i) {
      if (block.timestamp > stack[i].point.end) {
        revert InvalidState(InvalidStates.EXPIRED_LIEN);
      }
      newStack[i] = stack[i];
    }
    newStack[stack.length] = newSlot;
  }

  function removeLiens(
    uint256 collateralId,
    AuctionStack[] memory remainingLiens
  ) external requiresAuth {}

  event log_named_address(string, address);

  function payDebtViaClearingHouse(uint256 collateralId, uint256 payment)
    external
  {
    LienStorage storage s = _loadLienStorageSlot();
    require(msg.sender == s.COLLATERAL_TOKEN.getClearingHouse(collateralId));

    uint256 spent = _payDebt(s, collateralId, payment, msg.sender);
    delete s.collateralStateHash[collateralId];

    if (spent < payment) {
      s.TRANSFER_PROXY.tokenTransferFrom(
        s.WETH,
        msg.sender,
        s.COLLATERAL_TOKEN.ownerOf(collateralId),
        payment - spent
      );
    }
    s.COLLATERAL_TOKEN.settleAuction(collateralId);
  }

  function _payDebt(
    LienStorage storage s,
    uint256 collateralId,
    uint256 payment,
    address payer
  ) internal returns (uint256 totalSpent) {
    AuctionStack[] storage stack = s.auctionData[collateralId].stack;

    uint256 liquidatorPayment = s.ASTARIA_ROUTER.getLiquidatorFee(payment);

    s.TRANSFER_PROXY.tokenTransferFrom(
      s.WETH,
      payer,
      s.auctionData[collateralId].liquidator,
      liquidatorPayment
    );
    payment -= liquidatorPayment;
    totalSpent += liquidatorPayment;
    for (uint256 i = 0; i < stack.length; i++) {
      uint256 spent;
      unchecked {
        spent = _paymentAH(s, collateralId, stack, i, payment, payer);
        totalSpent += spent;
        payment -= spent;
      }
    }
  }

  function getAuctionData(uint256 collateralId)
    external
    view
    returns (AuctionData memory)
  {
    return _loadLienStorageSlot().auctionData[collateralId];
  }

  function getAmountOwingAtLiquidation(ILienToken.Stack calldata stack)
    public
    view
    returns (uint256)
  {
    return
      _loadLienStorageSlot()
        .auctionData[stack.lien.collateralId]
        .stack[stack.point.lienId]
        .amountOwed;
  }

  function validateLien(Lien memory lien) public view returns (uint256 lienId) {
    lienId = uint256(keccak256(abi.encode(lien)));
    if (!_exists(lienId)) {
      revert InvalidState(InvalidStates.INVALID_LIEN_ID);
    }
  }

  function getCollateralState(uint256 collateralId)
    external
    view
    returns (bytes32)
  {
    return _loadLienStorageSlot().collateralStateHash[collateralId];
  }

  function getBuyout(Stack calldata stack)
    public
    view
    returns (uint256, uint256)
  {
    LienStorage storage s = _loadLienStorageSlot();

    return _getBuyout(s, stack);
  }

  function _getBuyout(LienStorage storage s, Stack calldata stack)
    internal
    view
    returns (uint256, uint256)
  {
    uint256 remainingInterest = _getRemainingInterest(s, stack);
    uint256 owed = _getOwed(stack, block.timestamp);
    uint256 buyoutTotal = owed +
      s.ASTARIA_ROUTER.getBuyoutFee(remainingInterest);

    return (owed, buyoutTotal);
  }

  function makePayment(Stack[] calldata stack, uint256 amount)
    public
    validateStack(stack[0].lien.collateralId, stack)
    returns (Stack[] memory newStack)
  {
    LienStorage storage s = _loadLienStorageSlot();
    (newStack, ) = _makePayment(s, stack, amount);
  }

  function makePayment(
    Stack[] calldata stack,
    uint8 position,
    uint256 amount
  )
    external
    validateStack(stack[0].lien.collateralId, stack)
    returns (Stack[] memory newStack)
  {
    (newStack, ) = _payment(
      _loadLienStorageSlot(),
      stack,
      position,
      amount,
      address(msg.sender)
    );
  }

  function _paymentAH(
    LienStorage storage s,
    uint256 collateralId,
    AuctionStack[] memory stack,
    uint256 position,
    uint256 payment,
    address payer
  ) internal returns (uint256) {
    uint256 lienId = stack[position].lienId;
    uint256 end = stack[position].end;
    uint256 owing = stack[position].amountOwed;
    //checks the lien exists
    address owner = ownerOf(lienId);
    address payee = _getPayee(s, lienId);

    if (owing > payment.safeCastTo88()) {
      stack[position].amountOwed -= payment.safeCastTo88();
    } else {
      payment = owing;
    }
    s.TRANSFER_PROXY.tokenTransferFrom(s.WETH, payer, payee, payment);

    delete s.lienMeta[lienId]; //full delete
    delete stack[position];
    _burn(lienId);

    if (_isPublicVault(s, payee)) {
      if (owner == payee) {
        IPublicVault(payee).updateAfterLiquidationPayment(
          IPublicVault.LiquidationPaymentParams({lienEnd: end})
        );
      } else {
        IPublicVault(payee).decreaseEpochLienCount(stack[position].end);
      }
    }
    emit Payment(lienId, payment);
    return payment;
  }

  /**
   * @dev Have a specified payer make a payment for the debt against a CollateralToken.
   * @param stack the stack for the payment
   * @param totalCapitalAvailable The amount to pay against the debts
   */
  function _makePayment(
    LienStorage storage s,
    Stack[] calldata stack,
    uint256 totalCapitalAvailable
  ) internal returns (Stack[] memory newStack, uint256 spent) {
    uint256 amount = totalCapitalAvailable;
    for (uint256 i = 0; i < stack.length; ++i) {
      (newStack, spent) = _payment(
        s,
        stack,
        uint8(i),
        amount,
        address(msg.sender)
      );
      amount -= spent;
    }
  }

  function calculateSlope(Stack memory stack) public pure returns (uint256) {
    uint256 owedAtEnd = _getOwed(stack, stack.point.end);
    return
      (owedAtEnd - stack.point.amount).mulDivDown(
        1,
        stack.point.end - stack.point.last
      );
  }

  function getMaxPotentialDebtForCollateral(Stack[] memory stack)
    public
    pure
    returns (uint256 maxPotentialDebt)
  {
    maxPotentialDebt = 0;
    for (uint256 i = 0; i < stack.length; ++i) {
      maxPotentialDebt += _getOwed(stack[i], stack[i].point.end);
    }
  }

  function getMaxPotentialDebtForCollateral(Stack[] memory stack, uint256 end)
    public
    pure
    returns (uint256 maxPotentialDebt)
  {
    maxPotentialDebt = 0;
    for (uint256 i = 0; i < stack.length; ++i) {
      maxPotentialDebt += _getOwed(stack[i], end);
    }
  }

  function getOwed(Stack memory stack) external view returns (uint192) {
    return _getOwed(stack, block.timestamp);
  }

  function getOwed(Stack memory stack, uint256 timestamp)
    external
    view
    returns (uint192)
  {
    uint256 lienId = validateLien(stack.lien);
    return _getOwed(stack, timestamp);
  }

  /**
   * @dev Computes the debt owed to a Lien at a specified timestamp.
   * @param stack The specified Lien.
   * @return The amount owed to the Lien at the specified timestamp.
   */
  function _getOwed(Stack memory stack, uint256 timestamp)
    internal
    pure
    returns (uint88)
  {
    return stack.point.amount + _getInterest(stack, timestamp).safeCastTo88();
  }

  /**
   * @dev Computes the interest still owed to a Lien.
   * @param s active storage slot
   * @param stack the lien
   * @return The WETH still owed in interest to the Lien.
   */
  function _getRemainingInterest(LienStorage storage s, Stack memory stack)
    internal
    view
    returns (uint256)
  {
    uint256 end = stack.point.end;

    uint256 delta_t = end - block.timestamp;

    return
      delta_t.mulDivDown(stack.lien.details.rate, 1).mulWadDown(
        stack.point.amount
      );
  }

  /**
   * @dev Make a payment from a payer to a specific lien against a CollateralToken.
   * @param activeStack The stack
   * @param amount The amount to pay against the debt.
   * @param payer The address to make the payment.
   */
  function _payment(
    LienStorage storage s,
    Stack[] memory activeStack,
    uint8 position,
    uint256 amount,
    address payer
  ) internal returns (Stack[] memory, uint256) {
    Stack memory stack = activeStack[position];
    uint256 lienId = stack.point.lienId;

    if (s.lienMeta[lienId].atLiquidation) {
      revert InvalidState(InvalidStates.COLLATERAL_AUCTION);
    }
    // Blocking off payments for a lien that has exceeded the lien.end to prevent repayment unless the msg.sender() is the AuctionHouse
    if (block.timestamp > activeStack[position].point.end) {
      revert InvalidLoanState();
    }
    uint256 owed = _getOwed(activeStack[position], block.timestamp);

    address lienOwner = ownerOf(lienId);
    bool isPublicVault = _isPublicVault(s, lienOwner);

    address payee = _getPayee(s, lienId);

    if (amount > owed) amount = owed;
    if (isPublicVault) {
      IPublicVault(lienOwner).beforePayment(
        IPublicVault.BeforePaymentParams({
          interestOwed: owed - stack.point.amount,
          amount: stack.point.amount,
          lienSlope: calculateSlope(stack)
        })
      );
    }

    //bring the point up to block.timestamp, compute the owed
    stack.point.amount = owed.safeCastTo88();
    stack.point.last = block.timestamp.safeCastTo40();

    if (stack.point.amount > amount) {
      stack.point.amount -= amount.safeCastTo88();
      //      // slope does not need to be updated if paying off the rest, since we neutralize slope in beforePayment()
      if (isPublicVault) {
        IPublicVault(lienOwner).afterPayment(calculateSlope(stack));
      }
    } else {
      amount = stack.point.amount;
      if (isPublicVault) {
        // since the openLiens count is only positive when there are liens that haven't been paid off
        // that should be liquidated, this lien should not be counted anymore
        IPublicVault(lienOwner).decreaseEpochLienCount(
          IPublicVault(lienOwner).getLienEpoch(stack.point.end)
        );
      }
      delete s.lienMeta[lienId]; //full delete of point data for the lien
      _burn(lienId);
      activeStack = _removeStackPosition(activeStack, position);
    }
    if (activeStack.length == 0) {
      delete s.collateralStateHash[stack.lien.collateralId];
    } else {
      s.collateralStateHash[stack.lien.collateralId] = keccak256(
        abi.encode(activeStack)
      );
    }

    s.TRANSFER_PROXY.tokenTransferFrom(s.WETH, payer, payee, amount);

    emit Payment(lienId, amount);
    return (activeStack, amount);
  }

  function _removeStackPosition(Stack[] memory stack, uint8 position)
    internal
    returns (Stack[] memory newStack)
  {
    require(position < stack.length);
    uint256 collateralId = stack[position].lien.collateralId;

    newStack = new ILienToken.Stack[](stack.length - 1);
    for (uint256 i = 0; i < stack.length; i++) {
      if (i == position) continue;
      newStack[i] = stack[i];
    }
    emit LienStackUpdated(
      collateralId,
      position,
      StackAction.REMOVE,
      uint8(newStack.length)
    );
  }

  function _isPublicVault(LienStorage storage s, address account)
    internal
    view
    returns (bool)
  {
    return
      s.ASTARIA_ROUTER.isValidVault(account) &&
      IPublicVault(account).supportsInterface(type(IPublicVault).interfaceId);
  }

  function getPayee(uint256 lienId) public view returns (address) {
    LienStorage storage s = _loadLienStorageSlot();
    if (!_exists(lienId)) {
      revert InvalidState(InvalidStates.INVALID_LIEN_ID);
    }
    return _getPayee(s, lienId);
  }

  function _getPayee(LienStorage storage s, uint256 lienId)
    internal
    view
    returns (address)
  {
    return
      s.lienMeta[lienId].payee != address(0)
        ? s.lienMeta[lienId].payee
        : ownerOf(lienId);
  }

  function setPayee(Lien calldata lien, address newPayee) public {
    LienStorage storage s = _loadLienStorageSlot();
    uint256 lienId = validateLien(lien);
    require(
      msg.sender == ownerOf(lienId) || msg.sender == address(s.ASTARIA_ROUTER)
    );
    if (s.lienMeta[lienId].atLiquidation) {
      revert InvalidState(InvalidStates.COLLATERAL_AUCTION);
    }
    _setPayee(s, lienId, newPayee);
  }

  function _setPayee(
    LienStorage storage s,
    uint256 lienId,
    address newPayee
  ) internal {
    s.lienMeta[lienId].payee = newPayee;
    emit PayeeChanged(lienId, newPayee);
  }
}
