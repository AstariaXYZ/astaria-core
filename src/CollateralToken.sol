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

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {IERC165} from "core/interfaces/IERC165.sol";
import {IERC721} from "core/interfaces/IERC721.sol";
import {IERC721Receiver} from "core/interfaces/IERC721Receiver.sol";
import {IFlashAction} from "core/interfaces/IFlashAction.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {ISecurityHook} from "core/interfaces/ISecurityHook.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {CollateralLookup} from "core/libraries/CollateralLookup.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "gpl/ERC721.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {VaultImplementation} from "core/VaultImplementation.sol";
import {ZoneInterface} from "seaport/interfaces/ZoneInterface.sol";
import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";
import {IERC1155} from "core/interfaces/IERC1155.sol";
import {
  ConduitControllerInterface
} from "seaport/interfaces/ConduitControllerInterface.sol";
import {SeaportInterface, Order} from "seaport/interfaces/SeaportInterface.sol";
import {
  AdvancedOrder,
  CriteriaResolver,
  OfferItem,
  ConsiderationItem,
  ItemType,
  OrderParameters,
  OrderComponents,
  OrderType
} from "seaport/lib/ConsiderationStructs.sol";

import {Consideration} from "seaport/lib/Consideration.sol";
import {SeaportInterface} from "seaport/interfaces/SeaportInterface.sol";
import {EIP1271Interface} from "core/interfaces/EIP1271Interface.sol";

