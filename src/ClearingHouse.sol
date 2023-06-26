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

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Clone} from "create2-clones-with-immutable-args/Clone.sol";
import {IERC1155} from "core/interfaces/IERC1155.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";
import {
  ConduitControllerInterface
} from "seaport/interfaces/ConduitControllerInterface.sol";
import {AmountDeriver} from "seaport/lib/AmountDeriver.sol";
import {Order} from "seaport/lib/ConsiderationStructs.sol";
import {IERC721Receiver} from "core/interfaces/IERC721Receiver.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {
  ConsiderationInterface
} from "seaport/interfaces/ConsiderationInterface.sol";

contract ClearingHouse is AmountDeriver, Clone, IERC1155, IERC721Receiver {
  using Bytes32AddressLib for bytes32;
  using SafeTransferLib for ERC20;
  struct AuctionStack {
    uint256 lienId;
    uint256 amountOwed;
    uint40 end;
  }

  struct AuctionData {
    uint256 startAmount;
    uint256 endAmount;
    uint48 startTime;
    uint48 endTime;
    address liquidator;
    address token;
    AuctionStack stack;
  }

  struct ClearingHouseStorage {
    AuctionData auctionData;
  }
  enum InvalidRequestReason {
    NOT_ENOUGH_FUNDS_RECEIVED,
    NO_AUCTION,
    INVALID_ORDER
  }
  error InvalidRequest(InvalidRequestReason);

  uint256 private constant CLEARING_HOUSE_STORAGE_SLOT =
    uint256(keccak256("xyz.astaria.ClearingHouse.storage.location")) - 1;

  function ROUTER() public pure returns (IAstariaRouter) {
    return IAstariaRouter(_getArgAddress(0));
  }

  function COLLATERAL_ID() public pure returns (uint256) {
    return _getArgUint256(21);
  }

  function IMPL_TYPE() public pure returns (uint8) {
    return _getArgUint8(20);
  }

  function _getStorage()
    internal
    pure
    returns (ClearingHouseStorage storage s)
  {
    uint256 slot = CLEARING_HOUSE_STORAGE_SLOT;
    assembly {
      s.slot := slot
    }
  }

  function setAuctionData(AuctionData calldata auctionData) external {
    IAstariaRouter ASTARIA_ROUTER = IAstariaRouter(_getArgAddress(0)); // get the router from the immutable arg

    //only execute from the lien token
    require(msg.sender == address(ASTARIA_ROUTER.LIEN_TOKEN()));

    ClearingHouseStorage storage s = _getStorage();
    s.auctionData = auctionData;
  }

  function getAuctionData() external view returns (AuctionData memory) {
    return _getStorage().auctionData;
  }

  function supportsInterface(bytes4 interfaceId) external view returns (bool) {
    return interfaceId == type(IERC1155).interfaceId;
  }

  function balanceOf(
    address account,
    uint256 id
  ) external view returns (uint256) {
    return type(uint256).max;
  }

  function balanceOfBatch(
    address[] calldata accounts,
    uint256[] calldata ids
  ) external view returns (uint256[] memory output) {
    output = new uint256[](accounts.length);
    for (uint256 i; i < accounts.length; ) {
      output[i] = type(uint256).max;
      unchecked {
        ++i;
      }
    }
  }

  function setApprovalForAll(address operator, bool approved) external {}

  function isApprovedForAll(
    address account,
    address operator
  ) external view returns (bool) {
    return true;
  }

  function _execute() internal {
    IAstariaRouter ASTARIA_ROUTER = ROUTER(); // get the router from the immutable arg

    ClearingHouseStorage storage s = _getStorage();
    ERC20 paymentToken = ERC20(s.auctionData.token);

    uint256 currentOfferPrice = _locateCurrentAmount({
      startAmount: s.auctionData.startAmount,
      endAmount: s.auctionData.endAmount,
      startTime: s.auctionData.startTime,
      endTime: s.auctionData.endTime,
      roundUp: true //we are a consideration we round up
    });

    if (currentOfferPrice == 0 || block.timestamp > s.auctionData.endTime) {
      revert InvalidRequest(InvalidRequestReason.NO_AUCTION);
    }
    uint256 payment = paymentToken.balanceOf(address(this));
    if (currentOfferPrice > payment) {
      revert InvalidRequest(InvalidRequestReason.NOT_ENOUGH_FUNDS_RECEIVED);
    }

    uint256 collateralId = COLLATERAL_ID();
    // pay liquidator fees here

    AuctionStack memory stack = s.auctionData.stack;

    uint256 liquidatorPayment = ASTARIA_ROUTER.getLiquidatorFee(payment);

    payment -= liquidatorPayment;
    paymentToken.safeTransfer(s.auctionData.liquidator, liquidatorPayment);

    address transferProxy = address(ASTARIA_ROUTER.TRANSFER_PROXY());
    // If existing approval is non-zero -> set it to zero
    if (paymentToken.allowance(address(this), transferProxy) != 0) {
      paymentToken.safeApprove(transferProxy, 0);
    }
    paymentToken.approve(address(transferProxy), payment);

    ASTARIA_ROUTER.LIEN_TOKEN().payDebtViaClearingHouse(
      address(paymentToken),
      collateralId,
      payment,
      stack
    );

    uint256 remainingBalance = paymentToken.balanceOf(address(this));
    if (remainingBalance > 0) {
      paymentToken.safeTransfer(
        ASTARIA_ROUTER.COLLATERAL_TOKEN().ownerOf(collateralId),
        remainingBalance
      );
    }
    ASTARIA_ROUTER.COLLATERAL_TOKEN().settleAuction(collateralId);
    _deleteLocalState();
  }

  function safeTransferFrom(
    address from, // the from is the offerer
    address to,
    uint256 identifier,
    uint256 amount,
    bytes calldata data //empty from seaport
  ) public {
    //data is empty and useless
    ConsiderationInterface seaport = ROUTER().COLLATERAL_TOKEN().SEAPORT();

    ConduitControllerInterface conduitController = ROUTER()
      .COLLATERAL_TOKEN()
      .CONDUIT_CONTROLLER();
    require(
      msg.sender == address(seaport) ||
        conduitController.ownerOf(msg.sender) != address(0),
      "Must be seaport or a seaport conduit"
    );
    _execute();
  }

  function safeBatchTransferFrom(
    address from,
    address to,
    uint256[] calldata ids,
    uint256[] calldata amounts,
    bytes calldata data
  ) public {}

  function onERC721Received(
    address operator_,
    address from_,
    uint256 tokenId_,
    bytes calldata data_
  ) external override returns (bytes4) {
    return IERC721Receiver.onERC721Received.selector;
  }

  function validateOrder(Order memory order) external {
    IAstariaRouter ASTARIA_ROUTER = ROUTER();
    require(msg.sender == address(ASTARIA_ROUTER.COLLATERAL_TOKEN()));
    Order[] memory listings = new Order[](1);
    listings[0] = order;

    ERC721(order.parameters.offer[0].token).approve(
      ASTARIA_ROUTER.COLLATERAL_TOKEN().getConduit(),
      order.parameters.offer[0].identifierOrCriteria
    );
    if (!ASTARIA_ROUTER.COLLATERAL_TOKEN().SEAPORT().validate(listings)) {
      revert InvalidRequest(InvalidRequestReason.INVALID_ORDER);
    }
  }

  function transferUnderlying(
    address tokenContract,
    uint256 tokenId,
    address target
  ) external {
    IAstariaRouter ASTARIA_ROUTER = ROUTER();
    require(msg.sender == address(ASTARIA_ROUTER.COLLATERAL_TOKEN()));
    ERC721(tokenContract).safeTransferFrom(address(this), target, tokenId);
  }

  function settleLiquidatorNFTClaim() external {
    IAstariaRouter ASTARIA_ROUTER = ROUTER();

    require(msg.sender == address(ASTARIA_ROUTER.COLLATERAL_TOKEN()));
    ClearingHouseStorage storage s = _getStorage();
    uint256 collateralId = COLLATERAL_ID();
    ASTARIA_ROUTER.LIEN_TOKEN().payDebtViaClearingHouse(
      address(0),
      collateralId,
      0,
      s.auctionData.stack
    );
    _deleteLocalState();
  }

  function _deleteLocalState() internal {
    ClearingHouseStorage storage s = _getStorage();
    delete s.auctionData;
  }
}
