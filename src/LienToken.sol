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
  //    returns (Lien[] memory newStack)
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

  function _replaceStackAtPositionWithNewLien(
    LienStorage storage s,
    uint256 amount,
    ILienToken.Lien[] calldata stack,
    uint256 position,
    Lien memory lien,
    uint256 oldLienId,
    uint256 newLienId
  ) internal returns (ILienToken.Lien[] memory) {
    ILienToken.Lien[] memory newStack = new ILienToken.Lien[](stack.length);
    for (uint256 i = 0; i < stack.length; i++) {
      if (i == position) {
        newStack[i] = lien;
        _burn(oldLienId);
        delete s.amountAtLiquidation[oldLienId];
        //        s.amountAtLiquidation[newLienId] = LienDataPoint({
        //          amount: amount.safeCastTo192(),
        //          last: block.timestamp.safeCastTo40(),
        //          active: true
        //        });
      } else {
        newStack[i] = stack[i];
      }
    }
    return newStack;
  }

  function getInterest(Lien memory lien) public view returns (uint256) {
    LienStorage storage s = _loadLienStorageSlot();
    if (s.amountAtLiquidation[uint256(keccak256(abi.encode(lien)))] > 0) {
      return uint256(0);
    }
    return _getInterest(lien, block.timestamp);
  }

  /**
   * @dev Computes the interest accrued for a lien since its last payment.
   * @param lien The Lien for the loan to calculate interest for.
   * @param timestamp The timestamp at which to compute interest for.
   */
  function _getInterest(Lien memory lien, uint256 timestamp)
    internal
    pure
    returns (uint256)
  {
    uint256 delta_t = timestamp - lien.start;

    return delta_t.mulDivDown(lien.details.rate, 1).mulWadDown(lien.amount);
  }

  function stopLiens(uint256 collateralId, Lien[] memory stack)
    external
    requiresAuth
    returns (uint256 reserve)
  {
    LienStorage storage s = _loadLienStorageSlot();

    reserve = 0;
    for (uint256 i = 0; i < stack.length; ++i) {
      uint256 lienId = validateLien(stack[i]);
      //valdation position always matches index
      require(i == stack[i].position);

      unchecked {
        stack[i].amount = _getOwed(stack[i]);
        reserve += stack[i].amount;
      }
      s.amountAtLiquidation[lienId] = stack[i].amount;

      //      point.last = block.timestamp.safeCastTo40();
      //      point.active = false;
    }
  }

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
    returns (uint256 lienId, Lien[] memory newStack)
  {
    LienStorage storage s = _loadLienStorageSlot();
    //0 - 4 are valid
    for (uint256 i = 0; i < params.stack.length; ++i) {
      validateLien(params.stack[i]);
      require(i == params.stack[i].position);
    }
    Lien memory newLien;
    (lienId, newLien) = _createLien(s, params);
    newStack = _appendStack(s, params.stack, newLien);
    s.collateralStateHash[params.collateralId] = keccak256(
      abi.encode(newStack)
    );

    emit LienStackUpdated(params.collateralId, newStack);
  }

  function _createLien(
    LienStorage storage s,
    ILienToken.LienActionEncumber memory params
  ) internal returns (uint256 newLienId, ILienToken.Lien memory newLien) {
    if (params.stack.length >= s.maxLiens) {
      revert InvalidState(InvalidStates.MAX_LIENS);
    }
    uint256 maxPotentialDebt = getMaxPotentialDebtForCollateral(params.stack);

    if (maxPotentialDebt > params.terms.maxPotentialDebt) {
      revert InvalidState(InvalidStates.DEBT_LIMIT);
    }

    newLien = Lien({
      collateralId: params.collateralId,
      vault: params.vault,
      token: s.WETH,
      amount: params.amount.safeCastTo192(),
      position: uint8(params.stack.length),
      strategyRoot: params.strategyRoot,
      start: block.timestamp.safeCastTo40(),
      end: uint256(block.timestamp + params.terms.duration).safeCastTo40(),
      details: params.terms
    });
    unchecked {
      newLienId = uint256(keccak256(abi.encode(newLien)));
    }
    _mint(VaultImplementation(params.vault).recipient(), newLienId);
  }

  function _appendStack(
    LienStorage storage s,
    Lien[] calldata stack,
    Lien memory newLien
  ) internal pure returns (Lien[] memory newStack) {
    newStack = new Lien[](stack.length + 1);
    for (uint256 i = 0; i < stack.length; ++i) {
      newStack[i] = stack[i];
    }
    newStack[stack.length] = newLien;
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

  function getAmountOwingAtLiquidation(ILienToken.Lien calldata lien)
    public
    view
    returns (uint256)
  {
    return
      _loadLienStorageSlot().amountAtLiquidation[
        uint256(keccak256(abi.encode(lien)))
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

  function getBuyout(Lien calldata lien)
    public
    view
    returns (uint256, uint256)
  {
    LienStorage storage s = _loadLienStorageSlot();

    //    if (lien.amount == 0) {
    //      revert InvalidState(InvalidStates.LIEN_NO_DEBT);
    //    }
    //validate lien presented

    uint256 remainingInterest = _getRemainingInterest(s, lien, true);
    uint256 buyoutTotal = lien.amount +
      s.ASTARIA_ROUTER.getBuyoutFee(remainingInterest);

    return (_getOwed(lien), buyoutTotal);
  }

  function makePayment(Lien[] memory stack, uint256 amount) public {
    for (uint256 i = 0; i < stack.length; ++i) {
      validateLien(stack[i]);
      require(i == stack[i].position);
    }
    _makePayment(stack, amount);
  }

  function makePayment(
    Lien[] memory stack,
    uint8 position,
    uint256 amount
  ) external {
    _payment(
      _loadLienStorageSlot(),
      stack,
      position,
      amount,
      address(msg.sender)
    );
  }

  function makePaymentAuctionHouse(
    uint256 lienId,
    uint256 collateralId,
    uint256 amount,
    address payer,
    uint256[] memory currentStack
  ) external requiresAuth returns (uint256) {
    LienStorage storage s = _loadLienStorageSlot();
    if (amount == uint256(0)) {
      return uint256(0);
    }

    if (!_exists(lienId)) {
      revert InvalidState(InvalidStates.INVALID_LIEN_ID);
    }

    address lienOwner = ownerOf(lienId);

    address payee = getPayee(lienId);

    if (s.amountAtLiquidation[lienId] > amount) {
      s.amountAtLiquidation[lienId] -= amount.safeCastTo192();
      amount = amount;
      // slope does not need to be updated if paying off the rest, since we neutralize slope in beforePayment()
    } else {
      amount = s.amountAtLiquidation[lienId];
      delete s.amountAtLiquidation[lienId]; //full delete
      _burn(lienId);
    }

    s.TRANSFER_PROXY.tokenTransferFrom(s.WETH, payer, payee, amount);

    emit Payment(lienId, amount);
    return amount;
  }

  /**

   * @notice Have a specified payer make a payment for the debt against a CollateralToken.
   * @param stack the stack for the payment
   * @param totalCapitalAvailable The amount to pay against the debts
   */
  function _makePayment(Lien[] memory stack, uint256 totalCapitalAvailable)
    internal
  {
    LienStorage storage s = _loadLienStorageSlot();
    uint256 amount = totalCapitalAvailable;
    for (uint256 i = 0; i < stack.length; ++i) {
      validateLien(stack[i]);
      require(i == stack[i].position);
      uint256 capitalSpent = _payment(
        s,
        stack,
        uint8(i),
        amount,
        address(msg.sender)
      );
      amount -= capitalSpent;
    }
  }

  //  function makePayment(
  //    Lien[] memory stack,
  //    uint8 position,
  //    uint256 paymentAmount,
  //    address payer
  //  ) public requiresAuth {
  //    _payment(_loadLienStorageSlot(), stack, paymentAmount, payer);
  //  }

  function calculateSlope(Lien memory lien) public view returns (uint256) {
    uint256 lienId = validateLien(lien);

    LienStorage storage s = _loadLienStorageSlot();

    uint256 owedAtEnd = _getOwed(lien, lien.end);
    return (owedAtEnd - lien.amount).mulDivDown(1, lien.end - block.timestamp);
  }

  /**
   * @notice Computes the total amount owed on all liens against a CollateralToken.
   * @return maxPotentialDebt the total possible debt for the collateral
   */
  function getMaxPotentialDebtForCollateral(Lien[] memory stack)
    public
    view
    returns (uint256 maxPotentialDebt)
  {
    maxPotentialDebt = 0;
    for (uint256 i = 0; i < stack.length; ++i) {
      maxPotentialDebt += _getOwed(stack[i], stack[i].end);
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

  function getOwed(Lien memory lien) external view returns (uint192) {
    return _getOwed(lien);
  }

  function getOwed(Lien memory lien, uint256 timestamp)
    external
    view
    returns (uint192)
  {
    uint256 lienId = validateLien(lien);
    return _getOwed(lien, timestamp);
  }

  function _getOwed(Lien memory lien) internal view returns (uint192) {
    return _getOwed(lien, block.timestamp);
  }

  /**
   * @dev Computes the debt owed to a Lien at a specified timestamp.
   * @param lien The specified Lien.
   * @return The amount owed to the Lien at the specified timestamp.
   */
  function _getOwed(Lien memory lien, uint256 timestamp)
    internal
    pure
    returns (uint192)
  {
    return lien.amount + _getInterest(lien, timestamp).safeCastTo192();
  }

  /**
   * @dev Computes the interest still owed to a Lien.
   * @param s active storage slot
   * @param lien the lien
   * @param buyout compute with a ceiling based on the buyout interest window
   * @return The WETH still owed in interest to the Lien.
   */
  function _getRemainingInterest(
    LienStorage storage s,
    Lien memory lien,
    bool buyout
  ) internal view returns (uint256) {
    uint256 end = lien.end;
    if (buyout) {
      uint32 buyoutInterestWindow = s.ASTARIA_ROUTER.getBuyoutInterestWindow();
      if (end >= block.timestamp + buyoutInterestWindow) {
        end = block.timestamp + buyoutInterestWindow;
      }
    }

    uint256 delta_t = end - block.timestamp;

    return delta_t.mulDivDown(lien.details.rate, 1).mulWadDown(_getOwed(lien));
  }

  /**
   * @dev Make a payment from a payer to a specific lien against a CollateralToken.
   * @param stack The stack
   * @param amount The amount to pay against the debt.
   * @param payer The address to make the payment.
   * @return amountSpent The amount actually spent for the payment.
   */
  function _payment(
    LienStorage storage s,
    Lien[] memory stack,
    uint8 position,
    uint256 amount,
    address payer
  ) internal returns (uint256) {
    if (amount == uint256(0)) {
      return uint256(0);
    }

    Lien memory lien = stack[position];
    uint256 lienId = validateLien(lien);

    //    LienDataPoint storage point = s.amountAtLiquidation[lienId];
    // Blocking off payments for a lien that has exceeded the lien.end to prevent repayment unless the msg.sender() is the AuctionHouse
    if (block.timestamp > lien.end) {
      revert InvalidLoanState();
    }

    address lienOwner = ownerOf(lienId);
    bool isPublicVault = _isPublicVault(lienOwner);

    address payee = getPayee(lienId);
    uint256 owed = _getOwed(lien);

    if (amount > owed) amount = owed;
    if (isPublicVault) {
      IPublicVault(lienOwner).beforePayment(
        IPublicVault.BeforePaymentParams({
          interestOwed: owed - lien.amount,
          amount: lien.amount,
          lienSlope: calculateSlope(lien)
        })
      );
    }
    lien.amount = owed.safeCastTo192();
    //    point.last = block.timestamp.safeCastTo40();
    if (lien.amount > amount) {
      //      point.amount -= amount.safeCastTo192();
      //      // slope does not need to be updated if paying off the rest, since we neutralize slope in beforePayment()
      //      if (isPublicVault) {
      //        IPublicVault(lienOwner).afterPayment(calculateSlope(lien));
      //      }
      revert("must pay in full");
    } else {
      amount = lien.amount;
      if (isPublicVault) {
        // since the openLiens count is only positive when there are liens that haven't been paid off
        // that should be liquidated, this lien should not be counted anymore
        IPublicVault(lienOwner).decreaseEpochLienCount(
          IPublicVault(lienOwner).getLienEpoch(lien.end)
        );
      }
      delete s.amountAtLiquidation[lienId]; //full delete of point data for the lien
      _removeStackPosition(stack, position);
      _burn(lienId);
    }

    s.TRANSFER_PROXY.tokenTransferFrom(s.WETH, payer, payee, amount);

    emit Payment(lienId, amount);
    return amount;
  }

  function _removeStackPosition(Lien[] memory stack, uint8 position)
    internal
    returns (Lien[] memory newStack)
  {
    require(position < stack.length);
    uint256 collateralId = stack[position].collateralId;

    newStack = new ILienToken.Lien[](stack.length - 1);
    for (uint256 i = 0; i < stack.length; i++) {
      if (i == position) continue;
      newStack[i] = stack[i];
    }
    emit RemovedLien(collateralId, position);
    emit LienStackUpdated(collateralId, stack);
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
    if (s.AUCTION_HOUSE.auctionExists(lien.collateralId)) {
      revert InvalidState(InvalidStates.COLLATERAL_AUCTION);
    }

    require(
      msg.sender == ownerOf(lienId) || msg.sender == address(s.ASTARIA_ROUTER)
    );

    s.payee[lienId] = newPayee;
    emit PayeeChanged(lienId, newPayee);
  }
}
