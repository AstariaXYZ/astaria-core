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

pragma experimental ABIEncoderV2;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {ERC721} from "gpl/ERC721.sol";
import {IERC721} from "core/interfaces/IERC721.sol";
import {IERC165} from "core/interfaces/IERC165.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {CollateralLookup} from "core/libraries/CollateralLookup.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IVaultImplementation} from "core/interfaces/IVaultImplementation.sol";
import {IPublicVault} from "core/interfaces/IPublicVault.sol";
import {VaultImplementation} from "./VaultImplementation.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {AuthInitializable} from "core/AuthInitializable.sol";
import {Initializable} from "./utils/Initializable.sol";
import {ClearingHouse} from "core/ClearingHouse.sol";

import {AmountDeriver} from "seaport/lib/AmountDeriver.sol";

/**
 * @title LienToken
 * @notice This contract handles the creation, payments, buyouts, and liquidations of tokenized NFT-collateralized debt (liens). Vaults which originate loans against supported collateral are issued a LienToken representing the right to loan repayments and auctioned funds on liquidation.
 */
contract LienToken is ERC721, ILienToken, AuthInitializable, AmountDeriver {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeCastLib for uint256;
  using SafeTransferLib for ERC20;

  uint256 private constant LIEN_SLOT =
    uint256(keccak256("xyz.astaria.LienToken.storage.location")) - 1;

  bytes32 constant ACTIVE_AUCTION = bytes32("ACTIVE_AUCTION");

  constructor() {
    _disableInitializers();
  }

  function initialize(
    Authority _AUTHORITY,
    ITransferProxy _TRANSFER_PROXY
  ) public initializer {
    __initAuth(msg.sender, address(_AUTHORITY));
    __initERC721("Astaria Lien Token", "ALT");
    LienStorage storage s = _loadLienStorageSlot();
    s.TRANSFER_PROXY = _TRANSFER_PROXY;
    s.maxLiens = uint8(5);
    s.buyoutFeeNumerator = uint32(100);
    s.buyoutFeeDenominator = uint32(1000);
    s.durationFeeCapNumerator = uint32(900);
    s.durationFeeCapDenominator = uint32(1000);
    s.minDurationIncrease = uint32(5 days);
    s.minInterestBPS = uint32((uint256(1e15) * 5) / (365 days));
  }

  function _loadLienStorageSlot()
    internal
    pure
    returns (LienStorage storage s)
  {
    uint256 slot = LIEN_SLOT;

    assembly {
      s.slot := slot
    }
  }

  function file(File calldata incoming) external requiresAuth {
    FileType what = incoming.what;
    bytes memory data = incoming.data;
    LienStorage storage s = _loadLienStorageSlot();
    if (what == FileType.CollateralToken) {
      s.COLLATERAL_TOKEN = ICollateralToken(abi.decode(data, (address)));
    } else if (what == FileType.AstariaRouter) {
      s.ASTARIA_ROUTER = IAstariaRouter(abi.decode(data, (address)));
    } else if (what == FileType.BuyoutFee) {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      if (denominator < numerator) revert InvalidFileData();
      s.buyoutFeeNumerator = numerator.safeCastTo32();
      s.buyoutFeeDenominator = denominator.safeCastTo32();
    } else if (what == FileType.BuyoutFeeDurationCap) {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      if (denominator < numerator) revert InvalidFileData();
      s.durationFeeCapNumerator = numerator.safeCastTo32();
      s.durationFeeCapDenominator = denominator.safeCastTo32();
    } else if (what == FileType.MinInterestBPS) {
      uint256 value = abi.decode(data, (uint256));
      s.minInterestBPS = value.safeCastTo32();
    } else if (what == FileType.MinDurationIncrease) {
      uint256 value = abi.decode(data, (uint256));
      s.minDurationIncrease = value.safeCastTo32();
    } else {
      revert UnsupportedFile();
    }
    emit FileUpdated(what, data);
  }

  function supportsInterface(
    bytes4 interfaceId
  ) public view override(ERC721, IERC165) returns (bool) {
    return
      interfaceId == type(ILienToken).interfaceId ||
      super.supportsInterface(interfaceId);
  }

  function isValidRefinance(
    Lien calldata newLien,
    uint8 position,
    Stack[] calldata stack,
    uint256 owed,
    uint256 buyout,
    bool chargeable
  ) public view returns (bool) {
    LienStorage storage s = _loadLienStorageSlot();
    uint256 maxNewRate = uint256(stack[position].lien.details.rate) -
      s.minInterestBPS;

    if (newLien.collateralId != stack[0].lien.collateralId) {
      revert InvalidRefinanceCollateral(newLien.collateralId);
    }

    bool isPublicVault = _isPublicVault(s, msg.sender);
    bool hasBuyoutFee = buyout > owed;

    // PublicVault refinances are only valid if they do not have a buyout fee.
    // This happens when the borrower executes the buyout, or the lien duration is past the durationFeeCap.
    if (hasBuyoutFee && !chargeable) {
      revert RefinanceBlocked();
    }

    bool hasImprovedRate = (newLien.details.rate <= maxNewRate &&
      newLien.details.duration + block.timestamp >= stack[position].point.end);

    bool hasImprovedDuration = (block.timestamp +
      newLien.details.duration -
      stack[position].point.end >=
      s.minDurationIncrease &&
      newLien.details.rate <= stack[position].lien.details.rate);

    bool hasNotDecreasedInitialAsk = newLien.details.liquidationInitialAsk >=
      stack[position].lien.details.liquidationInitialAsk;

    return
      (hasImprovedRate || hasImprovedDuration) && hasNotDecreasedInitialAsk;
  }

  function buyoutLien(
    ILienToken.LienActionBuyout calldata params
  )
    external
    validateStack(params.encumber.lien.collateralId, params.encumber.stack)
    returns (
      Stack[] memory stacks,
      Stack memory newStack,
      ILienToken.BuyoutLienParams memory buyoutParams
    )
  {
    if (block.timestamp >= params.encumber.stack[params.position].point.end) {
      revert InvalidState(InvalidStates.EXPIRED_LIEN);
    }
    LienStorage storage s = _loadLienStorageSlot();
    if (!s.ASTARIA_ROUTER.isValidVault(msg.sender)) {
      revert InvalidSender();
    }
    return _buyoutLien(s, params);
  }

  function _buyoutLien(
    LienStorage storage s,
    ILienToken.LienActionBuyout calldata params
  )
    internal
    returns (
      Stack[] memory newStack,
      Stack memory newLien,
      ILienToken.BuyoutLienParams memory buyoutParams
    )
  {
    //the borrower shouldn't incur more debt from the buyout than they already owe
    (, newLien) = _createLien(s, params.encumber);

    (uint256 owed, uint256 buyout) = _getBuyout(
      s,
      params.encumber.stack[params.position]
    );

    if (
      !isValidRefinance({
        newLien: params.encumber.lien,
        position: params.position,
        stack: params.encumber.stack,
        owed: owed,
        buyout: buyout,
        chargeable: params.chargeable
      })
    ) {
      revert InvalidRefinance();
    }

    if (
      s.collateralStateHash[params.encumber.lien.collateralId] == ACTIVE_AUCTION
    ) {
      revert InvalidState(InvalidStates.COLLATERAL_AUCTION);
    }

    if (params.encumber.lien.details.maxAmount < buyout) {
      revert InvalidBuyoutDetails(
        params.encumber.lien.details.maxAmount,
        buyout
      );
    }

    address payee = _getPayee(
      s,
      params.encumber.stack[params.position].point.lienId
    );

    if (_isPublicVault(s, payee)) {
      IPublicVault(payee).handleLoseLienToBuyout(
        ILienToken.BuyoutLienParams({
          lienSlope: calculateSlope(params.encumber.stack[params.position]),
          lienEnd: params.encumber.stack[params.position].point.end
        }),
        buyout - owed
      );
    }

    s.TRANSFER_PROXY.tokenTransferFromWithErrorReceiver(
      params.encumber.stack[params.position].lien.token,
      msg.sender,
      payee,
      buyout
    );

    newStack = _replaceStackAtPositionWithNewLien(
      s,
      params.encumber.stack,
      params.position,
      newLien,
      params.encumber.stack[params.position].point.lienId
    );

    _validateStackState(newStack);

    buyoutParams = ILienToken.BuyoutLienParams({
      lienSlope: calculateSlope(newStack[params.position]),
      lienEnd: newStack[params.position].point.end
    });

    s.collateralStateHash[params.encumber.lien.collateralId] = keccak256(
      abi.encode(newStack)
    );
  }

  function _validateStackState(Stack[] memory stack) internal {
    uint256 potentialDebt = 0;
    uint256 i;
    for (i; i < stack.length; ) {
      if (block.timestamp >= stack[i].point.end) {
        revert InvalidState(InvalidStates.EXPIRED_LIEN);
      }
      if (potentialDebt > stack[i].lien.details.maxPotentialDebt) {
        revert InvalidState(InvalidStates.DEBT_LIMIT);
      }
      potentialDebt += _getOwed(stack[i], stack[i].point.end);
      unchecked {
        ++i;
      }
    }
    potentialDebt = 0;
    i = stack.length;
    for (i; i > 0; ) {
      potentialDebt += _getOwed(stack[i - 1], stack[i - 1].point.end);
      if (potentialDebt > stack[i - 1].lien.details.liquidationInitialAsk) {
        revert InvalidState(InvalidStates.INITIAL_ASK_EXCEEDED);
      }
      unchecked {
        --i;
      }
    }
  }

  function _replaceStackAtPositionWithNewLien(
    LienStorage storage s,
    ILienToken.Stack[] calldata stack,
    uint256 position,
    Stack memory newLien,
    uint256 oldLienId
  ) internal returns (ILienToken.Stack[] memory newStack) {
    newStack = stack;
    newStack[position] = newLien;
    _burn(oldLienId);
    delete s.lienMeta[oldLienId];

    uint256 next;
    uint256 last;
    if (position != 0) {
      last = stack[position - 1].point.lienId;
    }
    if (position != stack.length - 1) {
      next = stack[position + 1].point.lienId;
    }
    emit ReplaceLien(
      newStack[position].point.lienId,
      stack[position].point.lienId,
      next,
      last
    );
  }

  function getInterest(Stack calldata stack) public view returns (uint256) {
    return _getInterest(stack, block.timestamp);
  }

  /**
   * @dev Computes the interest accrued for a lien since its last payment.
   * @param stack The Lien for the loan to calculate interest for.
   * @param timestamp The timestamp at which to compute interest for.
   */
  function _getInterest(
    Stack memory stack,
    uint256 timestamp
  ) internal pure returns (uint256) {
    uint256 delta_t = timestamp - stack.point.last;

    return (delta_t * stack.lien.details.rate).mulWadDown(stack.point.amount);
  }

  modifier validateStack(uint256 collateralId, Stack[] memory stack) {
    LienStorage storage s = _loadLienStorageSlot();
    bytes32 stateHash = s.collateralStateHash[collateralId];
    if (stateHash == bytes32(0) && stack.length != 0) {
      revert InvalidState(InvalidStates.EMPTY_STATE);
    }
    if (stateHash != bytes32(0) && keccak256(abi.encode(stack)) != stateHash) {
      revert InvalidState(InvalidStates.INVALID_HASH);
    }
    _;
  }

  function stopLiens(
    uint256 collateralId,
    uint256 auctionWindow,
    Stack[] calldata stack,
    address liquidator
  ) external validateStack(collateralId, stack) requiresAuth {
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
  ) internal {
    ClearingHouse.AuctionData memory auctionData;
    auctionData.liquidator = liquidator;
    auctionData.token = stack[0].lien.token;
    auctionData.stack = new ClearingHouse.AuctionStack[](stack.length);
    uint256 i;
    for (; i < stack.length; ) {
      ClearingHouse.AuctionStack memory auctionStack;

      auctionStack.lienId = stack[i].point.lienId;
      auctionStack.end = stack[i].point.end;
      uint256 owed = _getOwed(stack[i], block.timestamp);
      auctionStack.amountOwed = owed;
      s.lienMeta[auctionStack.lienId].atLiquidation = true;
      auctionData.stack[i] = auctionStack;
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
      unchecked {
        ++i;
      }
    }
    s.collateralStateHash[collateralId] = ACTIVE_AUCTION;
    auctionData.startTime = block.timestamp.safeCastTo48();
    auctionData.endTime = (block.timestamp + auctionWindow).safeCastTo48();
    auctionData.startAmount = stack[0].lien.details.liquidationInitialAsk;
    auctionData.endAmount = uint256(1000 wei);
    s.COLLATERAL_TOKEN.getClearingHouse(collateralId).setAuctionData(
      auctionData
    );
  }

  function tokenURI(
    uint256 tokenId
  ) public view override(ERC721, IERC721) returns (string memory) {
    if (!_exists(tokenId)) {
      revert InvalidTokenId(tokenId);
    }
    return "";
  }

  function transferFrom(
    address from,
    address to,
    uint256 id
  ) public override(ERC721, IERC721) {
    LienStorage storage s = _loadLienStorageSlot();
    if (_isPublicVault(s, to)) {
      revert InvalidState(InvalidStates.PUBLIC_VAULT_RECIPIENT);
    }
    if (s.lienMeta[id].atLiquidation) {
      revert InvalidState(InvalidStates.COLLATERAL_AUCTION);
    }
    delete s.lienMeta[id].payee;
    emit PayeeChanged(id, address(0));
    super.transferFrom(from, to, id);
  }

  function _exists(uint256 tokenId) internal view returns (bool) {
    return _loadERC721Slot()._ownerOf[tokenId] != address(0);
  }

  function createLien(
    ILienToken.LienActionEncumber calldata params
  )
    external
    requiresAuth
    validateStack(params.lien.collateralId, params.stack)
    returns (uint256 lienId, Stack[] memory newStack, uint256 lienSlope)
  {
    LienStorage storage s = _loadLienStorageSlot();
    //0 - 4 are valid
    Stack memory newStackSlot;
    (lienId, newStackSlot) = _createLien(s, params);

    newStack = _appendStack(s, params.stack, newStackSlot);
    _validateStackState(newStack);

    s.collateralStateHash[params.lien.collateralId] = keccak256(
      abi.encode(newStack)
    );

    lienSlope = calculateSlope(newStackSlot);

    emit NewLien(params.lien.collateralId, newStackSlot);
    emit AppendLien(
      lienId,
      params.stack.length == 0
        ? 0
        : params.stack[params.stack.length - 1].point.lienId
    );
  }

  function _createLien(
    LienStorage storage s,
    ILienToken.LienActionEncumber calldata params
  ) internal returns (uint256 newLienId, ILienToken.Stack memory newSlot) {
    if (s.collateralStateHash[params.lien.collateralId] == ACTIVE_AUCTION) {
      revert InvalidState(InvalidStates.COLLATERAL_AUCTION);
    }
    if (
      params.lien.details.liquidationInitialAsk < params.amount ||
      params.lien.details.liquidationInitialAsk == 0
    ) {
      revert InvalidState(InvalidStates.INVALID_LIQUIDATION_INITIAL_ASK);
    }

    if (params.stack.length > 0) {
      if (params.lien.collateralId != params.stack[0].lien.collateralId) {
        revert InvalidState(InvalidStates.COLLATERAL_MISMATCH);
      }

      if (params.lien.token != params.stack[0].lien.token) {
        revert InvalidState(InvalidStates.ASSET_MISMATCH);
      }
    }

    newLienId = uint256(keccak256(abi.encode(params.lien)));
    Point memory point = Point({
      lienId: newLienId,
      amount: params.amount,
      last: block.timestamp.safeCastTo40(),
      end: (block.timestamp + params.lien.details.duration).safeCastTo40()
    });
    _mint(params.receiver, newLienId);
    return (newLienId, Stack({lien: params.lien, point: point}));
  }

  function _appendStack(
    LienStorage storage s,
    Stack[] calldata stack,
    Stack memory newSlot
  ) internal returns (Stack[] memory newStack) {
    if (stack.length >= s.maxLiens) {
      revert InvalidState(InvalidStates.MAX_LIENS);
    }

    newStack = new Stack[](stack.length + 1);
    newStack[stack.length] = newSlot;
    uint256 i;
    for (i; i < stack.length; ) {
      newStack[i] = stack[i];
      unchecked {
        ++i;
      }
    }
    return newStack;
  }

  function payDebtViaClearingHouse(
    address token,
    uint256 collateralId,
    uint256 payment,
    ClearingHouse.AuctionStack[] memory auctionStack
  ) external {
    LienStorage storage s = _loadLienStorageSlot();
    require(
      msg.sender == address(s.COLLATERAL_TOKEN.getClearingHouse(collateralId))
    );

    _payDebt(s, token, payment, msg.sender, auctionStack);
    delete s.collateralStateHash[collateralId];
  }

  function _payDebt(
    LienStorage storage s,
    address token,
    uint256 payment,
    address payer,
    ClearingHouse.AuctionStack[] memory stack
  ) internal returns (uint256 totalSpent) {
    uint256 i;
    for (; i < stack.length; ) {
      uint256 spent;
      unchecked {
        spent = _paymentAH(s, token, stack, i, payment, payer);
        totalSpent += spent;
        payment -= spent;
        ++i;
      }
    }
  }

  function getAuctionData(
    uint256 collateralId
  ) public view returns (ClearingHouse.AuctionData memory) {
    return
      ClearingHouse(
        _loadLienStorageSlot().COLLATERAL_TOKEN.getClearingHouse(collateralId)
      ).getAuctionData();
  }

  function getAuctionLiquidator(
    uint256 collateralId
  ) external view returns (address liquidator) {
    liquidator = getAuctionData(collateralId).liquidator;
    if (liquidator == address(0)) {
      revert InvalidState(InvalidStates.COLLATERAL_NOT_LIQUIDATED);
    }
  }

  function getAmountOwingAtLiquidation(
    ILienToken.Stack calldata stack
  ) public view returns (uint256) {
    return
      getAuctionData(stack.lien.collateralId)
        .stack[stack.point.lienId]
        .amountOwed;
  }

  function validateLien(Lien memory lien) public view returns (uint256 lienId) {
    lienId = uint256(keccak256(abi.encode(lien)));
    if (!_exists(lienId)) {
      revert InvalidState(InvalidStates.INVALID_LIEN_ID);
    }
  }

  function getCollateralState(
    uint256 collateralId
  ) external view returns (bytes32) {
    return _loadLienStorageSlot().collateralStateHash[collateralId];
  }

  function getBuyoutFee(
    uint256 remainingInterestIn,
    uint256 end,
    uint256 duration
  ) public view returns (uint256 fee) {
    LienStorage storage s = _loadLienStorageSlot();

    uint256 start = end - duration;

    uint256 endTime = start +
      duration.mulDivDown(
        s.durationFeeCapNumerator,
        s.durationFeeCapDenominator
      );

    // Buyout fees begin at (buyoutFee * remainingInterest) and decrease linearly until the durationFeeCap is reached.
    fee = block.timestamp >= endTime
      ? 0
      : _locateCurrentAmount({
        startAmount: remainingInterestIn.mulDivDown(
          s.buyoutFeeNumerator,
          s.buyoutFeeDenominator
        ),
        endAmount: 0,
        startTime: start,
        endTime: endTime,
        roundUp: true
      });
  }

  function getBuyout(
    Stack calldata stack
  ) public view returns (uint256 owed, uint256 buyout) {
    return _getBuyout(_loadLienStorageSlot(), stack);
  }

  function _getBuyout(
    LienStorage storage s,
    Stack calldata stack
  ) internal view returns (uint256 owed, uint256 buyout) {
    owed = _getOwed(stack, block.timestamp);
    buyout = owed;

    // Buyout fees are excluded if the borrower is executing the refinance or if the refinance is within the same Vault.
    if (
      tx.origin != s.COLLATERAL_TOKEN.ownerOf(stack.lien.collateralId) &&
      msg.sender != stack.lien.vault
    ) {
      buyout += getBuyoutFee(
        _getRemainingInterest(s, stack),
        stack.point.end,
        stack.lien.details.duration
      );
    }
  }

  function makePayment(
    uint256 collateralId,
    Stack[] calldata stack,
    uint256 amount
  )
    public
    validateStack(collateralId, stack)
    returns (Stack[] memory newStack)
  {
    return _makePayment(_loadLienStorageSlot(), stack, amount);
  }

  function makePayment(
    uint256 collateralId,
    Stack[] calldata stack,
    uint8 position,
    uint256 amount
  )
    external
    validateStack(collateralId, stack)
    returns (Stack[] memory newStack)
  {
    LienStorage storage s = _loadLienStorageSlot();
    (newStack, ) = _payment(s, stack, position, amount, msg.sender);
    _updateCollateralStateHash(s, collateralId, newStack);
  }

  function _paymentAH(
    LienStorage storage s,
    address token,
    ClearingHouse.AuctionStack[] memory stack,
    uint256 position,
    uint256 payment,
    address payer
  ) internal returns (uint256) {
    uint256 lienId = stack[position].lienId;
    uint256 end = stack[position].end;
    uint256 owing = stack[position].amountOwed;
    //checks the lien exists
    address payee = _getPayee(s, lienId);
    uint256 remaining = 0;
    if (owing > payment) {
      remaining = owing - payment;
    } else {
      payment = owing;
    }
    bool isPublicVault = _isPublicVault(s, payee);

    if (payment > 0) {
      s.TRANSFER_PROXY.tokenTransferFromWithErrorReceiver(
        token,
        payer,
        payee,
        payment
      );
    }

    delete s.lienMeta[lienId]; //full delete
    delete stack[position];
    _burn(lienId);

    if (isPublicVault) {
      IPublicVault(payee).updateAfterLiquidationPayment(
        IPublicVault.LiquidationPaymentParams({remaining: remaining})
      );
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
  ) internal returns (Stack[] memory newStack) {
    newStack = stack;
    for (uint256 i; i < newStack.length; ) {
      uint256 oldLength = newStack.length;
      uint256 spent;
      (newStack, spent) = _payment(
        s,
        newStack,
        uint8(i),
        totalCapitalAvailable,
        msg.sender
      );
      totalCapitalAvailable -= spent;
      if (totalCapitalAvailable == 0) break;
      if (newStack.length == oldLength) {
        unchecked {
          ++i;
        }
      }
    }
    _updateCollateralStateHash(s, stack[0].lien.collateralId, newStack);
  }

  function _updateCollateralStateHash(
    LienStorage storage s,
    uint256 collateralId,
    Stack[] memory stack
  ) internal {
    if (stack.length == 0) {
      delete s.collateralStateHash[collateralId];
    } else {
      s.collateralStateHash[collateralId] = keccak256(abi.encode(stack));
    }
  }

  function calculateSlope(Stack memory stack) public pure returns (uint256) {
    return stack.lien.details.rate.mulWadDown(stack.point.amount);
  }

  function getMaxPotentialDebtForCollateral(
    Stack[] memory stack
  ) public pure returns (uint256 maxPotentialDebt) {
    return _getMaxPotentialDebtForCollateralUpToNPositions(stack, stack.length);
  }

  function _getMaxPotentialDebtForCollateralUpToNPositions(
    Stack[] memory stack,
    uint256 n
  ) internal pure returns (uint256 maxPotentialDebt) {
    for (uint256 i; i < n; ) {
      maxPotentialDebt += _getOwed(stack[i], stack[i].point.end);
      unchecked {
        ++i;
      }
    }
  }

  function getMaxPotentialDebtForCollateral(
    Stack[] memory stack,
    uint256 end
  ) public pure returns (uint256 maxPotentialDebt) {
    uint256 i;
    for (; i < stack.length; ) {
      maxPotentialDebt += _getOwed(stack[i], end);
      unchecked {
        ++i;
      }
    }
  }

  function getOwed(Stack memory stack) external view returns (uint256) {
    validateLien(stack.lien);
    return _getOwed(stack, block.timestamp);
  }

  function getOwed(
    Stack memory stack,
    uint256 timestamp
  ) external view returns (uint256) {
    validateLien(stack.lien);
    return _getOwed(stack, timestamp);
  }

  /**
   * @dev Computes the debt owed to a Lien at a specified timestamp.
   * @param stack The specified Lien.
   * @return The amount owed to the Lien at the specified timestamp.
   */
  function _getOwed(
    Stack memory stack,
    uint256 timestamp
  ) internal pure returns (uint256) {
    return stack.point.amount + _getInterest(stack, timestamp);
  }

  /**
   * @dev Computes the interest still owed to a Lien.
   * @param s active storage slot
   * @param stack the lien
   * @return The WETH still owed in interest to the Lien.
   */
  function _getRemainingInterest(
    LienStorage storage s,
    Stack memory stack
  ) internal view returns (uint256) {
    uint256 delta_t = stack.point.end - block.timestamp;
    return (delta_t * stack.lien.details.rate).mulWadDown(stack.point.amount);
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
    uint64 end = stack.point.end;
    // Blocking off payments for a lien that has exceeded the lien.end to prevent repayment unless the msg.sender() is the AuctionHouse
    if (block.timestamp >= end) {
      revert InvalidLoanState();
    }
    uint256 owed = _getOwed(stack, block.timestamp);
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
    stack.point.amount = owed;
    stack.point.last = block.timestamp.safeCastTo40();

    if (stack.point.amount > amount) {
      stack.point.amount -= amount;
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
          IPublicVault(lienOwner).getLienEpoch(end)
        );
      }
      delete s.lienMeta[lienId]; //full delete of point data for the lien
      _burn(lienId);
      activeStack = _removeStackPosition(activeStack, position);
    }

    s.TRANSFER_PROXY.tokenTransferFromWithErrorReceiver(
      stack.lien.token,
      payer,
      payee,
      amount
    );

    emit Payment(lienId, amount);
    return (activeStack, amount);
  }

  function _removeStackPosition(
    Stack[] memory stack,
    uint8 position
  ) internal returns (Stack[] memory newStack) {
    uint256 length = stack.length;
    require(position < length);
    newStack = new ILienToken.Stack[](length - 1);
    uint256 i;
    for (; i < position; ) {
      newStack[i] = stack[i];
      unchecked {
        ++i;
      }
    }
    for (; i < length - 1; ) {
      unchecked {
        newStack[i] = stack[i + 1];
        ++i;
      }
    }

    uint256 next;
    uint256 last;
    if (position == 0) {
      last = 0;
    } else {
      last = stack[position - 1].point.lienId;
    }
    if (position == newStack.length) {
      next = 0;
    } else {
      next = newStack[position].point.lienId;
    }
    emit RemoveLien(stack[position].point.lienId, next, last);
  }

  function _isPublicVault(
    LienStorage storage s,
    address account
  ) internal view returns (bool) {
    return
      s.ASTARIA_ROUTER.isValidVault(account) &&
      IPublicVault(account).supportsInterface(type(IPublicVault).interfaceId);
  }

  function getPayee(uint256 lienId) public view returns (address) {
    if (!_exists(lienId)) {
      revert InvalidState(InvalidStates.INVALID_LIEN_ID);
    }
    return _getPayee(_loadLienStorageSlot(), lienId);
  }

  function _getPayee(
    LienStorage storage s,
    uint256 lienId
  ) internal view returns (address) {
    return
      s.lienMeta[lienId].payee != address(0)
        ? s.lienMeta[lienId].payee
        : ownerOf(lienId);
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