contract CollateralToken is
  Auth,
  ERC721,
  IERC721Receiver,
  EIP1271Interface,
  ICollateralToken,
  ZoneInterface
{
  using SafeTransferLib for ERC20;
  using CollateralLookup for address;

  bytes32 constant COLLATERAL_TOKEN_SLOT =
    keccak256("xyz.astaria.collateral.token.storage.location");

  constructor(
    Authority AUTHORITY_,
    ITransferProxy TRANSFER_PROXY_,
    ILienToken LIEN_TOKEN_,
    SeaportInterface SEAPORT_,
    IERC1155 AUCTION_VALIDATOR_
  )
    Auth(msg.sender, Authority(AUTHORITY_))
    ERC721("Astaria Collateral Token", "ACT")
  {
    CollateralStorage storage s = _loadCollateralSlot();
    s.TRANSFER_PROXY = TRANSFER_PROXY_;
    s.LIEN_TOKEN = LIEN_TOKEN_;
    s.AUCTION_VALIDATOR = AUCTION_VALIDATOR_;
    s.validatorAssetEnabled[address(AUCTION_VALIDATOR_)] = true;
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

  function isValidSignature(bytes32 hash, bytes memory)
    external
    view
    override
    returns (bytes4)
  {
    return
      _loadCollateralSlot().orderSigned[hash]
        ? EIP1271Interface.isValidSignature.selector
        : bytes4(0);
  }

  function _loadCollateralSlot()
    internal
    pure
    returns (CollateralStorage storage s)
  {
    bytes32 position = COLLATERAL_TOKEN_SLOT;
    assembly {
      s.slot := position
    }
  }

  function isValidOrder(
    bytes32 orderHash,
    address caller,
    address offerer,
    bytes32 zoneHash
  ) external view returns (bytes4 validOrderMagicValue) {
    CollateralStorage storage s = _loadCollateralSlot();
    return
      s.collateralIdToAuction[uint256(zoneHash)]
        ? ZoneInterface.isValidOrder.selector
        : bytes4(0xffffffff);
  }

  // Called by Consideration whenever any extraData is provided by the caller.
  function isValidOrderIncludingExtraData(
    bytes32 orderHash,
    address caller,
    AdvancedOrder calldata order,
    bytes32[] calldata priorOrderHashes,
    CriteriaResolver[] calldata criteriaResolvers
  ) external view returns (bytes4 validOrderMagicValue) {
    CollateralStorage storage s = _loadCollateralSlot();
    return
      s.collateralIdToAuction[uint256(order.parameters.zoneHash)]
        ? ZoneInterface.isValidOrder.selector
        : bytes4(0xffffffff);
  }

  function supportsInterface(bytes4 interfaceId)
    public
    view
    override(ERC721, IERC165)
    returns (bool)
  {
    return
      interfaceId == type(ICollateralToken).interfaceId ||
      super.supportsInterface(interfaceId);
  }

  /**
   * @notice Sets universal protocol parameters or changes the addresses for deployed contracts.
   * @param files structs to file
   */
  function fileBatch(File[] calldata files) external requiresAuth {
    for (uint256 i = 0; i < files.length; i++) {
      file(files[i]);
    }
  }

  /**
   * @notice Sets collateral token parameters or changes the addresses for deployed contracts.
   * @param incoming the incoming files
   */
  function file(File calldata incoming) public requiresAuth {
    CollateralStorage storage s = _loadCollateralSlot();

    FileType what = incoming.what;
    bytes memory data = incoming.data;
    if (what == FileType.AstariaRouter) {
      address addr = abi.decode(data, (address));
      s.ASTARIA_ROUTER = IAstariaRouter(addr);
    } else if (what == FileType.SecurityHook) {
      (address target, address hook) = abi.decode(data, (address, address));
      s.securityHooks[target] = hook;
    } else if (what == FileType.FlashEnabled) {
      (address target, bool enabled) = abi.decode(data, (address, bool));
      s.flashEnabled[target] = enabled;
    } else if (what == FileType.ValidatorAsset) {
      (address target, bool enabled) = abi.decode(data, (address, bool));
      s.validatorAssetEnabled[target] = enabled;
    } else if (what == FileType.Seaport) {
      address target = abi.decode(data, (address));
      //setup seaport conduit
      s.SEAPORT = SeaportInterface(target);
      (, , address conduitController) = s.SEAPORT.information();
      s.CONDUIT_KEY = Bytes32AddressLib.fillLast12Bytes(address(this));
      s.CONDUIT_CONTROLLER = ConduitControllerInterface(conduitController);
      s.CONDUIT = s.CONDUIT_CONTROLLER.createConduit(
        s.CONDUIT_KEY,
        address(this)
      );
    } else {
      revert UnsupportedFile();
    }
    emit FileUpdated(what, data);
  }

  modifier releaseCheck(uint256 collateralId) {
    CollateralStorage storage s = _loadCollateralSlot();

    if (s.LIEN_TOKEN.getCollateralState(collateralId) != bytes32(0)) {
      revert InvalidCollateralState(InvalidCollateralStates.ACTIVE_LIENS);
    }
    if (s.collateralIdToAuction[collateralId]) {
      revert InvalidCollateralState(InvalidCollateralStates.AUCTION);
    }
    _;
  }

  modifier onlyOwner(uint256 collateralId) {
    CollateralStorage storage s = _loadCollateralSlot();

    require(ownerOf(collateralId) == msg.sender);
    _;
  }

  function flashAction(
    IFlashAction receiver,
    uint256 collateralId,
    bytes calldata data
  ) external onlyOwner(collateralId) {
    address addr;
    uint256 tokenId;
    CollateralStorage storage s = _loadCollateralSlot();
    (addr, tokenId) = getUnderlying(collateralId);

    require(
      s.flashEnabled[addr] &&
        !(s.LIEN_TOKEN.getCollateralState(collateralId) !=
          bytes32("ACTIVE_AUCTION"))
    );
    IERC721 nft = IERC721(addr);

    bytes memory preTransferState;
    //look to see if we have a security handler for this asset

    if (s.securityHooks[addr] != address(0)) {
      preTransferState = ISecurityHook(s.securityHooks[addr]).getState(
        addr,
        tokenId
      );
    }
    // transfer the NFT to the destination optimistically

    nft.transferFrom(address(this), address(receiver), tokenId);
    // invoke the call passed by the msg.sender

    if (
      receiver.onFlashAction(IFlashAction.Underlying(addr, tokenId), data) !=
      keccak256("FlashAction.onFlashAction")
    ) {
      revert FlashActionCallbackFailed();
    }

    if (
      s.securityHooks[addr] != address(0) &&
      (keccak256(preTransferState) !=
        keccak256(ISecurityHook(s.securityHooks[addr]).getState(addr, tokenId)))
    ) {
      revert FlashActionSecurityCheckFailed();
    }

    // validate that the NFT returned after the call

    if (nft.ownerOf(tokenId) != address(this)) {
      revert FlashActionNFTNotReturned();
    }
  }

  function releaseToAddress(uint256 collateralId, address releaseTo)
    public
    releaseCheck(collateralId)
  {
    CollateralStorage storage s = _loadCollateralSlot();
    if (msg.sender != ownerOf(collateralId)) {
      revert InvalidSender();
    }
    _releaseToAddress(s, collateralId, releaseTo);
  }

  /**
   * @dev Transfers locked collateral to a specified address and deletes the reference to the CollateralToken for that NFT.
   * @param collateralId The ID for the CollateralToken of the NFT to unlock.
   * @param releaseTo The address to send the NFT to.
   */
  function _releaseToAddress(
    CollateralStorage storage s,
    uint256 collateralId,
    address releaseTo
  ) internal {
    (address underlyingAsset, uint256 assetId) = getUnderlying(collateralId);
    delete s.idToUnderlying[collateralId];
    _burn(collateralId);
    IERC721(underlyingAsset).safeTransferFrom(
      address(this),
      releaseTo,
      assetId,
      ""
    );
    emit ReleaseTo(underlyingAsset, assetId, releaseTo);
  }

  function getConduitKey() public view returns (bytes32) {
    CollateralStorage storage s = _loadCollateralSlot();
    return s.CONDUIT_KEY;
  }

  function getConduit() public view returns (address) {
    CollateralStorage storage s = _loadCollateralSlot();
    return s.CONDUIT;
  }

  /**
   * @notice Retrieve the address and tokenId of the underlying NFT of a CollateralToken.
   * @param collateralId The ID of the CollateralToken wrapping the NFT.
   * @return The address and tokenId of the underlying NFT.
   */
  function getUnderlying(uint256 collateralId)
    public
    view
    returns (address, uint256)
  {
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
  function tokenURI(uint256 collateralId)
    public
    view
    virtual
    override(ERC721, IERC721)
    returns (string memory)
  {
    (address underlyingAsset, uint256 assetId) = getUnderlying(collateralId);
    return ERC721(underlyingAsset).tokenURI(assetId);
  }

  function securityHooks(address target) public view returns (address) {
    return _loadCollateralSlot().securityHooks[target];
  }

  //collateralId,
  //      s.auctionWindow,
  //      auctionWindowMax,
  //      msg.sender,
  //      s.liquidationFeeNumerator,
  //      s.liquidationFeeDenominator,
  //      reserve,
  //      stackAtLiquidation

  //uint256 collateralId;
  //    uint56 maxDuration;
  //    address liquidator;
  //    uint256 reserve;
  //    bytes32 stackHash;
  function auctionVault(AuctionVaultParams calldata params)
    external
    requiresAuth
    returns (OrderParameters memory)
  {
    CollateralStorage storage s = _loadCollateralSlot();
    Asset memory underlying = s.idToUnderlying[params.collateralId];
    address settlementToken = params.settlementToken;
    OfferItem[] memory offer = new OfferItem[](1);

    uint256 startingPrice = 33 ether;
    uint256 endingPrice = 0;

    offer[0] = OfferItem(
      ItemType.ERC721,
      underlying.tokenContract,
      underlying.tokenId,
      1,
      1
    );
    ConsiderationItem[] memory considerationItems = new ConsiderationItem[](3);

    //TODO: compute listing fee for opensea
    //compute royalty fee for the asset if it exists
    //seaport royalty registry

    uint256 listingFee = startingPrice; // TODO make good and compute fee for seaport
    considerationItems[0] = ConsiderationItem(
      ItemType.ERC20,
      settlementToken,
      uint256(0),
      uint256(2),
      uint256(0),
      payable(address(0x8De9C5A032463C561423387a9648c5C7BCC5BC90)) //opensea fees
    );
    considerationItems[1] = ConsiderationItem(
      ItemType.ERC20,
      settlementToken,
      uint256(0),
      startingPrice,
      endingPrice,
      payable(address(s.LIEN_TOKEN))
    );
    considerationItems[2] = ConsiderationItem(
      ItemType.ERC1155,
      address(s.AUCTION_VALIDATOR),
      params.collateralId,
      startingPrice,
      endingPrice,
      payable(address(s.LIEN_TOKEN))
    );

    OrderParameters memory orderParameters = OrderParameters({
      offerer: address(this),
      zone: address(this), // 0x20
      offer: offer,
      consideration: considerationItems,
      orderType: OrderType.FULL_OPEN,
      startTime: uint256(block.timestamp),
      endTime: uint256(block.timestamp + params.maxDuration),
      zoneHash: bytes32(params.collateralId),
      salt: uint256(blockhash(block.number)),
      conduitKey: Bytes32AddressLib.fillLast12Bytes(address(this)), // 0x120
      totalOriginalConsiderationItems: uint256(3)
    });

    _listUnderlyingOnSeaport(
      s,
      params.collateralId,
      Order(orderParameters, new bytes(0))
    );
    return orderParameters;
  }

  function isValidatorAssetOperator(address validatorAsset, address operator)
    public
    view
    returns (bool)
  {
    //make sure its a conduit from seaport calling
    CollateralStorage storage s = _loadCollateralSlot();
    return (s.CONDUIT_CONTROLLER.getKey(operator) != bytes32(0) &&
      s.validatorAssetEnabled[validatorAsset]);
  }

  function _listUnderlyingOnSeaport(
    CollateralStorage storage s,
    uint256 collateralId,
    Order memory listingOrder
  ) internal {
    if (
      listingOrder.parameters.consideration[0].itemType != ItemType.ERC20 ||
      listingOrder.parameters.consideration[1].itemType != ItemType.ERC20 ||
      listingOrder.parameters.consideration[2].itemType != ItemType.ERC1155 ||
      !s.validatorAssetEnabled[listingOrder.parameters.consideration[2].token]
    ) {
      //      revert InvalidConsiderationItem();
    }

    if (
      address(s.LIEN_TOKEN) !=
      listingOrder.parameters.consideration[2].recipient
    ) {
      //      revert InvalidConsiderationRecipient();
    }
    //get total Debt and ensure its being sold for more than that

    if (listingOrder.parameters.conduitKey != s.CONDUIT_KEY) {
      //      revert InvalidConduitKey();
    }
    if (listingOrder.parameters.zone != address(this)) {
      //      revert InvalidZone();
    }

    IERC721(listingOrder.parameters.offer[0].token).approve(
      s.CONDUIT,
      listingOrder.parameters.offer[0].identifierOrCriteria
    );
    Order[] memory listings = new Order[](1);
    listings[0] = listingOrder;
    s.SEAPORT.validate(listings);

    uint256 nonce = s.SEAPORT.getCounter(address(this));
    OrderComponents memory orderComponents = OrderComponents(
      listingOrder.parameters.offerer,
      listingOrder.parameters.zone,
      listingOrder.parameters.offer,
      listingOrder.parameters.consideration,
      listingOrder.parameters.orderType,
      listingOrder.parameters.startTime,
      listingOrder.parameters.endTime,
      listingOrder.parameters.zoneHash,
      listingOrder.parameters.salt,
      listingOrder.parameters.conduitKey,
      nonce
    );

    s.orderSigned[s.SEAPORT.getOrderHash(orderComponents)] = true;
    emit ListedOnSeaport(collateralId, listingOrder);
    s.collateralIdToAuction[uint256(listingOrder.parameters.zoneHash)] = true;
  }

  event ListedOnSeaport(uint256 collateralId, Order listingOrder);
  event log_named_address(string, address);

  function settleAuction(uint256 collateralId) public requiresAuth {
    CollateralStorage storage s = _loadCollateralSlot();
    require(
      s.collateralIdToAuction[collateralId],
      "Collateral is not listed on seaport"
    );
    delete s.collateralIdToAuction[collateralId];
    delete s.idToUnderlying[collateralId];
    _burn(collateralId);
  }

  /**
   * @dev Mints a new CollateralToken wrapping an NFT.
   * @param operator_ the approved sender that called safeTransferFrom
   * @param from_ the owner of the collateral deposited
   * @param data_ calldata that is apart of the callback
   * @return a static return of the receive signature
   */
  function onERC721Received(
    address operator_,
    address from_,
    uint256 tokenId_,
    bytes calldata data_
  ) external override whenNotPaused returns (bytes4) {
    uint256 collateralId = msg.sender.computeId(tokenId_);

    CollateralStorage storage s = _loadCollateralSlot();
    Asset memory incomingAsset = s.idToUnderlying[collateralId];
    if (incomingAsset.tokenContract == address(0)) {
      require(ERC721(msg.sender).ownerOf(tokenId_) == address(this));

      if (msg.sender == address(this) || msg.sender == address(s.LIEN_TOKEN)) {
        revert InvalidCollateral();
      }

      address depositFor = operator_;

      if (operator_ != from_) {
        depositFor = from_;
      }

      _mint(depositFor, collateralId);

      s.idToUnderlying[collateralId] = Asset({
        tokenContract: msg.sender,
        tokenId: tokenId_
      });

      emit Deposit721(msg.sender, tokenId_, collateralId, depositFor);
      return IERC721Receiver.onERC721Received.selector;
    } else {
      revert();
    }
  }

  modifier whenNotPaused() {
    if (_loadCollateralSlot().ASTARIA_ROUTER.paused()) {
      revert ProtocolPaused();
    }
    _;
  }
}
