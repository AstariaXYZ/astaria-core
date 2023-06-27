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

import {ERC721, ERC721TokenReceiver} from "gpl/ERC721.sol";
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
    s.buyoutFeeNumerator = uint32(100);
    s.buyoutFeeDenominator = uint32(1000);
    s.durationFeeCapNumerator = uint32(900);
    s.durationFeeCapDenominator = uint32(1000);
    s.minDurationIncrease = uint32(5 days);
    s.minInterestBPS = uint32((uint256(1e15) * 5) / (365 days));
    s.minLoanDuration = uint32(1 hours);
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
    } else if (what == FileType.MinLoanDuration) {
      uint256 value = abi.decode(data, (uint256));
      s.minLoanDuration = value.safeCastTo32();
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

  modifier validateCollateralState(uint256 collateralId, bytes32 incomingHash) {
    LienStorage storage s = _loadLienStorageSlot();
    if (incomingHash != s.collateralStateHash[collateralId]) {
      revert InvalidState(InvalidStates.INVALID_HASH);
    }
    _;
  }

  function stopLiens(
    uint256 collateralId,
    uint256 auctionWindow,
    Stack calldata stack,
    address liquidator
  )
    external
    validateCollateralState(collateralId, keccak256(abi.encode(stack)))
    requiresAuth
  {
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
    Stack calldata stack,
    address liquidator
  ) internal {
    uint256 owed = _getOwed(stack, block.timestamp);
    ClearingHouse.AuctionStack memory auctionStack = ClearingHouse
      .AuctionStack({
        lienId: stack.point.lienId,
        end: stack.point.end,
        amountOwed: owed,
        principal: stack.point.amount
      });
    s.lienMeta[auctionStack.lienId].atLiquidation = true;
    address owner = ownerOf(auctionStack.lienId);
    if (_isPublicVault(s, owner)) {
      // update the public vault state and get the liquidation accountant back if any
      address withdrawProxyIfNearBoundary = IPublicVault(owner)
        .updateVaultAfterLiquidation(
          auctionWindow,
          IPublicVault.AfterLiquidationParams({
            lienSlope: calculateSlope(stack),
            lienEnd: stack.point.end
          })
        );

      if (withdrawProxyIfNearBoundary != address(0)) {
        _safeTransferFromInLiquidation(
          owner,
          withdrawProxyIfNearBoundary,
          stack.point.lienId,
          owed,
          auctionWindow
        );
      }
    }
    s.collateralStateHash[collateralId] = ACTIVE_AUCTION;

    ClearingHouse.AuctionData memory auctionData = ClearingHouse.AuctionData({
      liquidator: liquidator,
      token: stack.lien.token,
      stack: auctionStack,
      startTime: block.timestamp.safeCastTo48(),
      endTime: (block.timestamp + auctionWindow).safeCastTo48(),
      startAmount: stack.lien.details.liquidationInitialAsk,
      endAmount: uint256(1000 wei)
    });
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
    validateCollateralState(params.lien.collateralId, bytes32(0))
    returns (uint256 lienId, Stack memory newStack, uint256 lienSlope)
  {
    LienStorage storage s = _loadLienStorageSlot();
    (lienId, newStack) = _createLien(s, params);

    s.collateralStateHash[params.lien.collateralId] = keccak256(
      abi.encode(newStack)
    );

    lienSlope = calculateSlope(newStack);

    emit NewLien(params.lien.collateralId, newStack);
  }

  function _createLien(
    LienStorage storage s,
    ILienToken.LienActionEncumber calldata params
  ) internal returns (uint256 newLienId, ILienToken.Stack memory newSlot) {
    if (s.collateralStateHash[params.lien.collateralId] == ACTIVE_AUCTION) {
      revert InvalidState(InvalidStates.COLLATERAL_AUCTION);
    }

    if (params.amount == 0) {
      revert InvalidState(InvalidStates.AMOUNT_ZERO);
    }
    if (params.lien.details.duration < s.minLoanDuration) {
      revert InvalidState(InvalidStates.MIN_DURATION_NOT_MET);
    }
    if (
      params.lien.details.liquidationInitialAsk < params.amount ||
      params.lien.details.liquidationInitialAsk == 0
    ) {
      revert InvalidState(InvalidStates.INVALID_LIQUIDATION_INITIAL_ASK);
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

  function payDebtViaClearingHouse(
    address token,
    uint256 collateralId,
    uint256 payment,
    ClearingHouse.AuctionStack memory auctionStack
  ) external {
    LienStorage storage s = _loadLienStorageSlot();
    require(
      msg.sender == address(s.COLLATERAL_TOKEN.getClearingHouse(collateralId))
    );

    payment = payment > auctionStack.amountOwed
      ? auctionStack.amountOwed
      : payment;
    uint256 remaining = auctionStack.amountOwed - payment;
    uint256 interestPaid = payment > auctionStack.principal
      ? payment - auctionStack.principal
      : 0;
    _payment(
      s,
      auctionStack.lienId,
      auctionStack.end,
      payment, //amount paid
      interestPaid,
      collateralId,
      token,
      remaining, // decrease in y intercept
      uint256(0) // decrease in slope
    );
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
    return getAuctionData(stack.lien.collateralId).stack.amountOwed;
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

  function makePayment(
    Stack calldata stack
  )
    public
    validateCollateralState(
      stack.lien.collateralId,
      keccak256(abi.encode(stack))
    )
  {
    {
      uint256 amountOwing = _getOwed(stack, block.timestamp);

      _payment(
        _loadLienStorageSlot(),
        stack.point.lienId,
        stack.point.end,
        amountOwing,
        amountOwing - stack.point.amount,
        stack.lien.collateralId,
        stack.lien.token,
        amountOwing,
        calculateSlope(stack)
      );
    }
  }

  function calculateSlope(Stack memory stack) public pure returns (uint256) {
    return stack.lien.details.rate.mulWadDown(stack.point.amount);
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
   * @dev Make a payment from a payer to a specific lien against a CollateralToken.
   */
  function _payment(
    LienStorage storage s,
    uint256 lienId,
    uint64 end,
    uint256 amountOwed,
    uint256 interestPaid,
    uint256 collateralId,
    address token,
    uint256 decreaseYIntercept, //remaining unpaid owed amount
    uint256 decreaseInSlope
  ) internal {
    address owner = ownerOf(lienId);

    if (_isPublicVault(s, owner)) {
      IPublicVault(owner).updateVault(
        IPublicVault.UpdateVaultParams({
          decreaseInYIntercept: decreaseYIntercept, //if the lien owner is not the payee then we are not decreasing the y intercept
          interestPaid: interestPaid,
          decreaseInSlope: decreaseInSlope,
          lienEnd: end
        })
      );
    }

    _removeLien(s, lienId, collateralId);
    emit Payment(lienId, amountOwed);
    if (amountOwed > 0) {
      s.TRANSFER_PROXY.tokenTransferFromWithErrorReceiver(
        token,
        msg.sender,
        owner,
        amountOwed
      );
    }
  }

  function _safeTransferFromInLiquidation(
    address from,
    address to,
    uint256 id,
    uint256 expected,
    uint256 auctionEnd
  ) internal virtual {
    _transfer(from, to, id);

    require(
      to.code.length == 0 ||
        ERC721TokenReceiver(to).onERC721Received(
          address(this),
          from,
          id,
          abi.encode(expected, auctionEnd)
        ) ==
        ERC721TokenReceiver.onERC721Received.selector,
      "UNSAFE_RECIPIENT"
    );
  }

  function _removeLien(
    LienStorage storage s,
    uint256 lienId,
    uint256 collateralId
  ) internal {
    _burn(lienId);
    delete s.lienMeta[lienId]; //full delete of point data for the lien
    delete s.collateralStateHash[collateralId];
  }

  function _isPublicVault(
    LienStorage storage s,
    address account
  ) internal view returns (bool) {
    return
      s.ASTARIA_ROUTER.isValidVault(account) &&
      IPublicVault(account).supportsInterface(type(IPublicVault).interfaceId);
  }
}
