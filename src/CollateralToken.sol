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

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {IERC165} from "core/interfaces/IERC165.sol";
import {IERC721} from "core/interfaces/IERC721.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {Authority} from "solmate/auth/Auth.sol";
import {CollateralLookup} from "core/libraries/CollateralLookup.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "gpl/ERC721.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {VaultImplementation} from "core/VaultImplementation.sol";
import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";
import {
  Create2ClonesWithImmutableArgs
} from "create2-clones-with-immutable-args/Create2ClonesWithImmutableArgs.sol";

import {
  ConduitControllerInterface
} from "seaport-types/src/interfaces/ConduitControllerInterface.sol";
import {
  ConsiderationInterface
} from "seaport-types/src/interfaces/ConsiderationInterface.sol";
import {
  AdvancedOrder,
  CriteriaResolver,
  OfferItem,
  ConsiderationItem,
  ItemType,
  OrderParameters,
  OrderComponents,
  OrderType,
  Order,
  Schema,
  ZoneParameters,
  SpentItem,
  ReceivedItem
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {Consideration} from "seaport-core/src/lib/Consideration.sol";
import {
  SeaportInterface
} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {ZoneInterface} from "seaport-types/src/interfaces/ZoneInterface.sol";
import {AuthInitializable} from "core/AuthInitializable.sol";

contract CollateralToken is
  AuthInitializable,
  ERC721,
  ZoneInterface,
  ICollateralToken
{
  using SafeTransferLib for ERC20;
  using CollateralLookup for address;
  using FixedPointMathLib for uint256;
  uint256 private constant COLLATERAL_TOKEN_SLOT =
    uint256(keccak256("xyz.astaria.CollateralToken.storage.location")) - 1;

  constructor() {
    _disableInitializers();
  }

  function initialize(
    Authority AUTHORITY_,
    ITransferProxy TRANSFER_PROXY_,
    ILienToken LIEN_TOKEN_,
    ConsiderationInterface SEAPORT_
  ) public initializer {
    __initAuth(msg.sender, address(AUTHORITY_));
    __initERC721("Astaria Collateral Token", "ACT");
    CollateralStorage storage s = _loadCollateralSlot();
    s.TRANSFER_PROXY = TRANSFER_PROXY_;
    s.LIEN_TOKEN = LIEN_TOKEN_;
    s.SEAPORT = SEAPORT_;
    (, , address conduitController) = s.SEAPORT.information();
    bytes32 CONDUIT_KEY = Bytes32AddressLib.fillLast12Bytes(address(this));
    s.CONDUIT_KEY = CONDUIT_KEY;
    s.CONDUIT_CONTROLLER = ConduitControllerInterface(conduitController);

    s.CONDUIT = s.CONDUIT_CONTROLLER.createConduit(CONDUIT_KEY, address(this));
    s.CONDUIT_CONTROLLER.updateChannel(
      address(s.CONDUIT),
      address(SEAPORT_),
      true
    );
  }

  function getOrderComponents(
    OrderParameters memory parameters,
    uint256 counter
  ) internal pure returns (OrderComponents memory) {
    return
      OrderComponents(
        parameters.offerer,
        parameters.zone,
        parameters.offer,
        parameters.consideration,
        parameters.orderType,
        parameters.startTime,
        parameters.endTime,
        parameters.zoneHash,
        parameters.salt,
        parameters.conduitKey,
        counter
      );
  }

  function validateOrder(
    ZoneParameters calldata zoneParameters
  ) external returns (bytes4 validOrderMagicValue) {
    CollateralStorage storage s = _loadCollateralSlot();

    if (msg.sender != address(s.SEAPORT)) {
      revert InvalidSender();
    }

    if (zoneParameters.offerer == address(this)) {
      uint256 collateralId = zoneParameters.offer[0].token.computeId(
        zoneParameters.offer[0].identifier
      );

      if (
        zoneParameters.orderHashes[0] !=
        s.idToUnderlying[collateralId].auctionHash
      ) {
        revert InvalidOrder();
      }
      ILienToken.Stack memory stack = abi.decode(
        zoneParameters.extraData,
        (ILienToken.Stack)
      );
      ERC20 paymentToken = ERC20(zoneParameters.consideration[0].token);
      if (address(paymentToken) != stack.lien.token) {
        revert InvalidPaymentToken();
      }

      if (uint256(zoneParameters.zoneHash) != collateralId) {
        revert InvalidZoneHash();
      }

      uint256 payment = zoneParameters.consideration[0].amount;

      uint256 liquidatorPayment = s.ASTARIA_ROUTER.getLiquidatorFee(payment);

      payment -= liquidatorPayment;

      address liquidator = s.LIEN_TOKEN.getAuctionLiquidator(collateralId);

      paymentToken.safeTransfer(liquidator, liquidatorPayment);
      address transferProxy = address(s.ASTARIA_ROUTER.TRANSFER_PROXY());

      // If existing approval is non-zero -> set it to zero
      if (paymentToken.allowance(address(this), transferProxy) != 0) {
        paymentToken.safeApprove(transferProxy, 0);
      }
      paymentToken.approve(address(transferProxy), s.LIEN_TOKEN.getOwed(stack));

      s.LIEN_TOKEN.makePayment(stack);

      uint256 remainingBalance = paymentToken.balanceOf(address(this));
      if (remainingBalance > 0) {
        paymentToken.safeTransfer(ownerOf(collateralId), remainingBalance);
      }
      _burnAndClearState(s, collateralId);
      return ZoneInterface.validateOrder.selector;
    } else if (zoneParameters.consideration[0].itemType == ItemType.ERC721) {
      // check the owner of the nft we sold make sure its not us
      if (
        ERC721(zoneParameters.consideration[0].token).ownerOf(
          zoneParameters.consideration[0].identifier
        ) == address(this)
      ) {
        revert InvalidOrder();
      }
      return ZoneInterface.validateOrder.selector;
    }
    revert InvalidOrder();
  }

  function _burnAndClearState(
    CollateralStorage storage s,
    uint256 collateralId
  ) internal {
    _burn(collateralId);
    delete s.idToUnderlying[collateralId].auctionHash;
  }

  /**
   * @dev Returns the metadata for this zone.
   *
   * @return name The name of the zone.
   * @return schemas The schemas that the zone implements.
   */
  function getSeaportMetadata()
    external
    view
    returns (
      string memory name,
      Schema[] memory schemas // map to Seaport Improvement Proposal IDs
    )
  {
    // we dont support any atm
    return ("Astaria Collateral Token", new Schema[](0));
  }

  function SEAPORT() public view returns (ConsiderationInterface) {
    return _loadCollateralSlot().SEAPORT;
  }

  /**
   * @notice Returns the ConduitController for this contract.
   * @return The ConduitController for this contract.
   */
  function CONDUIT_CONTROLLER()
    public
    view
    returns (ConduitControllerInterface)
  {
    return _loadCollateralSlot().CONDUIT_CONTROLLER;
  }

  /**
   * @notice Permissionless hook which returns the underlying NFT for a CollateralToken to the liquidator after an auction.
   * @param params The Seaport data from the liquidation.
   */
  function liquidatorNFTClaim(
    ILienToken.Stack memory stack,
    OrderParameters memory params,
    uint256 counterAtLiquidation
  ) external whenNotPaused {
    CollateralStorage storage s = _loadCollateralSlot();

    uint256 collateralId = params.offer[0].token.computeId(
      params.offer[0].identifierOrCriteria
    );
    if (stack.lien.collateralId != collateralId) {
      //revert collateral id mismatch
      revert InvalidCollateralState(InvalidCollateralStates.ID_MISMATCH);
    }
    if (s.idToUnderlying[collateralId].auctionHash == bytes32(0)) {
      //revert no auction
      revert InvalidCollateralState(InvalidCollateralStates.NO_AUCTION);
    }
    address liquidator = s.LIEN_TOKEN.getAuctionLiquidator(collateralId);

    if (
      s.idToUnderlying[collateralId].auctionHash !=
      s.SEAPORT.getOrderHash(getOrderComponents(params, counterAtLiquidation))
    ) {
      //revert auction params dont match
      revert InvalidCollateralState(
        InvalidCollateralStates.INVALID_AUCTION_PARAMS
      );
    }

    if (block.timestamp < params.endTime) {
      //auction hasn't ended yet
      revert InvalidCollateralState(InvalidCollateralStates.AUCTION_ACTIVE);
    }

    s.LIEN_TOKEN.makePayment(stack);
    _releaseToAddress(s, collateralId, liquidator);
  }

  function _loadCollateralSlot()
    internal
    pure
    returns (CollateralStorage storage s)
  {
    uint256 slot = COLLATERAL_TOKEN_SLOT;

    assembly {
      s.slot := slot
    }
  }

  function supportsInterface(
    bytes4 interfaceId
  ) public view override(ERC721, IERC165, ZoneInterface) returns (bool) {
    return
      interfaceId == type(ICollateralToken).interfaceId ||
      interfaceId == type(ZoneInterface).interfaceId ||
      super.supportsInterface(interfaceId);
  }

  /**
   * @notice Sets universal protocol parameters or changes the addresses for deployed contracts.
   * @param files Structs to file.
   */
  function fileBatch(File[] calldata files) external requiresAuth {
    uint256 i;
    for (; i < files.length; ) {
      _file(files[i]);
      unchecked {
        ++i;
      }
    }
  }

  /**
   * @notice Sets universal protocol parameters or changes the addresses for deployed contracts.
   * @param incoming The incoming File.
   */
  function file(File calldata incoming) public requiresAuth {
    _file(incoming);
  }

  function _file(File calldata incoming) internal {
    CollateralStorage storage s = _loadCollateralSlot();

    FileType what = incoming.what;
    bytes memory data = incoming.data;
    if (what == FileType.AstariaRouter) {
      address addr = abi.decode(data, (address));
      s.ASTARIA_ROUTER = IAstariaRouter(addr);
    } else if (what == FileType.CloseChannel) {
      address outgoingChannel = abi.decode(data, (address));
      if (outgoingChannel == address(s.SEAPORT)) {
        revert InvalidTarget();
      }
      s.CONDUIT_CONTROLLER.updateChannel(
        address(s.CONDUIT),
        outgoingChannel,
        false
      );
    } else if (what == FileType.Seaport) {
      s.SEAPORT = ConsiderationInterface(abi.decode(data, (address)));
      (, , address conduitController) = s.SEAPORT.information();
      if (s.CONDUIT_KEY == bytes32(0)) {
        s.CONDUIT_KEY = Bytes32AddressLib.fillLast12Bytes(address(this));
      }
      s.CONDUIT_CONTROLLER = ConduitControllerInterface(conduitController);
      (address conduit, bool exists) = s.CONDUIT_CONTROLLER.getConduit(
        s.CONDUIT_KEY
      );
      if (!exists) {
        s.CONDUIT = s.CONDUIT_CONTROLLER.createConduit(
          s.CONDUIT_KEY,
          address(this)
        );
      } else {
        s.CONDUIT = conduit;
      }
      s.CONDUIT_CONTROLLER.updateChannel(
        address(s.CONDUIT),
        address(s.SEAPORT),
        true
      );
    } else {
      revert UnsupportedFile();
    }
    emit FileUpdated(what, data);
  }

  /**
   * @notice Unlocks the NFT for a CollateralToken and sends it to the owner on repayment
   * @param collateralId The ID for the CollateralToken of the NFT to unlock.
   */
  function release(uint256 collateralId) public whenNotPaused {
    CollateralStorage storage s = _loadCollateralSlot();

    if (msg.sender != address(s.LIEN_TOKEN)) {
      revert InvalidSender();
    }

    _releaseToAddress(s, collateralId, ownerOf(collateralId));
  }

  /**
   * @dev Transfers locked collateral to a specified address and deletes the reference to the CollateralToken for that NFT.
   * @param releaseTo The address to send the NFT to.
   */
  function _releaseToAddress(
    CollateralStorage storage s,
    uint256 collateralId,
    address releaseTo
  ) internal {
    Asset storage underlying = s.idToUnderlying[collateralId];
    _burnAndClearState(s, collateralId);
    ERC721(underlying.tokenContract).transferFrom(
      address(this),
      releaseTo,
      underlying.tokenId
    );
    emit ReleaseTo(underlying.tokenContract, underlying.tokenId, releaseTo);
  }

  /**
   * @notice gets the conduit key
   * @return the conduit key
   */
  function getConduitKey() public view returns (bytes32) {
    CollateralStorage storage s = _loadCollateralSlot();
    return s.CONDUIT_KEY;
  }

  /**
   * @notice Retrieve the address of the Conduit contract.
   * @return The address of the Conduit contract.
   */
  function getConduit() public view returns (address) {
    CollateralStorage storage s = _loadCollateralSlot();
    return s.CONDUIT;
  }

  /**
   * @notice Retrieve the address and tokenId of the underlying NFT of a CollateralToken.
   * @param collateralId The ID of the CollateralToken wrapping the NFT.
   * @return The address and tokenId of the underlying NFT.
   */
  function getUnderlying(
    uint256 collateralId
  ) public view returns (address, uint256) {
    Asset memory underlying = _loadCollateralSlot().idToUnderlying[
      collateralId
    ];
    return (underlying.tokenContract, underlying.tokenId);
  }

  /**
   * @notice Retrieve the tokenURI for a CollateralToken.
   * @param collateralId The ID of the CollateralToken.
   * @return the URI of the CollateralToken.
   */
  function tokenURI(
    uint256 collateralId
  ) public view virtual override(ERC721, IERC721) returns (string memory) {
    (address underlyingAsset, uint256 assetId) = getUnderlying(collateralId);
    return ERC721(underlyingAsset).tokenURI(assetId);
  }

  function _generateValidOrderParameters(
    CollateralStorage storage s,
    address settlementToken,
    uint256 collateralId,
    uint256[] memory prices,
    uint256 maxDuration
  ) internal view returns (OrderParameters memory orderParameters) {
    OfferItem[] memory offer = new OfferItem[](1);

    Asset memory underlying = s.idToUnderlying[collateralId];

    offer[0] = OfferItem(
      ItemType.ERC721,
      underlying.tokenContract,
      underlying.tokenId,
      1,
      1
    );

    ConsiderationItem[] memory considerationItems = new ConsiderationItem[](1);
    considerationItems[0] = ConsiderationItem(
      ItemType.ERC20,
      settlementToken,
      uint256(0),
      prices[0],
      prices[1],
      payable(address(this))
    );

    orderParameters = OrderParameters({
      offerer: address(this),
      zone: address(this),
      offer: offer,
      consideration: considerationItems,
      orderType: OrderType.FULL_RESTRICTED,
      startTime: uint256(block.timestamp),
      endTime: uint256(block.timestamp + maxDuration),
      zoneHash: bytes32(collateralId),
      salt: uint256(
        keccak256(
          abi.encodePacked(collateralId, uint256(blockhash(block.number - 1)))
        )
      ),
      conduitKey: s.CONDUIT_KEY,
      totalOriginalConsiderationItems: considerationItems.length
    });
  }

  /**
   * @notice Send a CollateralToken to a Seaport auction on liquidation.
   * @param params The auction data.
   */
  function auctionVault(
    AuctionVaultParams calldata params
  ) external whenNotPaused returns (OrderParameters memory orderParameters) {
    CollateralStorage storage s = _loadCollateralSlot();

    if (msg.sender != address(s.ASTARIA_ROUTER)) {
      revert InvalidSender();
    }
    uint256[] memory prices = new uint256[](2);
    prices[0] = params.startingPrice;
    prices[1] = params.endingPrice;
    orderParameters = _generateValidOrderParameters(
      s,
      params.settlementToken,
      params.collateralId,
      prices,
      params.maxDuration
    );

    Order[] memory listing = new Order[](1);
    listing[0] = Order(orderParameters, "");

    ERC721(orderParameters.offer[0].token).approve(
      s.CONDUIT,
      orderParameters.offer[0].identifierOrCriteria
    );
    if (!s.SEAPORT.validate(listing)) {
      revert InvalidOrder();
    }
    s.idToUnderlying[params.collateralId].auctionHash = s.SEAPORT.getOrderHash(
      getOrderComponents(orderParameters, s.SEAPORT.getCounter(address(this)))
    );
  }

  /**
   * @dev Mints a new CollateralToken wrapping an NFT.
   * @param tokenContract the address of the NFT contract
   * @param from the owner of the collateral deposited
   * @param tokenId The NFT token ID
   */
  function depositERC721(
    address tokenContract,
    uint256 tokenId,
    address from
  ) external whenNotPaused {
    CollateralStorage storage s = _loadCollateralSlot();
    if (msg.sender != address(s.ASTARIA_ROUTER)) {
      revert InvalidSender();
    }
    uint256 collateralId = tokenContract.computeId(tokenId);

    Asset storage incomingAsset = s.idToUnderlying[collateralId];

    require(ERC721(tokenContract).ownerOf(tokenId) == address(this));
    incomingAsset.tokenContract = tokenContract;
    incomingAsset.tokenId = tokenId;
    if (
      tokenContract == address(this) || tokenContract == address(s.LIEN_TOKEN)
    ) {
      revert InvalidCollateral();
    }

    _mint(from, collateralId);

    emit Deposit721(tokenContract, tokenId, collateralId, from);
  }

  modifier whenNotPaused() {
    if (_loadCollateralSlot().ASTARIA_ROUTER.paused()) {
      revert ProtocolPaused();
    }
    _;
  }
}
