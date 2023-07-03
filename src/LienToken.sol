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

import {AmountDeriver} from "seaport-core/src/lib/AmountDeriver.sol";

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

  /**
   * @notice Sets addresses for the AuctionHouse, CollateralToken, and AstariaRouter contracts to use.
   * @param incoming The incoming file to handle.
   */
  function file(File calldata incoming) external requiresAuth {
    FileType what = incoming.what;
    bytes memory data = incoming.data;
    LienStorage storage s = _loadLienStorageSlot();
    if (what == FileType.CollateralToken) {
      s.COLLATERAL_TOKEN = ICollateralToken(abi.decode(data, (address)));
    } else if (what == FileType.AstariaRouter) {
      s.ASTARIA_ROUTER = IAstariaRouter(abi.decode(data, (address)));
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

  /**
   * @notice Public view function that computes the interest for a LienToken since its last payment.
   * @param stack the Lien
   */
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

  /**
   * @notice Checks the validity of the loan hash and the current state of the lien.
   */
  modifier validateCollateralState(uint256 collateralId, bytes32 incomingHash) {
    LienStorage storage s = _loadLienStorageSlot();
    if (incomingHash != s.collateralStateHash[collateralId]) {
      revert InvalidLienState(InvalidLienStates.INVALID_HASH);
    }
    _;
  }

  /**
   * @notice Stops accruing interest for all liens against a single CollateralToken.
   * @param auctionWindow The ID for the  CollateralToken of the NFT used as collateral for the liens.
   * @param stack the stack of the loan
   * @param liquidator the address of the liquidator
   */
  function handleLiquidation(
    uint256 auctionWindow,
    Stack calldata stack,
    address liquidator
  )
    external
    validateCollateralState(
      stack.lien.collateralId,
      keccak256(abi.encode(stack))
    )
  {
    LienStorage storage s = _loadLienStorageSlot();
    if (msg.sender != address(s.ASTARIA_ROUTER)) {
      revert InvalidSender();
    }
    _handleLiquidation(s, auctionWindow, stack, liquidator);
  }

  function _handleLiquidation(
    LienStorage storage s,
    uint256 auctionWindow,
    Stack calldata stack,
    address liquidator
  ) internal {
    uint256 owed = _getOwed(stack, block.timestamp);
    uint256 lienId = uint256(keccak256(abi.encode(stack)));

    s.collateralLiquidator[stack.lien.collateralId] = AuctionData({
      amountOwed: owed,
      liquidator: liquidator
    });

    address owner = ownerOf(lienId);
    if (_isPublicVault(s, owner)) {
      IPublicVault(owner).stopLien(
        auctionWindow,
        calculateSlope(stack),
        stack.point.end,
        lienId,
        owed
      );
    }
  }

  function tokenURI(
    uint256 tokenId
  ) public view override(ERC721, IERC721) returns (string memory) {
    ownerOf(tokenId); //enforce exists
    return "";
  }

  function transferFrom(
    address from,
    address to,
    uint256 id
  ) public override(ERC721, IERC721) {
    LienStorage storage s = _loadLienStorageSlot();
    if (_isPublicVault(s, to)) {
      revert InvalidLienState(InvalidLienStates.PUBLIC_VAULT_RECIPIENT);
    }
    super.transferFrom(from, to, id);
  }

  /**
   * @notice Creates a new lien against a CollateralToken.
   * @param params LienActionEncumber data containing CollateralToken information and lien parameters (rate, duration, and amount, rate, and debt caps).
   */
  function createLien(
    ILienToken.LienActionEncumber calldata params
  )
    external
    validateCollateralState(params.lien.collateralId, bytes32(0))
    returns (uint256 lienId, Stack memory newStack, uint256 owingAtEnd)
  {
    LienStorage storage s = _loadLienStorageSlot();
    if (msg.sender != address(s.ASTARIA_ROUTER)) {
      revert InvalidSender();
    }

    (lienId, newStack) = _createLien(s, params);

    owingAtEnd = _getOwed(newStack, newStack.point.end);
    s.collateralStateHash[params.lien.collateralId] = bytes32(lienId);
    emit NewLien(params.lien.collateralId, newStack);
  }

  function _createLien(
    LienStorage storage s,
    ILienToken.LienActionEncumber calldata params
  ) internal returns (uint256 newLienId, ILienToken.Stack memory newSlot) {
    uint40 lienEnd = (block.timestamp + params.lien.details.duration)
      .safeCastTo40();
    Point memory point = Point({
      amount: params.amount,
      last: block.timestamp.safeCastTo40(),
      end: lienEnd
    });

    newSlot = Stack({lien: params.lien, point: point});
    newLienId = uint256(keccak256(abi.encode(newSlot)));
    _safeMint(
      params.receiver,
      newLienId,
      abi.encode(
        params.borrower,
        params.amount,
        lienEnd,
        calculateSlope(newSlot),
        params.feeTo,
        params.fee
      )
    );
  }

  /**
   * @notice Retrieves the liquidator for a CollateralToken.
   * @param collateralId The ID of the CollateralToken.
   */
  function getAuctionLiquidator(
    uint256 collateralId
  ) external view returns (address liquidator) {
    liquidator = _loadLienStorageSlot()
      .collateralLiquidator[collateralId]
      .liquidator;
    if (liquidator == address(0)) {
      revert InvalidLienState(InvalidLienStates.COLLATERAL_NOT_LIQUIDATED);
    }
  }

  /**
   * @notice Retrieves a lienCount for specific collateral
   * @param collateralId the Lien to compute a point for
   */
  function getCollateralState(
    uint256 collateralId
  ) external view returns (bytes32) {
    return _loadLienStorageSlot().collateralStateHash[collateralId];
  }

  struct Payments {
    uint256 amountOwing;
    uint256 interestPaid;
    uint256 decreaseInYIntercept;
    uint256 decreaseInSlope;
  }

  /**
   * @notice Make a payment for the debt against a CollateralToken.
   * @param stack the stack to pay against
   */
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
      LienStorage storage s = _loadLienStorageSlot();
      Payments memory payment;

      //auction repayment
      if (s.collateralLiquidator[stack.lien.collateralId].amountOwed > 0) {
        if (msg.sender != address(s.COLLATERAL_TOKEN)) {
          revert InvalidSender();
        }
        uint256 CTBalance = ERC20(stack.lien.token).balanceOf(
          address(s.COLLATERAL_TOKEN)
        );

        uint256 owing = s
          .collateralLiquidator[stack.lien.collateralId]
          .amountOwed;
        payment.amountOwing = owing > CTBalance ? CTBalance : owing;
        payment.interestPaid = payment.amountOwing > stack.point.amount
          ? payment.amountOwing - stack.point.amount
          : 0;
        payment.decreaseInYIntercept = owing - payment.amountOwing;
        payment.decreaseInSlope = 0;
      } else {
        // regular payment
        payment.amountOwing = _getOwed(stack, block.timestamp); // amountOwing
        payment.interestPaid = payment.amountOwing - stack.point.amount; // interestPaid
        payment.decreaseInYIntercept = 0; // decrease in y intercept
        payment.decreaseInSlope = calculateSlope(stack);
      }
      _payment(
        s,
        uint256(keccak256(abi.encode(stack))),
        stack.point.end,
        payment.amountOwing,
        payment.interestPaid,
        stack.lien.collateralId,
        stack.lien.token,
        payment.decreaseInYIntercept, // decrease in y intercept
        payment.decreaseInSlope // decrease in slope
      );
    }
  }

  /**
   * @notice Computes the rate for a specified lien.
   * @param stack The Lien to compute the slope for.
   * @return slope The rate for the specified lien, in WETH per second.
   */
  function calculateSlope(Stack memory stack) public pure returns (uint256) {
    return stack.lien.details.rate.mulWadDown(stack.point.amount);
  }

  /**
   * @notice Removes all liens for a given CollateralToken.
   * @param stack The Lien stack
   * @return the amount owed in uint192 at the current block.timestamp
   */
  function getOwed(Stack memory stack) external view returns (uint256) {
    return _getOwed(stack, block.timestamp);
  }

  /**
   * @notice Removes all liens for a given CollateralToken.
   * @param stack The Lien stack
   * @param timestamp The timestamp to calculate the amount owed at
   * @return the amount owed in uint192 at the current block.timestamp
   */
  function getOwed(
    Stack memory stack,
    uint256 timestamp
  ) external view returns (uint256) {
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
    //only if not in an auction
    if (msg.sender != address(s.COLLATERAL_TOKEN)) {
      s.COLLATERAL_TOKEN.release(collateralId);
    }
  }

  function _removeLien(
    LienStorage storage s,
    uint256 lienId,
    uint256 collateralId
  ) internal {
    _burn(lienId);
    delete s.collateralStateHash[collateralId];
    delete s.collateralLiquidator[collateralId];
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
