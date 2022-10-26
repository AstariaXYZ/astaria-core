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

import {IPublicVault} from "./PublicVault.sol";
import {VaultImplementation} from "./VaultImplementation.sol";
import {PublicVault} from "./PublicVault.sol";

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

    if (msg.sender != params.receiver) {
      require(isApprovedForAll[msg.sender][params.receiver]);
    }

    lienData[lienId].last = block.timestamp.safeCastTo64();
    lienData[lienId].end = uint256(block.timestamp + ld.duration)
      .safeCastTo64();
    lienData[lienId].rate = ld.rate.safeCastTo192();

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
    uint256 delta_t = timestamp - lien.last;

    return delta_t.mulDivDown(lien.rate, 1).mulWadDown(lien.amount);
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
      lien.last = block.timestamp.safeCastTo64();
      lien.rate = uint192(0);
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

  /**
   * @notice Creates a new lien against a CollateralToken.
   * @param params LienActionEncumber data containing CollateralToken information and lien parameters (rate, duration, and amount, rate, and debt caps).
   */
  function createLien(ILienToken.LienActionEncumber memory params)
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

    uint256 maxPotentialDebt = getMaxPotentialDebtForCollateral(collateralId);

    if (maxPotentialDebt > params.terms.maxPotentialDebt) {
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

    if (liens[collateralId].length == MAX_LIENS) {
      revert InvalidCollateralState(InvalidStates.MAX_LIENS);
    }

    uint8 newPosition = uint8(liens[collateralId].length);

    _mint(VaultImplementation(params.vault).recipient(), lienId);
    lienData[lienId] = Lien({
      collateralId: collateralId,
      position: newPosition,
      amount: params.amount,
      rate: params.terms.rate.safeCastTo192(),
      last: block.timestamp.safeCastTo64(),
      end: uint256(block.timestamp + params.terms.duration).safeCastTo64(),
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
    lien.last = block.timestamp.safeCastTo64();
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
    uint256 owedAtEnd = _getOwed(lien, lien.end);
    return (owedAtEnd - lien.amount).mulDivDown(1, lien.end - lien.last);
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
   * @notice Computes the total amount owed on all liens against a CollateralToken.
   * @param collateralId The ID of the underlying CollateralToken.
   * @return maxPotentialDebt the total possible debt for the collateral
   */
  function getMaxPotentialDebtForCollateral(uint256 collateralId)
    public
    view
    returns (uint256 maxPotentialDebt)
  {
    maxPotentialDebt = 0;
    uint256[] memory openLiens = getLiens(collateralId);
    for (uint256 i = 0; i < openLiens.length; ++i) {
      Lien memory lien = lienData[openLiens[i]];
      maxPotentialDebt += _getOwed(lien, lien.end);
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

  function getAccruedSinceLastPayment(uint256 lienId)
    external
    view
    returns (uint256)
  {
    Lien memory lien = lienData[lienId];
    //    assert(lien.last == lien.start);
    return _getOwed(lien, lien.last);
  }

  function getOwed(Lien memory lien, uint256 timestamp)
    external
    view
    returns (uint256)
  {
    return _getOwed(lien, timestamp);
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
    uint256 end = lien.end;
    if (buyout) {
      uint32 getBuyoutInterestWindow = ASTARIA_ROUTER.getBuyoutInterestWindow();
      if (end >= block.timestamp + getBuyoutInterestWindow) {
        end = block.timestamp + getBuyoutInterestWindow;
      }
    }

    uint256 delta_t = end - block.timestamp;

    return delta_t.mulDivDown(lien.rate, 1).mulWadDown(lien.amount);
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
   * @return amountSpent The amount actually spent for the payment.
   */
  function _payment(
    uint256 collateralId,
    uint8 position,
    uint256 paymentAmount,
    address payer
  ) internal returns (uint256 amountSpent) {
    if (paymentAmount == uint256(0)) {
      return uint256(0);
    }

    uint256 lienId = liens[collateralId][position];
    Lien storage lien = lienData[lienId];
    bool isAuctionHouse = address(msg.sender) == address(AUCTION_HOUSE);

    if (block.timestamp > lien.end && !isAuctionHouse) {
      revert InvalidLoanState();
    }

    address lienOwner = ownerOf(lienId);
    bool isPublicVault = IPublicVault(lienOwner).supportsInterface(
      type(IPublicVault).interfaceId
    );

    address payee = getPayee(lienId);

    uint256 owed = _getOwed(lien);

    if (paymentAmount > owed) {
      paymentAmount = owed;
    }

    if (isPublicVault && !isAuctionHouse) {
      IPublicVault(lienOwner).beforePayment(lienId, paymentAmount, lien.last);
      IPublicVault(lienOwner).handleStrategistInterestReward(
      lienId,
      lien.amount,
      owed - paymentAmount
    );
    }

    
    lien.amount = owed;

    if (lien.amount > paymentAmount) {
      lien.amount -= paymentAmount;
      amountSpent = paymentAmount;
      lien.last = block.timestamp.safeCastTo64();
      // slope does not need to be updated if paying off the rest, since we neutralize slope in beforePayment()

      if (isPublicVault && !isAuctionHouse) {
        IPublicVault(lienOwner).afterPayment(lienId);
      }
    } else {
      amountSpent = lien.amount;
      if (isPublicVault && !AUCTION_HOUSE.auctionExists(collateralId)) {
        // since the openLiens count is only positive when there are liens that haven't been paid off
        // that should be liquidated, this lien should not be counted anymore
        IPublicVault(lienOwner).decreaseEpochLienCount(
          IPublicVault(lienOwner).getLienEpoch(lien.end)
        );
      }
      //delete liens
      _deleteLienPosition(collateralId, position);
      delete lienData[lienId]; //full delete

      _burn(lienId);
    }

    TRANSFER_PROXY.tokenTransferFrom(WETH, payer, payee, amountSpent);

    emit Payment(lienId, amountSpent);
  }

  function _deleteLienPosition(uint256 collateralId, uint256 position) public {
    uint256[] storage stack = liens[collateralId];
    require(position < stack.length);

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
      msg.sender == ownerOf(lienId) || msg.sender == address(ASTARIA_ROUTER)
    );

    lienData[lienId].payee = newPayee;
    emit PayeeChanged(lienId, newPayee);
  }
}
