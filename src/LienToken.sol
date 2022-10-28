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
 * @author androolloyd
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
    view
    returns (LienStorage storage s)
  {
    bytes32 slot = LIEN_SLOT;
    assembly {
      s.slot := slot
    }
  }

  /**
   * @notice Sets addresses for the AuctionHouse, CollateralToken, and AstariaRouter contracts to use.
   * @param what The identifier for what is being filed.
   * @param data The encoded address data to be decoded and filed.
   */
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

  /**
   * @dev See {IERC165-supportsInterface}.
   */
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

  //  /**
  //   * @notice Purchase a LienToken for its buyout price.
  //   * @param params The LienActionBuyout data specifying the lien position, receiver address, and underlying CollateralToken information of the lien.
  //   */

  //  function buyoutLien(ILienToken.LienActionBuyout calldata params) external {
  //    LienStorage storage s = _loadLienStorageSlot();
  //
  //    (bool valid, ILienToken.Details memory ld) = s
  //      .ASTARIA_ROUTER
  //      .validateCommitment(params.incoming);
  //
  //    if (!valid) {
  //      revert InvalidTerms();
  //    }
  //
  //    uint256 collateralId = params.incoming.tokenContract.computeId(
  //      params.incoming.tokenId
  //    );
  //    (uint256 owed, uint256 buyout) = getBuyout(collateralId, params.position);
  //    uint256 lienId = s.liens[collateralId][params.position];
  //
  //    //the borrower shouldn't incur more debt from the buyout than they already owe
  //    if (ld.maxAmount < owed) {
  //      revert InvalidBuyoutDetails(ld.maxAmount, owed);
  //    }
  //    if (!s.ASTARIA_ROUTER.isValidRefinance(s.lienData[lienId], ld)) {
  //      revert InvalidRefinance();
  //    }
  //
  //    s.TRANSFER_PROXY.tokenTransferFrom(
  //      s.WETH,
  //      address(msg.sender),
  //      getPayee(lienId),
  //      uint256(buyout)
  //    );
  //
  //    if (msg.sender != params.receiver) {
  //      require(_loadERC721Slot().isApprovedForAll[msg.sender][params.receiver]);
  //    }
  //
  //    s.lienData[lienId].last = block.timestamp.safeCastTo64();
  //    s.lienData[lienId].end = uint256(block.timestamp + ld.duration)
  //      .safeCastTo64();
  //    s.lienData[lienId].rate = ld.rate.safeCastTo192();
  //
  //    _transfer(ownerOf(lienId), address(params.receiver), lienId);
  //  }

  //  /**
  //   * @notice Public view function that computes the interest for a LienToken since its last payment.
  //   * @param collateralId The ID of the underlying CollateralToken
  //   * @param position The position of the lien to calculate interest for.
  //   */
  //  function getInterest(uint256 collateralId, uint256 position)
  //    public
  //    view
  //    returns (uint256)
  //  {
  //    LienStorage storage s = _loadLienStorageSlot();
  //
  //    uint256 lien = s.liens[collateralId][position];
  //    return _getInterest(s.lienData[lien], block.timestamp);
  //  }

  function getInterest(LienEvent calldata lien) public view returns (uint256) {
    return _getInterest(lien, block.timestamp);
  }

  function _getInterest(LienEvent calldata lien, uint256 timestamp)
    internal
    view
    returns (uint256)
  {
    LienStorage storage s = _loadLienStorageSlot();
    uint256 lienId = validateLien(lien);
    LienDataPoint memory point = s.lienData[lienId];
    return _getInterest(point, lien, timestamp);
  }

  /**
   * @dev Computes the interest accrued for a lien since its last payment.
   * @param lien The Lien for the loan to calculate interest for.
   * @param timestamp The timestamp at which to compute interest for.
   */
  function _getInterest(
    LienDataPoint memory point,
    LienEvent calldata lien,
    uint256 timestamp
  ) internal pure returns (uint256) {
    if (!point.active) {
      return uint256(0);
    }
    uint256 delta_t = timestamp - point.last;

    return delta_t.mulDivDown(lien.details.rate, 1).mulWadDown(point.amount);
  }

  /**
   * @notice Stops accruing interest for all liens against a single CollateralToken.
   * @param collateralId The ID for the  CollateralToken of the NFT used as collateral for the liens.
   */
  function stopLiens(uint256 collateralId, LienEvent[] calldata stack)
    external
    requiresAuth
    validateStack(collateralId, stack)
    returns (uint256 reserve)
  {
    LienStorage storage s = _loadLienStorageSlot();

    reserve = 0;
    uint256[] memory lienIds = s.liens[collateralId];
    for (uint256 i = 0; i < lienIds.length; ++i) {
      LienDataPoint storage point = s.lienData[lienIds[i]];

      unchecked {
        point.amount = _getOwed(point, stack[i]);
        reserve += point.amount;
      }
      point.last = block.timestamp.safeCastTo40();
      point.active = false;
    }
  }

  /**
   * @dev See {IERC721Metadata-tokenURI}.
   */
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

  /**
   * @notice Creates a new lien against a CollateralToken.
   * @param params LienActionEncumber data containing CollateralToken information and lien parameters (rate, duration, and amount, rate, and debt caps).
   */
  function createLien(ILienToken.LienActionEncumber calldata params)
    external
    requiresAuth
    validateStack(params.collateralId, params.stack)
    returns (uint256 lienId, LienEvent[] memory stack)
  {
    // require that the auction is not under way

    //    uint256 collateralId = params.tokenContract.computeId(params.tokenId);

    LienStorage storage s = _loadLienStorageSlot();

    //    if (s.AUCTION_HOUSE.auctionExists(collateralId)) {
    //      revert InvalidState(InvalidStates.COLLATERAL_AUCTION);
    //    }
    //
    //    (address tokenContract, ) = s.COLLATERAL_TOKEN.getUnderlying(collateralId);
    //    if (tokenContract == address(0)) {
    //      revert InvalidState(InvalidStates.COLLATERAL_NOT_DEPOSITED);
    //    }

    uint256 maxPotentialDebt = getMaxPotentialDebtForCollateral(
      params.collateralId,
      params.stack
    );

    if (maxPotentialDebt > params.terms.maxPotentialDebt) {
      revert InvalidState(InvalidStates.DEBT_LIMIT);
    }
    uint8 newPosition = uint8(s.liens[params.collateralId].length);

    ILienToken.LienEvent memory newLien = LienEvent({
      collateralId: params.collateralId,
      vault: params.vault,
      token: s.WETH,
      position: newPosition,
      strategyRoot: params.strategyRoot,
      end: uint256(block.timestamp + params.terms.duration).safeCastTo40(),
      details: params.terms
    });

    lienId = uint256(keccak256(abi.encode(newLien)));

    //0 - 4 are valid

    if (s.liens[params.collateralId].length == s.maxLiens) {
      revert InvalidState(InvalidStates.MAX_LIENS);
    }

    _mint(VaultImplementation(params.vault).recipient(), lienId);

    stack = _appendStack(s, params.stack, newLien);

    s.lienData[lienId] = LienDataPoint({
      amount: params.amount.safeCastTo192(),
      last: block.timestamp.safeCastTo40(),
      active: true
    });

    s.liens[params.collateralId].push(lienId);

    emit LienStackUpdated(lienId, stack);
  }

  function _appendStack(
    LienStorage storage s,
    LienEvent[] calldata stack,
    LienEvent memory newLien
  ) internal view returns (LienEvent[] memory newStack) {
    newStack = new LienEvent[](stack.length + 1);
    for (uint256 i = 0; i < stack.length; ++i) {
      newStack[i] = stack[i];
    }
    newStack[stack.length] = newLien;
  }

  /**
   * @notice Removes all liens for a given CollateralToken.
   * @param collateralId The ID for the underlying CollateralToken.
   * @param remainingLiens The IDs for the unpaid liens
   */
  function removeLiens(uint256 collateralId, uint256[] memory remainingLiens)
    external
    requiresAuth
  {
    LienStorage storage s = _loadLienStorageSlot();

    for (uint256 i = 0; i < remainingLiens.length; i++) {
      delete s.lienData[remainingLiens[i]];
      _burn(remainingLiens[i]);
    }
    delete s.liens[collateralId];
    emit RemovedLiens(collateralId);
  }

  /**
   * @notice Retrieves all liens taken out against the underlying NFT of a CollateralToken.
   * @param collateralId The ID for the underlying CollateralToken.
   * @return The IDs of the liens against the CollateralToken.
   */
  function getLiens(uint256 collateralId)
    public
    view
    returns (uint256[] memory)
  {
    return _loadLienStorageSlot().liens[collateralId];
  }

  /**
   * @notice Retrieves a specific point by its lienId.
   * @param collateralId the collateral holding the point
   * @return point the LienDataPoint
   */
  function getPoint(uint256 collateralId, uint8 position)
    public
    view
    returns (LienDataPoint memory point)
  {
    LienStorage storage s = _loadLienStorageSlot();
    point = _getPointNoAccrue(s, s.liens[collateralId][position]);
  }

  function getPoint(uint256 lienId)
    external
    view
    returns (LienDataPoint memory point)
  {
    LienStorage storage s = _loadLienStorageSlot();
    return _getPointNoAccrue(s, lienId);
  }

  function _getPointNoAccrue(LienStorage storage s, uint256 lienId)
    internal
    view
    returns (LienDataPoint memory point)
  {
    point = s.lienData[lienId];
  }

  /**
   * @notice Retrieves a specific point by its lienId.
   * @param lien the Lien to compute a point for
   */
  function getPoint(ILienToken.LienEvent calldata lien)
    public
    view
    returns (LienDataPoint memory point)
  {
    uint256 lienId = validateLien(lien);
    point = _loadLienStorageSlot().lienData[lienId];

    point.amount = _getOwed(point, lien);
    point.last = block.timestamp.safeCastTo40();
  }

  function getLienDataPoint(uint256 lienId)
    public
    view
    returns (LienDataPoint memory lien)
  {
    lien = _loadLienStorageSlot().lienData[lienId];
  }

  //  /**
  //   * @notice Retrives a specific Lien from the ID of the CollateralToken for the underlying NFT and the lien position.
  //   * @param collateralId The ID for the underlying CollateralToken.
  //   * @param position The requested lien position.
  //   *  @ return lien The Lien for the lienId.
  //   */
  //  function getLien(uint256 collateralId, uint256 position)
  //    public
  //    view
  //    returns (Lien memory)
  //  {
  //    return getLien(_loadLienStorageSlot().liens[collateralId][position]);
  //  }

  /**
   * @notice Retrives a specific Lien from the ID of the CollateralToken for the underlying NFT and the lien position.
   * @param collateralId The ID for the underlying CollateralToken.
   * @param position The requested lien position.
   *  @ return lien The Lien for the lienId.
   */
  function getLienDataPoint(uint256 collateralId, uint256 position)
    public
    view
    returns (LienDataPoint memory)
  {
    return
      getLienDataPoint(_loadLienStorageSlot().liens[collateralId][position]);
  }

  function validateLien(LienEvent calldata lienEvent)
    public
    view
    returns (uint256 lienId)
  {
    lienId = uint256(keccak256(abi.encode(lienEvent)));
    if (!_exists(lienId)) {
      revert InvalidState(InvalidStates.INVALID_LIEN_ID);
    }
  }

  modifier lienExists(LienEvent calldata lienEvent) {
    LienStorage storage s = _loadLienStorageSlot();
    validateLien(lienEvent);
    _;
  }

  function getBuyout(LienEvent calldata lienEvent)
    public
    view
    returns (uint256, uint256)
  {
    LienStorage storage s = _loadLienStorageSlot();
    LienDataPoint storage point = s.lienData[
      s.liens[lienEvent.collateralId][lienEvent.position]
    ];

    if (point.amount == 0) {
      revert InvalidState(InvalidStates.LIEN_NO_DEBT);
    }
    //    Lien memory lien = getLien(collateralId, position);

    //validate lien presented

    uint256 remainingInterest = _getRemainingInterest(
      s,
      point,
      lienEvent,
      true
    );
    uint256 buyoutTotal = point.amount +
      s.ASTARIA_ROUTER.getBuyoutFee(remainingInterest);

    return (point.amount, buyoutTotal);
    //    return
    //      _getBuyout(
    //        lienEvent.details.maxAmount,
    //        lienEvent.details.rate,
    //        lienEvent.details.duration,
    //        lienEvent.details.maxPotentialDebt
    //      );
  }

  //  /**
  //   * @notice Computes and returns the buyout amount for a Lien.
  //   * @param collateralId The ID for the underlying CollateralToken.
  //   * @param position The position of the Lien to compute the buyout amount for.
  //   * @return The outstanding debt for the lien and the buyout amount for the Lien.
  //   */
  //  function getBuyout(uint256 collateralId, uint256 position)
  //    public
  //    view
  //    returns (uint256, uint256)
  //  {
  //    LienStorage storage s = _loadLienStorageSlot();
  //    //    Point storage point = s.lienData[liens[collateralId][position]];
  //    Lien memory lien = getLien(collateralId, position);
  //
  //    //validate lien presented
  //
  //    uint256 remainingInterest = _getRemainingInterest(s, lien, true);
  //    uint256 buyoutTotal = lien.amount +
  //      s.ASTARIA_ROUTER.getBuyoutFee(remainingInterest);
  //
  //    return (lien.amount, buyoutTotal);
  //  }

  /**
   * @notice Make a payment for the debt against a CollateralToken.
   * @param stack the stack to pay against
   * @param paymentAmount The amount to pay against the debt.
   */
  function makePayment(LienEvent[] calldata stack, uint256 paymentAmount)
    public
  {
    _makePayment(stack, paymentAmount);
  }

  /**
   * @notice Make a payment for the debt against a CollateralToken for a specific lien.
   * @param lien the LienEvent to make a payment towards
   * @param paymentAmount The amount to pay against the debt.
   */
  function makePayment(LienEvent calldata lien, uint256 paymentAmount)
    external
  {
    _payment2(_loadLienStorageSlot(), lien, paymentAmount, address(msg.sender));
  }

  function makePaymentAuctionHouse(
    uint256 lienId,
    uint256 collateralId,
    uint256 paymentAmount,
    uint8 position,
    address payer
  ) external requiresAuth returns (uint256) {
    LienStorage storage s = _loadLienStorageSlot();
    if (paymentAmount == uint256(0)) {
      return uint256(0);
    }
    uint256 amountSpent = paymentAmount;

    //    uint256 lienId = s.liens[collateralId][position];
    if (!_exists(lienId)) {
      revert InvalidState(InvalidStates.INVALID_LIEN_ID);
    }

    LienDataPoint storage point = s.lienData[lienId];

    address lienOwner = ownerOf(lienId);

    address payee = getPayee(lienId);

    if (point.amount > paymentAmount) {
      point.amount -= paymentAmount.safeCastTo192();
      amountSpent = paymentAmount;
      point.last = block.timestamp.safeCastTo40();
      // slope does not need to be updated if paying off the rest, since we neutralize slope in beforePayment()
    } else {
      amountSpent = point.amount;
      //delete liens
      _deleteLienPosition(s, collateralId, position);
      delete s.lienData[lienId]; //full delete

      _burn(lienId);
    }

    s.TRANSFER_PROXY.tokenTransferFrom(s.WETH, payer, payee, amountSpent);

    emit Payment(lienId, amountSpent);
    return amountSpent;
  }

  /**

   * @notice Have a specified payer make a payment for the debt against a CollateralToken.
   * @param stack the stack for the payment
   * @param totalCapitalAvailable The amount to pay against the debts
   */
  function _makePayment(
    LienEvent[] calldata stack,
    uint256 totalCapitalAvailable
  ) internal {
    LienStorage storage s = _loadLienStorageSlot();
    uint256[] memory openLiens = s.liens[stack[0].collateralId];
    uint256 amount = totalCapitalAvailable;
    for (uint256 i = 0; i < openLiens.length; ++i) {
      uint256 lienId = validateLien(stack[i]);
      require(lienId == openLiens[i], "stack mismatch");
      uint256 capitalSpent = _payment2(
        s,
        stack[i],
        amount,
        address(msg.sender)
      );
      amount -= capitalSpent;
    }
  }

  function makePayment(
    LienEvent calldata lien,
    uint256 paymentAmount,
    address payer
  ) public requiresAuth {
    _payment2(_loadLienStorageSlot(), lien, paymentAmount, payer);
  }

  /**
   * @notice Computes the rate for a specified lien.
   * @param lien The LienEvent to compute the slope for.
   * @return The rate for the specified lien, in WETH per second.
   */
  function calculateSlope(LienEvent calldata lien)
    public
    view
    returns (uint256)
  {
    uint256 lienId = validateLien(lien);

    LienStorage storage s = _loadLienStorageSlot();

    LienDataPoint memory point = s.lienData[lienId];
    uint256 owedAtEnd = _getOwed(point, lien, lien.end);
    return (owedAtEnd - point.amount).mulDivDown(1, lien.end - point.last);
  }

  //  /**
  //   * @notice Computes the total amount owed on all liens against a CollateralToken.
  //   * @param collateralId The ID of the underlying CollateralToken.
  //   * @return totalDebt The aggregate debt for all loans against the collateral.
  //   */
  //  function getTotalDebtForCollateralToken(uint256 collateralId)
  //    public
  //    view
  //    returns (uint256 totalDebt)
  //  {
  //    LienStorage storage s = _loadLienStorageSlot();
  //
  //    uint256[] memory openLiens = s.liens[collateralId];
  //    totalDebt = 0;
  //    for (uint256 i = 0; i < openLiens.length; ++i) {
  //      totalDebt += _getOwed(s.lienData[openLiens[i]]);
  //    }
  //  }

  modifier validateStack(uint256 collateralId, LienEvent[] calldata stack) {
    LienStorage storage s = _loadLienStorageSlot();
    require(s.liens[collateralId].length == stack.length);
    for (uint256 i = 0; i < stack.length; ++i) {
      require(s.liens[collateralId][i] == validateLien(stack[i]));
    }
    _;
  }

  /**
   * @notice Computes the total amount owed on all liens against a CollateralToken.
   * @param collateralId The ID of the underlying CollateralToken.
   * @return maxPotentialDebt the total possible debt for the collateral
   */
  function getMaxPotentialDebtForCollateral(
    uint256 collateralId,
    LienEvent[] calldata stack
  ) public view returns (uint256 maxPotentialDebt) {
    LienStorage storage s = _loadLienStorageSlot();

    maxPotentialDebt = 0;
    uint256[] memory openLiens = s.liens[collateralId];
    for (uint256 i = 0; i < openLiens.length; ++i) {
      LienDataPoint memory point = s.lienData[openLiens[i]];
      maxPotentialDebt += _getOwed(point, stack[i], stack[i].end);
    }
  }

  //  /**
  //   * @notice Computes the total amount owed on all liens against a CollateralToken at a specified timestamp.
  //   * @param collateralId The ID of the underlying CollateralToken.
  //   * @param timestamp The timestamp to use to calculate owed debt.
  //   * @return totalDebt The aggregate debt for all loans against the specified collateral at the specified timestamp.
  //   */
  //  function getTotalDebtForCollateralToken(
  //    uint256 collateralId,
  //    uint256 timestamp
  //  ) public view returns (uint256 totalDebt) {
  //    uint256[] memory openLiens = getLiens(collateralId);
  //    totalDebt = 0;
  //
  //    LienStorage storage s = _loadLienStorageSlot();
  //
  //    for (uint256 i = 0; i < openLiens.length; ++i) {
  //      totalDebt += _getOwed(s.lienData[openLiens[i]], timestamp);
  //    }
  //  }

  //  /**
  //   * @notice Computes the combined rate of all liens against a CollateralToken
  //   * @param collateralId The ID of the underlying CollateralToken.
  //   * @return impliedRate The aggregate rate for all loans against the specified collateral.
  //   */
  //  function getImpliedRate(uint256 collateralId)
  //    public
  //    view
  //    returns (uint256 impliedRate)
  //  {
  //    uint256 totalDebt = getTotalDebtForCollateralToken(collateralId);
  //    uint256[] memory openLiens = getLiens(collateralId);
  //    impliedRate = 0;
  //    for (uint256 i = 0; i < openLiens.length; ++i) {
  //      Lien memory lien = lienData[openLiens[i]];
  //
  //      impliedRate += lien.rate * lien.amount;
  //    }
  //
  //    if (totalDebt > uint256(0)) {
  //      impliedRate = impliedRate.mulDivDown(1, totalDebt);
  //    }
  //  }

  function getAccruedSinceLastPayment(LienEvent calldata lien)
    external
    view
    returns (uint256)
  {
    LienStorage storage s = _loadLienStorageSlot();
    uint256 lienId = validateLien(lien);
    LienDataPoint memory point = s.lienData[lienId];
    return _getOwed(point, lien, point.last);
  }

  function getOwed(LienEvent calldata lien, uint256 timestamp)
    external
    view
    returns (uint192)
  {
    uint256 lienId = validateLien(lien);
    return _getOwed(_loadLienStorageSlot().lienData[lienId], lien, timestamp);
  }

  function getOwed(LienEvent calldata lien) external view returns (uint192) {
    uint256 lienId = validateLien(lien);
    return
      _getOwed(_loadLienStorageSlot().lienData[lienId], lien, block.timestamp);
  }

  //  /**
  //   * @dev Computes the debt owed to a Lien.
  //   * @param lien The specified Lien.
  //   * @return The amount owed to the specified Lien.
  //   */
  //  function _getOwed(LienEvent memory lien) internal view returns (uint256) {
  //    uint256 lienId = _validateLienEvent(lien);
  //    LienDataPoint memory point = _loadLienStorageSlot().lienData[];
  //    return _getOwed(point, lien, block.timestamp);
  //  }

  function _getOwed(LienDataPoint memory point, LienEvent calldata lien)
    internal
    view
    returns (uint192)
  {
    return _getOwed(point, lien, block.timestamp);
  }

  /**
   * @dev Computes the debt owed to a Lien at a specified timestamp.
   * @param lien The specified Lien.
   * @return The amount owed to the Lien at the specified timestamp.
   */
  function _getOwed(
    LienDataPoint memory point,
    LienEvent calldata lien,
    uint256 timestamp
  ) internal pure returns (uint192) {
    return point.amount + _getInterest(point, lien, timestamp).safeCastTo192();
  }

  /**
   * @dev Computes the interest still owed to a Lien.
   * @param s active storage slot
   * @param point The specified LienDataPoint.
   * @param lienEvent the lienEvent
   * @param buyout compute with a ceiling based on the buyout interest window
   * @return The WETH still owed in interest to the Lien.
   */
  function _getRemainingInterest(
    LienStorage storage s,
    LienDataPoint memory point,
    LienEvent memory lienEvent,
    bool buyout
  ) internal view returns (uint256) {
    uint256 end = lienEvent.end;
    if (buyout) {
      uint32 buyoutInterestWindow = s.ASTARIA_ROUTER.getBuyoutInterestWindow();
      if (end >= block.timestamp + buyoutInterestWindow) {
        end = block.timestamp + buyoutInterestWindow;
      }
    }

    uint256 delta_t = end - block.timestamp;

    return
      delta_t.mulDivDown(lienEvent.details.rate, 1).mulWadDown(point.amount);
  }

  //  function getInterest(uint256 lienId) public view returns (uint256) {
  //    return
  //      _getInterest(_loadLienStorageSlot().lienData[lienId], block.timestamp);
  //  }

  //  /**
  //   * @dev Make a payment from a payer to a specific lien against a CollateralToken.
  //   * @param collateralId The ID of the underlying CollateralToken.
  //   * @param position The position of the lien to make a payment to.
  //   * @param paymentAmount The amount to pay against the debt.
  //   * @param payer The address to make the payment.
  //   * @return amountSpent The amount actually spent for the payment.
  //   */
  //  function _payment(
  //    LienStorage storage s,
  //    uint256 collateralId,
  //    uint8 position,
  //    uint256 paymentAmount,
  //    address payer
  //  ) internal returns (uint256 amountSpent) {
  //    if (paymentAmount == uint256(0)) {
  //      return uint256(0);
  //    }
  //
  //    uint256 lienId = s.liens[collateralId][position];
  //    if (!_exists(lienId)) {
  //      revert InvalidState(InvalidStates.INVALID_LIEN_ID);
  //    }
  //
  //    LienDataPoint storage point = s.lienData[lienId];
  //    bool isAuctionHouse = address(msg.sender) == address(s.AUCTION_HOUSE);
  //
  //    if (block.timestamp > lien.end && !isAuctionHouse) {
  //      revert InvalidLoanState();
  //    }
  //
  //    address lienOwner = ownerOf(lienId);
  //    bool isPublicVault = IPublicVault(lienOwner).supportsInterface(
  //      type(IPublicVault).interfaceId
  //    );
  //
  //    point.amount = _getOwed(point, lien);
  //
  //    address payee = getPayee(lienId);
  //
  //    if (isPublicVault && !isAuctionHouse) {
  //      IPublicVault(lienOwner).beforePayment(lienId, paymentAmount);
  //    }
  //    if (point.amount > paymentAmount) {
  //      point.amount -= paymentAmount;
  //      amountSpent = paymentAmount;
  //      point.last = block.timestamp;
  //      // slope does not need to be updated if paying off the rest, since we neutralize slope in beforePayment()
  //
  //      if (isPublicVault && !isAuctionHouse) {
  //        IPublicVault(lienOwner).afterPayment(lienId);
  //      }
  //    } else {
  //      amountSpent = point.amount;
  //      if (isPublicVault && !s.AUCTION_HOUSE.auctionExists(collateralId)) {
  //        // since the openLiens count is only positive when there are liens that haven't been paid off
  //        // that should be liquidated, this lien should not be counted anymore
  //        IPublicVault(lienOwner).decreaseEpochLienCount(
  //          IPublicVault(lienOwner).getLienEpoch(point.epochEnd)
  //        );
  //      }
  //      //delete liens
  //      _deleteLienPosition(s, collateralId, position);
  //      delete s.lienData[lienId]; //full delete
  //
  //      _burn(lienId);
  //    }
  //
  //    s.TRANSFER_PROXY.tokenTransferFrom(s.WETH, payer, payee, amountSpent);
  //
  //    emit Payment(lienId, amountSpent);
  //  }

  /**
   * @dev Make a payment from a payer to a specific lien against a CollateralToken.
   * @param lien The position of the lien to make a payment to.
   * @param amount The amount to pay against the debt.
   * @param payer The address to make the payment.
   * @return amountSpent The amount actually spent for the payment.
   */
  function _payment2(
    LienStorage storage s,
    LienEvent calldata lien,
    uint256 amount,
    address payer
  ) internal returns (uint256) {
    if (amount == uint256(0)) {
      return uint256(0);
    }

    uint256 lienId = validateLien(lien);

    LienDataPoint storage point = s.lienData[lienId];

    // Blocking off payments for a lien that has exceeded the lien.end to prevent repayment unless the msg.sender() is the AuctionHouse
    if (block.timestamp > lien.end) {
      revert InvalidLoanState();
    }

    address lienOwner = ownerOf(lienId);
    bool isPublicVault = _isPublicVault(lienOwner);

    address payee = getPayee(lienId);
    uint256 owed = _getOwed(point, lien);

    if (amount > owed) amount = owed;
    if (isPublicVault) {
      IPublicVault(lienOwner).beforePayment(
        IPublicVault.BeforePaymentParams({
          interestOwed: owed - point.amount,
          amount: point.amount,
          lienSlope: calculateSlope(lien)
        })
      );
    }
    point.amount = owed.safeCastTo192();
    point.last = block.timestamp.safeCastTo40();
    if (point.amount > amount) {
      point.amount -= amount.safeCastTo192();
      // slope does not need to be updated if paying off the rest, since we neutralize slope in beforePayment()
      if (isPublicVault) {
        IPublicVault(lienOwner).afterPayment(calculateSlope(lien));
      }
    } else {
      amount = point.amount;
      if (isPublicVault) {
        // since the openLiens count is only positive when there are liens that haven't been paid off
        // that should be liquidated, this lien should not be counted anymore
        IPublicVault(lienOwner).decreaseEpochLienCount(
          IPublicVault(lienOwner).getLienEpoch(lien.end)
        );
      }
      //delete liens
      _deleteLienPosition(s, lien.collateralId, lien.position);
      delete s.lienData[lienId]; //full delete

      _burn(lienId);
    }

    s.TRANSFER_PROXY.tokenTransferFrom(s.WETH, payer, payee, amount);

    emit Payment(lienId, amount);
    return amount;
  }

  function _deleteLienPosition(
    LienStorage storage s,
    uint256 collateralId,
    uint256 position
  ) internal {
    uint256[] storage stack = s.liens[collateralId];
    require(position < stack.length);

    emit RemoveLien(stack[position], collateralId, uint8(position));
    for (uint256 i = position; i < stack.length - 1; i++) {
      stack[i] = stack[i + 1];
    }
    stack.pop();
  }

  function _isPublicVault(address account) internal view returns (bool) {
    return
      IPublicVault(account).supportsInterface(type(IPublicVault).interfaceId);
  }

  /**
   * @notice Retrieve the payee (address that receives payments and auction funds) for a specified Lien.
   * @param lienId The ID of the Lien.
   * @return The address of the payee for the Lien.
   */
  function getPayee(uint256 lienId) public view returns (address) {
    LienStorage storage s = _loadLienStorageSlot();

    return s.payee[lienId] != address(0) ? s.payee[lienId] : ownerOf(lienId);
  }

  /**
   * @notice Change the payee for a specified Lien.
   * @param lien the lienevent
   * @param newPayee The new Lien payee.
   */
  function setPayee(LienEvent calldata lien, address newPayee) public {
    LienStorage storage s = _loadLienStorageSlot();
    uint256 lienId = validateLien(lien);
    if (s.AUCTION_HOUSE.auctionExists(lien.collateralId)) {
      // todo can we get rid of this check somewhere here
      revert InvalidState(InvalidStates.COLLATERAL_AUCTION);
    }

    require(
      msg.sender == ownerOf(lienId) || msg.sender == address(s.ASTARIA_ROUTER)
    );

    s.payee[lienId] = newPayee;
    emit PayeeChanged(lienId, newPayee);
  }
}
