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
import {Clone} from "clones-with-immutable-args/Clone.sol";
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

contract ClearingHouse is AmountDeriver, Clone, IERC1155, IERC721Receiver {
  using Bytes32AddressLib for bytes32;
  using SafeTransferLib for ERC20;
  struct AuctionStack {
    uint256 lienId;
    uint88 amountOwed;
    uint40 end;
  }

  struct AuctionData {
    uint88 startAmount;
    uint88 endAmount;
    uint48 startTime;
    uint48 endTime;
    address liquidator;
    address token;
    AuctionStack[] stack;
  }

  struct ClearingHouseStorage {
    AuctionData auctionStack;
  }
  enum InvalidRequestReason {
    NOT_ENOUGH_FUNDS_RECEIVED
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

    //only execute from the conduit
    require(msg.sender == address(ASTARIA_ROUTER.LIEN_TOKEN()));

    ClearingHouseStorage storage s = _getStorage();
    s.auctionStack = auctionData;
  }

  function getAuctionData() external view returns (AuctionData memory) {
    return _getStorage().auctionStack;
  }

  function supportsInterface(bytes4 interfaceId) external view returns (bool) {
    return interfaceId == type(IERC1155).interfaceId;
  }

  function balanceOf(address account, uint256 id)
    external
    view
    returns (uint256)
  {
    return type(uint256).max;
  }

  function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
    external
    view
    returns (uint256[] memory output)
  {
    output = new uint256[](accounts.length);
    for (uint256 i; i < accounts.length; ) {
      output[i] = type(uint256).max;
      unchecked {
        ++i;
      }
    }
  }

  function setApprovalForAll(address operator, bool approved) external {}

  function isApprovedForAll(address account, address operator)
    external
    view
    returns (bool)
  {
    return true;
  }

  function _execute() internal {
    IAstariaRouter ASTARIA_ROUTER = IAstariaRouter(_getArgAddress(0)); // get the router from the immutable arg

    ClearingHouseStorage storage s = _getStorage();
    address paymentToken = s.auctionStack.token;

    uint256 currentOfferPrice = _locateCurrentAmount({
      startAmount: s.auctionStack.startAmount,
      endAmount: s.auctionStack.endAmount,
      startTime: s.auctionStack.startTime,
      endTime: s.auctionStack.endTime,
      roundUp: true //we are a consideration we round up
    });
    uint256 payment = ERC20(paymentToken).balanceOf(address(this));

    if (currentOfferPrice > payment) {
      revert InvalidRequest(InvalidRequestReason.NOT_ENOUGH_FUNDS_RECEIVED);
    }

    uint256 collateralId = _getArgUint256(21);
    // pay liquidator fees here

    AuctionStack[] storage stack = s.auctionStack.stack;

    uint256 liquidatorPayment = ASTARIA_ROUTER.getLiquidatorFee(payment);

    ERC20(paymentToken).safeTransfer(
      s.auctionStack.liquidator,
      liquidatorPayment
    );

    ERC20(paymentToken).safeApprove(
      address(ASTARIA_ROUTER.TRANSFER_PROXY()),
      payment - liquidatorPayment
    );

    ASTARIA_ROUTER.LIEN_TOKEN().payDebtViaClearingHouse(
      paymentToken,
      collateralId,
      payment - liquidatorPayment,
      s.auctionStack.stack
    );

    if (ERC20(paymentToken).balanceOf(address(this)) > 0) {
      ERC20(paymentToken).safeTransfer(
        ASTARIA_ROUTER.COLLATERAL_TOKEN().ownerOf(collateralId),
        ERC20(paymentToken).balanceOf(address(this))
      );
    }
    ASTARIA_ROUTER.COLLATERAL_TOKEN().settleAuction(collateralId);
  }

  function safeTransferFrom(
    address from, // the from is the offerer
    address to,
    uint256 identifier,
    uint256 amount,
    bytes calldata data //empty from seaport
  ) public {
    //data is empty and useless
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
    IAstariaRouter ASTARIA_ROUTER = IAstariaRouter(_getArgAddress(0));
    require(msg.sender == address(ASTARIA_ROUTER.COLLATERAL_TOKEN()));
    Order[] memory listings = new Order[](1);
    listings[0] = order;

    ERC721(order.parameters.offer[0].token).approve(
      ASTARIA_ROUTER.COLLATERAL_TOKEN().getConduit(),
      order.parameters.offer[0].identifierOrCriteria
    );
    ASTARIA_ROUTER.COLLATERAL_TOKEN().SEAPORT().validate(listings);
  }

  function transferUnderlying(
    address tokenContract,
    uint256 tokenId,
    address target
  ) external {
    IAstariaRouter ASTARIA_ROUTER = IAstariaRouter(_getArgAddress(0));
    require(msg.sender == address(ASTARIA_ROUTER.COLLATERAL_TOKEN()));
    ERC721(tokenContract).safeTransferFrom(address(this), target, tokenId);
  }

  function settleLiquidatorNFTClaim() external {
    IAstariaRouter ASTARIA_ROUTER = IAstariaRouter(_getArgAddress(0));

    require(msg.sender == address(ASTARIA_ROUTER.COLLATERAL_TOKEN()));
    ClearingHouseStorage storage s = _getStorage();
    ASTARIA_ROUTER.LIEN_TOKEN().payDebtViaClearingHouse(
      address(0),
      COLLATERAL_ID(),
      0,
      s.auctionStack.stack
    );
  }
}
