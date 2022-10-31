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
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {IERC721} from "core/interfaces/IERC721.sol";
import {IERC165} from "core/interfaces/IERC165.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {Base64} from "./libraries/Base64.sol";
import {CollateralLookup} from "core/libraries/CollateralLookup.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";

import {IPublicVault} from "core/interfaces/IPublicVault.sol";
import {VaultImplementation} from "./VaultImplementation.sol";
import "./interfaces/ICollateralToken.sol";
import "./interfaces/IAstariaRouter.sol";

/**
 * @title LienToken
 * @notice This contract handles the creation, payments, buyouts, and liquidations of tokenized NFT-collateralized debt (liens). Vaults which originate loans against supported collateral are issued a LienToken representing the right to loan repayments and auctioned funds on liquidation.
 */
contract LienToken is ERC721, ILienToken, Auth {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeCastLib for uint256;

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
    s.maxLiens = uint256(5);
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

  function file(bytes32 what, bytes calldata data) external requiresAuth {
    LienStorage storage s = _loadLienStorageSlot();
    if (what == "setAuctionHouse") {
      address addr = abi.decode(data, (address));
      s.AUCTION_HOUSE = IAuctionHouse(addr);
    } else if (what == "setCollateralToken") {
      address addr = abi.decode(data, (address));
      s.COLLATERAL_TOKEN = ICollateralToken(addr);
    } else if (what == "setAstariaRouter") {
      address addr = abi.decode(data, (address));
      s.ASTARIA_ROUTER = IAstariaRouter(addr);
    } else {
      revert UnsupportedFile();
    }
    emit File(what, data);
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

  //  function buyoutLien(ILienToken.LienActionBuyout calldata params)
  //    external
  //    returns (Stack[] memory newStack)
  //  {
  //    if (msg.sender != params.receiver) {
  //      require(_loadERC721Slot().isApprovedForAll[msg.sender][params.receiver]);
  //    }
  //    uint256 outgoingLienId;
  //
  //    for (uint256 i = 0; i < params.stack.length; ++i) {
  //      uint256 lienId = validateLien(params.stack[i]);
  //      require(i == params.stack[i].position);
  //      if (i == params.stack[i].position) {
  //        outgoingLienId = lienId;
  //      }
  //    }
  //    LienStorage storage s = _loadLienStorageSlot();
  //
  //    ILienToken.Details memory details = s.ASTARIA_ROUTER.validateCommitment(
  //      params.incoming
  //    );
  //
  //    {
  //      (uint256 owed, uint256 buyout) = getBuyout(params.stack[params.position]);
  //
  //      //the borrower shouldn't incur more debt from the buyout than they already owe
  //      if (details.maxAmount < owed) {
  //        revert InvalidBuyoutDetails(details.maxAmount, owed);
  //      }
  //
  //      (uint256 newLienId, Lien memory newLien) = _createLien(
  //        s,
  //        ILienToken.LienActionEncumber({
  //          collateralId: params.incoming.tokenContract.computeId(
  //            params.incoming.tokenId
  //          ),
  //          terms: details,
  //          strategyRoot: params.incoming.lienRequest.merkle.root,
  //          amount: owed,
  //          vault: address(msg.sender),
  //          stack: params.stack
  //        })
  //      );
  //
  //      s.TRANSFER_PROXY.tokenTransferFrom(
  //        s.WETH,
  //        address(msg.sender),
  //        getPayee(outgoingLienId),
  //        buyout
  //      );
  //      newStack = _replaceStackAtPositionWithNewLien(
  //        s,
  //        owed,
  //        params.stack,
  //        params.position,
  //        newLien,
  //        outgoingLienId,
  //        newLienId
  //      );
  //
  //      if (!s.ASTARIA_ROUTER.isValidRefinance(newLien, params.stack)) {
  //        revert InvalidRefinance();
  //      }
  //    }
  //
  //    //_burn original lien
  //    _burn(outgoingLienId);
  //    delete s.amountAtLiquidation[outgoingLienId];
  //  }

  //  function _replaceStackAtPositionWithNewLien(
  //    LienStorage storage s,
  //    uint256 amount,
  //    ILienToken.Stack[] calldata stack,
  //    uint256 position,
  //    Lien memory lien,
  //    uint256 oldLienId,
  //    uint256 newLienId
  //  ) internal returns (ILienToken.Stack[] memory) {
  //    ILienToken.Stack[] memory newStack = new ILienToken.Stack[](stack.length);
  //    for (uint256 i = 0; i < stack.length; i++) {
  //      if (i == position) {
  //        newStack[i] = lien;
  //        _burn(oldLienId);
  //        delete s.amountAtLiquidation[oldLienId];
  //      } else {
  //        newStack[i] = stack[i];
  //      }
  //    }
  //    return newStack;
  //  }
  //
  function getInterest(Stack memory stack) public view returns (uint256) {
    LienStorage storage s = _loadLienStorageSlot();
    return _getInterest(s, stack, block.timestamp);
  }

  /**
   * @dev Computes the interest accrued for a lien since its last payment.
   * @param stack The Lien for the loan to calculate interest for.
   * @param timestamp The timestamp at which to compute interest for.
   */
  function _getInterest(
    LienStorage storage s,
    Stack memory stack,
    uint256 timestamp
  ) internal view returns (uint256) {
    uint256 delta_t = timestamp - stack.point.last;

    LienStorage storage s = _loadLienStorageSlot();
    if (s.amountAtLiquidation[stack.point.lienId] > 0) {
      return uint256(0);
    }
    return
      delta_t.mulDivDown(stack.lien.details.rate, 1).mulWadDown(
        stack.point.amount
      );
  }

  modifier validateStack(uint256 collateralId, Stack[] calldata stack) {
    LienStorage storage s = _loadLienStorageSlot();
    bytes32 stateHash = s.collateralStateHash[collateralId];
    if (stateHash != bytes32(0)) {
      require(keccak256(abi.encode(stack)) == stateHash, "invalid hash");
    }
    _;
  }
  modifier validateAuctionStack(uint256 collateralId, uint256[] memory stack) {
    LienStorage storage s = _loadLienStorageSlot();
    bytes32 stateHash = s.collateralStateHash[collateralId];
    if (stateHash != bytes32(0)) {
      require(keccak256(abi.encode(stack)) == stateHash, "invalid hash");
    }
    _;
  }

  function stopLiens(uint256 collateralId, Stack[] memory stack)
    external
    requiresAuth
    returns (uint256 reserve, Stack[] memory)
  {
    LienStorage storage s = _loadLienStorageSlot();

    reserve = 0;
    uint256[] memory lienIds = new uint256[](stack.length);
    for (uint256 i = 0; i < stack.length; ++i) {
      uint256 owed;
      unchecked {
        stack[i].point.amount = _getOwed(stack[i], block.timestamp);
        reserve += stack[i].point.amount;
      }
      stack[i].point.last = block.timestamp.safeCastTo40();
      lienIds[i] = stack[i].point.lienId;
      s.amountAtLiquidation[stack[i].point.lienId] = stack[i].point.amount;
    }

    s.collateralStateHash[collateralId] = keccak256(abi.encode(lienIds));
    return (reserve, stack);
  }

  event log_named_uint(string, uint256);

  function tokenURI(uint256 tokenId)
    public
    pure
    override(ERC721, IERC721)
    returns (string memory)
  {
    return "";
  }

  function AUCTION_HOUSE() public view returns (IAuctionHouse) {
    return _loadLienStorageSlot().AUCTION_HOUSE;
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

  function createLien(ILienToken.LienActionEncumber calldata params)
    external
    requiresAuth
    validateStack(params.collateralId, params.stack)
    returns (uint256 lienId, Stack[] memory newStack)
  {
    LienStorage storage s = _loadLienStorageSlot();
    //0 - 4 are valid

    Stack memory newStackSlot;
    (lienId, newStackSlot) = _createLien(s, params);

    newStack = _appendStack(s, params.stack, newStackSlot);
    s.collateralStateHash[params.collateralId] = keccak256(
      abi.encode(newStack)
    );

    emit LienStackUpdated(params.collateralId, newStack);
  }

  function _createLien(
    LienStorage storage s,
    ILienToken.LienActionEncumber calldata params
  ) internal returns (uint256 newLienId, ILienToken.Stack memory newSlot) {
    if (params.stack.length >= s.maxLiens) {
      revert InvalidState(InvalidStates.MAX_LIENS);
    }
    uint256 maxPotentialDebt = getMaxPotentialDebtForCollateral(params.stack);

    if (maxPotentialDebt > params.terms.maxPotentialDebt) {
      revert InvalidState(InvalidStates.DEBT_LIMIT);
    }

    Lien memory newLien = Lien({
      collateralId: params.collateralId,
      vault: params.vault,
      token: s.WETH,
      position: uint8(params.stack.length),
      strategyRoot: params.strategyRoot,
      end: uint256(block.timestamp + params.terms.duration).safeCastTo40(),
      details: params.terms
    });

    unchecked {
      newLienId = uint256(keccak256(abi.encode(newLien)));
    }
    Point memory point = Point({
      lienId: newLienId,
      amount: params.amount.safeCastTo192(),
      last: block.timestamp.safeCastTo40()
    });
    //todo factor recipient into an earlier where state is hot to call to save the lookup
    _mint(VaultImplementation(params.vault).recipient(), newLienId);
    return (newLienId, Stack({lien: newLien, point: point}));
  }

  function _appendStack(
    LienStorage storage s,
    Stack[] calldata stack,
    Stack memory newSlot
  ) internal pure returns (Stack[] memory newStack) {
    newStack = new Stack[](stack.length + 1);
    for (uint256 i = 0; i < stack.length; ++i) {
      newStack[i] = stack[i];
    }
    newStack[stack.length] = newSlot;
  }

  function removeLiens(uint256 collateralId, uint256[] memory remainingLiens)
    external
    requiresAuth
  {
    LienStorage storage s = _loadLienStorageSlot();
    for (uint256 i = 0; i < remainingLiens.length; i++) {
      address owner = ownerOf(remainingLiens[i]);
      if (
        IPublicVault(owner).supportsInterface(type(IPublicVault).interfaceId)
      ) {
        IPublicVault(owner).decreaseYIntercept(
          s.amountAtLiquidation[remainingLiens[i]]
        );
      }

      delete s.amountAtLiquidation[remainingLiens[i]];
      _burn(remainingLiens[i]); //burn the underlying lien associated
    }
    delete s.collateralStateHash[collateralId];
    emit RemovedLiens(collateralId);
  }

  function getAmountOwingAtLiquidation(uint256 lienId)
    external
    view
    returns (uint256)
  {
    return _loadLienStorageSlot().amountAtLiquidation[lienId];
  }

  function getAmountOwingAtLiquidation(ILienToken.Stack calldata stack)
    public
    view
    returns (uint256)
  {
    return
      _loadLienStorageSlot().amountAtLiquidation[
        uint256(keccak256(abi.encode(stack.lien)))
      ];
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

    //    if (lien.amount == 0) {
    //      revert InvalidState(InvalidStates.LIEN_NO_DEBT);
    //    }
    //validate lien presented

    uint256 remainingInterest = _getRemainingInterest(s, stack, true);
    uint256 buyoutTotal = stack.point.amount +
      s.ASTARIA_ROUTER.getBuyoutFee(remainingInterest);

    return (_getOwed(stack, block.timestamp), buyoutTotal);
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

  function makePaymentAuctionHouse(
    uint256[] memory stack,
    uint256 collateralId,
    uint256 payment,
    address payer
  )
    external
    validateAuctionStack(collateralId, stack)
    requiresAuth
    returns (uint256[] memory newStack, uint256 spent)
  {
    LienStorage storage s = _loadLienStorageSlot();
    for (uint256 i = 0; i < stack.length; i++) {
      (newStack, spent) = _paymentAH(s, stack, collateralId, payment, payer);
    }
    if (newStack.length != 0) {
      s.collateralStateHash[collateralId] = keccak256(abi.encode(newStack));
    } else {
      s.collateralStateHash[collateralId] = bytes32(0);
    }
  }

  function _paymentAH(
    LienStorage storage s,
    uint256[] memory stack,
    uint256 collateralId,
    uint256 payment,
    address payer
  ) internal returns (uint256[] memory newStack, uint256) {
    uint256 lienId = stack[0];
    //checks the lien exists
    address payee = getPayee(lienId);

    if (s.amountAtLiquidation[lienId] > payment) {
      s.amountAtLiquidation[lienId] -= payment;
      newStack = stack;
    } else {
      payment = s.amountAtLiquidation[lienId];
      delete s.amountAtLiquidation[lienId]; //full delete
      _burn(lienId);
      newStack = new uint256[](stack.length - 1);
      for (uint256 i = 1; i < stack.length; i++) {
        newStack[i] = stack[i];
      }
    }

    s.TRANSFER_PROXY.tokenTransferFrom(s.WETH, payer, payee, payment);

    emit Payment(lienId, payment);
    return (newStack, payment);
  }

  /**

   * @notice Have a specified payer make a payment for the debt against a CollateralToken.
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

  //  function makePayment(
  //    Stack[] memory stack,
  //    uint8 position,
  //    uint256 paymentAmount,
  //    address payer
  //  ) public requiresAuth {
  //    _payment(_loadLienStorageSlot(), stack, paymentAmount, payer);
  //  }

  function calculateSlope(Stack memory stack) public view returns (uint256) {
    LienStorage storage s = _loadLienStorageSlot();

    uint256 owedAtEnd = _getOwed(stack, stack.lien.end);
    return
      (owedAtEnd - stack.point.amount).mulDivDown(
        1,
        stack.lien.end - stack.point.last
      );
  }

  /**
   * @notice Computes the total amount owed on all liens against a CollateralToken.
   * @return maxPotentialDebt the total possible debt for the collateral
   */
  function getMaxPotentialDebtForCollateral(Stack[] calldata stack)
    public
    view
    returns (uint256 maxPotentialDebt)
  {
    maxPotentialDebt = 0;
    for (uint256 i = 0; i < stack.length; ++i) {
      maxPotentialDebt += _getOwed(stack[i], stack[i].lien.end);
    }
  }

  //  function getAccruedSinceLastPayment(Lien calldata lien)
  //    external
  //    view
  //    returns (uint256)
  //  {
  //    LienStorage storage s = _loadLienStorageSlot();
  //    uint256 lienId = validateLien(lien);
  //    LienDataPoint memory point = s.amountAtLiquidation[lienId];
  //    return _getOwed(lien, bll);
  //  }

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
    view
    returns (uint192)
  {
    LienStorage storage s = _loadLienStorageSlot();
    return
      stack.point.amount + _getInterest(s, stack, timestamp).safeCastTo192();
  }

  /**
   * @dev Computes the interest still owed to a Lien.
   * @param s active storage slot
   * @param stack the lien
   * @param buyout compute with a ceiling based on the buyout interest window
   * @return The WETH still owed in interest to the Lien.
   */
  function _getRemainingInterest(
    LienStorage storage s,
    Stack memory stack,
    bool buyout
  ) internal view returns (uint256) {
    uint256 end = stack.lien.end;
    if (buyout) {
      uint32 buyoutInterestWindow = s.ASTARIA_ROUTER.getBuyoutInterestWindow();
      if (end >= block.timestamp + buyoutInterestWindow) {
        end = block.timestamp + buyoutInterestWindow;
      }
    }

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
    //    LienDataPoint storage point = s.amountAtLiquidation[lienId];
    // Blocking off payments for a lien that has exceeded the lien.end to prevent repayment unless the msg.sender() is the AuctionHouse
    if (block.timestamp > activeStack[position].lien.end) {
      revert InvalidLoanState();
    }
    uint256 owed = _getOwed(activeStack[position], block.timestamp);
    Stack memory stack = activeStack[position];
    uint256 lienId = stack.point.lienId;

    address lienOwner = ownerOf(lienId);
    bool isPublicVault = _isPublicVault(lienOwner);

    address payee = getPayee(lienId);

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
    stack.point.amount = owed.safeCastTo192();
    stack.point.last = block.timestamp.safeCastTo40();

    if (stack.point.amount > amount) {
      stack.point.amount -= amount.safeCastTo192();
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
          IPublicVault(lienOwner).getLienEpoch(stack.lien.end)
        );
      }
      delete s.amountAtLiquidation[lienId]; //full delete of point data for the lien
      _burn(lienId);
      activeStack = _removeStackPosition(activeStack, position);
    }
    if (activeStack.length == 0) {
      s.collateralStateHash[stack.lien.collateralId] = bytes32(0);
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
    emit RemovedLien(collateralId, position);
    emit LienStackUpdated(collateralId, newStack);
  }

  //  function _deleteLienPosition(
  //    LienStorage storage s,
  //    uint256 collateralId,
  //    uint256 position
  //  ) internal {
  //    uint256[] storage stack = s.liens[collateralId];
  //    require(position < stack.length);
  //
  //    emit RemoveLien(stack[position], collateralId, uint8(position));
  //    for (uint256 i = position; i < stack.length - 1; i++) {
  //      stack[i] = stack[i + 1];
  //    }
  //    stack.pop();
  //  }

  function _isPublicVault(address account) internal view returns (bool) {
    return
      IPublicVault(account).supportsInterface(type(IPublicVault).interfaceId);
  }

  function getPayee(uint256 lienId) public view returns (address) {
    LienStorage storage s = _loadLienStorageSlot();

    return s.payee[lienId] != address(0) ? s.payee[lienId] : ownerOf(lienId);
  }

  function setPayee(Lien calldata lien, address newPayee) public {
    LienStorage storage s = _loadLienStorageSlot();
    uint256 lienId = validateLien(lien);
    require(
      msg.sender == ownerOf(lienId) || msg.sender == address(s.ASTARIA_ROUTER)
    );
    if (s.AUCTION_HOUSE.auctionExists(lien.collateralId)) {
      revert InvalidState(InvalidStates.COLLATERAL_AUCTION);
    }

    s.payee[lienId] = newPayee;
    emit PayeeChanged(lienId, newPayee);
  }
}
