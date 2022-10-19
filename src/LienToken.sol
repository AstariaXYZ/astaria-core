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
import {IERC721, IERC165} from "gpl/interfaces/IERC721.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {Base64} from "./libraries/Base64.sol";
import {CollateralLookup} from "./libraries/CollateralLookup.sol";

import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "./interfaces/ICollateralToken.sol";
import {ILienBase, ILienToken} from "./interfaces/ILienToken.sol";

import {IPublicVault} from "./PublicVault.sol";
import {VaultImplementation} from "./VaultImplementation.sol";

contract TransferAgent {
  address public immutable WETH;
  ITransferProxy public immutable TRANSFER_PROXY;

  constructor(ITransferProxy _TRANSFER_PROXY, address _WETH) {
    TRANSFER_PROXY = _TRANSFER_PROXY;
    WETH = _WETH;
  }
}

/**
 * @title LienToken
 * @author androolloyd
 * @notice This contract handles the creation, payments, buyouts, and liquidations of tokenized NFT-collateralized debt (liens). Vaults which originate loans against supported collateral are issued a LienToken representing the right to loan repayments and auctioned funds on liquidation.
 */
contract LienToken is ERC721, ILienToken, Auth, TransferAgent {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeCastLib for uint256;

  IAuctionHouse public AUCTION_HOUSE;
  IAstariaRouter public ASTARIA_ROUTER;
  ICollateralToken public COLLATERAL_TOKEN;

  uint256 INTEREST_DENOMINATOR = 1e18; //wad per second

  uint256 constant MAX_LIENS = uint256(5);

  mapping(uint256 => Lien) public lienData;
  mapping(uint256 => uint256[]) public liens;

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
  )
    Auth(address(msg.sender), _AUTHORITY)
    TransferAgent(_TRANSFER_PROXY, _WETH)
    ERC721("Astaria Lien Token", "ALT")
  {}

  /**
   * @notice Sets addresses for the AuctionHouse, CollateralToken, and AstariaRouter contracts to use.
   * @param what The identifier for what is being filed.
   * @param data The encoded address data to be decoded and filed.
   */
  function file(bytes32 what, bytes calldata data) external requiresAuth {
    if (what == "setAuctionHouse") {
      address addr = abi.decode(data, (address));
      AUCTION_HOUSE = IAuctionHouse(addr);
    } else if (what == "setCollateralToken") {
      address addr = abi.decode(data, (address));
      COLLATERAL_TOKEN = ICollateralToken(addr);
    } else if (what == "setAstariaRouter") {
      address addr = abi.decode(data, (address));
      ASTARIA_ROUTER = IAstariaRouter(addr);
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

  /**
   * @notice Purchase a LienToken for its buyout price.
   * @param params The LienActionBuyout data specifying the lien position, receiver address, and underlying CollateralToken information of the lien.
   */

  function buyoutLien(ILienToken.LienActionBuyout calldata params) external {
    (bool valid, IAstariaRouter.LienDetails memory ld) = ASTARIA_ROUTER
      .validateCommitment(params.incoming);

    if (!valid) {
      revert InvalidTerms();
    }

    uint256 collateralId = params.incoming.tokenContract.computeId(
      params.incoming.tokenId
    );
    (uint256 owed, uint256 buyout) = getBuyout(collateralId, params.position);
    uint256 lienId = liens[collateralId][params.position];

    //the borrower shouldn't incur more debt from the buyout than they already owe
    if (ld.maxAmount < owed) {
      revert InvalidBuyoutDetails(ld.maxAmount, owed);
    }
    if (!ASTARIA_ROUTER.isValidRefinance(lienData[lienId], ld)) {
      revert InvalidRefinance();
    }

    TRANSFER_PROXY.tokenTransferFrom(
      WETH,
      address(msg.sender),
      getPayee(lienId),
      uint256(buyout)
    );

    lienData[lienId].last = block.timestamp.safeCastTo32();
    lienData[lienId].start = block.timestamp.safeCastTo32();
    lienData[lienId].rate = ld.rate.safeCastTo240();
    lienData[lienId].duration = ld.duration.safeCastTo32();

    _transfer(ownerOf(lienId), address(params.receiver), lienId);
  }

  /**
   * @notice Public view function that computes the interest for a LienToken since its last payment.
   * @param collateralId The ID of the underlying CollateralToken
   * @param position The position of the lien to calculate interest for.
   */
  function getInterest(uint256 collateralId, uint256 position)
    public
    view
    returns (uint256)
  {
    uint256 lien = liens[collateralId][position];
    return _getInterest(lienData[lien], block.timestamp);
  }

  /**
   * @dev Computes the interest accrued for a lien since its last payment.
   * @param lien The Lien for the loan to calculate interest for.
   * @param timestamp The timestamp at which to compute interest for.
   */
  function _getInterest(Lien memory lien, uint256 timestamp)
    internal
    view
    returns (uint256)
  {
    if (!lien.active) {
      return uint256(0);
    }
    uint256 delta_t;
    if (block.timestamp >= lien.start + lien.duration) {
      delta_t = uint256(lien.start + lien.duration - lien.last);
    } else {
      delta_t = uint256(timestamp.safeCastTo32() - lien.last);
    }
    return
      delta_t.mulDivDown(lien.rate, 1).mulDivDown(
        lien.amount,
        INTEREST_DENOMINATOR
      );
  }

  /**
   * @notice Stops accruing interest for all liens against a single CollateralToken.
   * @param collateralId The ID for the  CollateralToken of the NFT used as collateral for the liens.
   */
  function stopLiens(uint256 collateralId)
    external
    requiresAuth
    returns (uint256 reserve, uint256[] memory lienIds)
  {
    reserve = 0;
    lienIds = liens[collateralId];
    for (uint256 i = 0; i < lienIds.length; ++i) {
      Lien storage lien = lienData[lienIds[i]];
      unchecked {
        lien.amount = _getOwed(lien);
        reserve += lien.amount;
      }
      lien.active = false;
    }
  }

  /**
   * @dev See {IERC721Metadata-tokenURI}.
   */
  function tokenURI(uint256 tokenId)
    public
    pure
    override
    returns (string memory)
  {
    return "";
  }

  /**
   * @notice Creates a new lien against a CollateralToken.
   * @param params LienActionEncumber data containing CollateralToken information and lien parameters (rate, duration, and amount, rate, and debt caps).
   */
  function createLien(ILienBase.LienActionEncumber memory params)
    external
    requiresAuth
    returns (uint256 lienId)
  {
    // require that the auction is not under way

    uint256 collateralId = params.tokenContract.computeId(params.tokenId);

    if (AUCTION_HOUSE.auctionExists(collateralId)) {
      revert InvalidCollateralState(InvalidStates.AUCTION);
    }

    (address tokenContract, ) = COLLATERAL_TOKEN.getUnderlying(collateralId);
    if (tokenContract == address(0)) {
      revert InvalidCollateralState(InvalidStates.NO_DEPOSIT);
    }

    uint256 totalDebt = getTotalDebtForCollateralToken(collateralId);
    uint256 impliedRate = getImpliedRate(collateralId);

    uint256 potentialDebt = totalDebt *
      (impliedRate + 1) *
      params.terms.duration;

    if (potentialDebt > params.terms.maxPotentialDebt) {
      revert InvalidCollateralState(InvalidStates.DEBT_LIMIT);
    }

    lienId = uint256(
      keccak256(
        abi.encodePacked(
          abi.encode(
            bytes32(collateralId),
            params.vault,
            WETH,
            params.terms.maxAmount,
            params.terms.rate,
            params.terms.duration,
            params.terms.maxPotentialDebt
          ),
          params.strategyRoot
        )
      )
    );

    //0 - 4 are valid
    require(
      uint256(liens[collateralId].length) < MAX_LIENS,
      "too many liens active"
    );

    uint8 newPosition = uint8(liens[collateralId].length);

    _mint(VaultImplementation(params.vault).recipient(), lienId);
    lienData[lienId] = Lien({
      collateralId: collateralId,
      position: newPosition,
      amount: params.amount,
      active: true,
      rate: params.terms.rate.safeCastTo240(),
      last: block.timestamp.safeCastTo32(),
      start: block.timestamp.safeCastTo32(),
      duration: params.terms.duration.safeCastTo32(),
      payee: address(0)
    });

    liens[collateralId].push(lienId);
    emit NewLien(lienId, lienData[lienId]);
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
    for (uint256 i = 0; i < remainingLiens.length; i++) {
      delete lienData[remainingLiens[i]];
      _burn(remainingLiens[i]);
    }
    delete liens[collateralId];
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
    return liens[collateralId];
  }

  /**
   * @notice Retrieves a specific Lien by its ID.
   * @param lienId The ID of the requested Lien.
   * @return lien The Lien for the lienId.
   */
  function getLien(uint256 lienId) public view returns (Lien memory lien) {
    lien = lienData[lienId];
    lien.amount = _getOwed(lien);
    lien.last = block.timestamp.safeCastTo32();
  }

  /**
   * @notice Retrives a specific Lien from the ID of the CollateralToken for the underlying NFT and the lien position.
   * @param collateralId The ID for the underlying CollateralToken.
   * @param position The requested lien position.
   *  @ return lien The Lien for the lienId.
   */
  function getLien(uint256 collateralId, uint256 position)
    public
    view
    returns (Lien memory)
  {
    uint256 lienId = liens[collateralId][position];
    return getLien(lienId);
  }

  /**
   * @notice Computes and returns the buyout amount for a Lien.
   * @param collateralId The ID for the underlying CollateralToken.
   * @param position The position of the Lien to compute the buyout amount for.
   * @return The outstanding debt for the lien and the buyout amount for the Lien.
   */
  function getBuyout(uint256 collateralId, uint256 position)
    public
    view
    returns (uint256, uint256)
  {
    Lien memory lien = getLien(collateralId, position);

    uint256 remainingInterest = _getRemainingInterest(lien, true);
    uint256 buyoutTotal = lien.amount +
      ASTARIA_ROUTER.getBuyoutFee(remainingInterest);

    return (lien.amount, buyoutTotal);
  }

  /**
   * @notice Make a payment for the debt against a CollateralToken.
   * @param collateralId The ID of the underlying CollateralToken.
   * @param paymentAmount The amount to pay against the debt.
   */
  function makePayment(uint256 collateralId, uint256 paymentAmount) public {
    _makePayment(collateralId, paymentAmount);
  }

  /**
   * @notice Make a payment for the debt against a CollateralToken for a specific lien.
   * @param collateralId The ID of the underlying CollateralToken.
   * @param paymentAmount The amount to pay against the debt.
   * @param position The lien position to make a payment to.
   */
  function makePayment(
    uint256 collateralId,
    uint256 paymentAmount,
    uint8 position
  ) external {
    _payment(collateralId, position, paymentAmount, address(msg.sender));
  }

  /**
   * @notice Have a specified paymer make a payment for the debt against a CollateralToken.
   * @param collateralId The ID of the underlying CollateralToken.
   * @param totalCapitalAvailable The amount to pay against the debts
   */
  function _makePayment(uint256 collateralId, uint256 totalCapitalAvailable)
    internal
  {
    uint256[] memory openLiens = liens[collateralId];
    uint256 paymentAmount = totalCapitalAvailable;
    for (uint256 i = 0; i < openLiens.length; ++i) {
      uint256 capitalSpent = _payment(
        collateralId,
        uint8(i),
        paymentAmount,
        address(msg.sender)
      );
      paymentAmount -= capitalSpent;
    }
  }

  function makePayment(
    uint256 collateralId,
    uint256 paymentAmount,
    uint8 position,
    address payer
  ) public requiresAuth {
    _payment(collateralId, position, paymentAmount, payer);
  }

  /**
   * @notice Computes the rate for a specified lien.
   * @param lienId The ID for the lien.
   * @return The rate for the specified lien, in WETH per second.
   */
  function calculateSlope(uint256 lienId) public view returns (uint256) {
    Lien memory lien = lienData[lienId];
    uint256 end = (lien.start + lien.duration);
    uint256 owedAtEnd = _getOwed(lien, end);
    return (owedAtEnd - lien.amount).mulDivDown(1, end - lien.last);
  }

  /**
   * @notice Computes the change in rate for a lien if a specific payment amount was made.
   * @param lienId The ID for the lien.
   * @param paymentAmount The hypothetical payment amount that would be made to the lien.
   * @return slope The difference between the current lien rate and the lien rate if the payment was made.
   */
  function changeInSlope(uint256 lienId, uint256 paymentAmount)
    public
    view
    returns (uint256 slope)
  {
    Lien memory lien = lienData[lienId];
    uint256 oldSlope = calculateSlope(lienId);
    uint256 newAmount = (lien.amount - paymentAmount);

    // slope = (rate*time*amount - amount) / time -> amount(rate*time - 1) / time
    uint256 newSlope = newAmount.mulDivDown(
      (uint256(lien.rate).mulDivDown(lien.duration, 1) - 1),
      lien.duration
    );

    slope = oldSlope - newSlope;
  }

  /**
   * @notice Computes the total amount owed on all liens against a CollateralToken.
   * @param collateralId The ID of the underlying CollateralToken.
   * @return totalDebt The aggregate debt for all loans against the collateral.
   */
  function getTotalDebtForCollateralToken(uint256 collateralId)
    public
    view
    returns (uint256 totalDebt)
  {
    uint256[] memory openLiens = getLiens(collateralId);
    totalDebt = 0;
    for (uint256 i = 0; i < openLiens.length; ++i) {
      totalDebt += _getOwed(lienData[openLiens[i]]);
    }
  }

  /**
   * @notice Computes the total amount owed on all liens against a CollateralToken at a specified timestamp.
   * @param collateralId The ID of the underlying CollateralToken.
   * @param timestamp The timestamp to use to calculate owed debt.
   * @return totalDebt The aggregate debt for all loans against the specified collateral at the specified timestamp.
   */
  function getTotalDebtForCollateralToken(
    uint256 collateralId,
    uint256 timestamp
  ) public view returns (uint256 totalDebt) {
    uint256[] memory openLiens = getLiens(collateralId);
    totalDebt = 0;

    for (uint256 i = 0; i < openLiens.length; ++i) {
      totalDebt += _getOwed(lienData[openLiens[i]], timestamp);
    }
  }

  /**
   * @notice Computes the combined rate of all liens against a CollateralToken
   * @param collateralId The ID of the underlying CollateralToken.
   * @return impliedRate The aggregate rate for all loans against the specified collateral.
   */
  function getImpliedRate(uint256 collateralId)
    public
    view
    returns (uint256 impliedRate)
  {
    uint256 totalDebt = getTotalDebtForCollateralToken(collateralId);
    uint256[] memory openLiens = getLiens(collateralId);
    impliedRate = 0;
    for (uint256 i = 0; i < openLiens.length; ++i) {
      Lien memory lien = lienData[openLiens[i]];

      impliedRate += lien.rate * lien.amount;
    }

    if (totalDebt > uint256(0)) {
      impliedRate = impliedRate.mulDivDown(1, totalDebt);
    }
  }

  /**
   * @dev Computes the debt owed to a Lien.
   * @param lien The specified Lien.
   * @return The amount owed to the specified Lien.
   */
  function _getOwed(Lien memory lien) internal view returns (uint256) {
    return _getOwed(lien, block.timestamp);
  }

  /**
   * @dev Computes the debt owed to a Lien at a specified timestamp.
   * @param lien The specified Lien.
   * @return The amount owed to the Lien at the specified timestamp.
   */
  function _getOwed(Lien memory lien, uint256 timestamp)
    internal
    view
    returns (uint256)
  {
    return lien.amount + _getInterest(lien, timestamp);
  }

  /**
   * @dev Computes the interest still owed to a Lien.
   * @param lien The specified Lien.
   * @param buyout compute with a ceiling based on the buyout interest window
   * @return The WETH still owed in interest to the Lien.
   */
  function _getRemainingInterest(Lien memory lien, bool buyout)
    internal
    view
    returns (uint256)
  {
    uint256 end = lien.start + lien.duration;
    if (buyout) {
      uint32 getBuyoutInterestWindow = ASTARIA_ROUTER.getBuyoutInterestWindow();
      if (
        lien.start + lien.duration >= block.timestamp + getBuyoutInterestWindow
      ) {
        end = block.timestamp + getBuyoutInterestWindow;
      }
    }

    uint256 delta_t = end - block.timestamp;

    return
      delta_t.mulDivDown(lien.rate, 1).mulDivDown(
        lien.amount,
        INTEREST_DENOMINATOR
      );
  }

  function getInterest(uint256 lienId) public view returns (uint256) {
    return _getInterest(lienData[lienId], block.timestamp);
  }

  /**
   * @dev Make a payment from a payer to a specific lien against a CollateralToken.
   * @param collateralId The ID of the underlying CollateralToken.
   * @param position The position of the lien to make a payment to.
   * @param paymentAmount The amount to pay against the debt.
   * @param payer The address to make the payment.
   * @return The paymentAmount for the payment.
   */
  function _payment(
    uint256 collateralId,
    uint8 position,
    uint256 paymentAmount,
    address payer
  ) internal returns (uint256) {
    if (paymentAmount == uint256(0)) {
      return uint256(0);
    }

    uint256 lienId = liens[collateralId][position];
    Lien storage lien = lienData[lienId];
    uint256 end = (lien.start + lien.duration);
    require(
      block.timestamp < end || address(msg.sender) == address(AUCTION_HOUSE),
      "cannot pay off an expired lien"
    );

    address lienOwner = ownerOf(lienId);
    bool isPublicVault = IPublicVault(lienOwner).supportsInterface(
      type(IPublicVault).interfaceId
    );

    lien.amount = _getOwed(lien);

    address payee = getPayee(lienId);
    if (isPublicVault) {
      IPublicVault(lienOwner).beforePayment(lienId, paymentAmount);
    }
    if (lien.amount > paymentAmount) {
      lien.amount -= paymentAmount;
      lien.last = block.timestamp.safeCastTo32();
      // slope does not need to be updated if paying off the rest, since we neutralize slope in beforePayment()
      if (isPublicVault) {
        IPublicVault(lienOwner).afterPayment(lienId);
      }
    } else {
      if (isPublicVault && !AUCTION_HOUSE.auctionExists(collateralId)) {
        // since the openLiens count is only positive when there are liens that haven't been paid off
        // that should be liquidated, this lien should not be counted anymore
        IPublicVault(lienOwner).decreaseEpochLienCount(
          IPublicVault(lienOwner).getLienEpoch(end)
        );
      }
      //delete liens
      _deleteLienPosition(collateralId, position);
      delete lienData[lienId]; //full delete

      _burn(lienId);
    }

    TRANSFER_PROXY.tokenTransferFrom(WETH, payer, payee, paymentAmount);

    emit Payment(lienId, paymentAmount);
    return paymentAmount;
  }

  function _deleteLienPosition(uint256 collateralId, uint256 position) public {
    uint256[] storage stack = liens[collateralId];
    require(position < stack.length, "index out of bounds");

    emit RemoveLien(
      stack[position],
      lienData[stack[position]].collateralId,
      lienData[stack[position]].position
    );
    for (uint256 i = position; i < stack.length - 1; i++) {
      stack[i] = stack[i + 1];
    }
    stack.pop();
  }

  /**
   * @notice Retrieve the payee (address that receives payments and auction funds) for a specified Lien.
   * @param lienId The ID of the Lien.
   * @return The address of the payee for the Lien.
   */
  function getPayee(uint256 lienId) public view returns (address) {
    return
      lienData[lienId].payee != address(0)
        ? lienData[lienId].payee
        : ownerOf(lienId);
  }

  /**
   * @notice Change the payee for a specified Lien.
   * @param lienId The ID of the Lien.
   * @param newPayee The new Lien payee.
   */
  function setPayee(uint256 lienId, address newPayee) public {
    if (AUCTION_HOUSE.auctionExists(lienData[lienId].collateralId)) {
      revert InvalidCollateralState(InvalidStates.AUCTION);
    }
    require(
      !AUCTION_HOUSE.auctionExists(lienData[lienId].collateralId),
      "collateralId is being liquidated, cannot change payee from LiquidationAccountant"
    );
    require(
      msg.sender == ownerOf(lienId) || msg.sender == address(ASTARIA_ROUTER),
      "invalid owner"
    );

    lienData[lienId].payee = newPayee;
    emit PayeeChanged(lienId, newPayee);
  }
}
