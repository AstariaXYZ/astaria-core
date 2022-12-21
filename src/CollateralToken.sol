// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity =0.8.17;

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
import {
  ClonesWithImmutableArgs
} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

import {
  ConduitControllerInterface
} from "seaport/interfaces/ConduitControllerInterface.sol";
import {
  ConsiderationInterface
} from "seaport/interfaces/ConsiderationInterface.sol";
import {
  AdvancedOrder,
  CriteriaResolver,
  OfferItem,
  ConsiderationItem,
  ItemType,
  OrderParameters,
  OrderComponents,
  OrderType,
  Order
} from "seaport/lib/ConsiderationStructs.sol";

import {Consideration} from "seaport/lib/Consideration.sol";
import {SeaportInterface} from "seaport/interfaces/SeaportInterface.sol";
import {IRoyaltyEngine} from "core/interfaces/IRoyaltyEngine.sol";
import {ClearingHouse} from "core/ClearingHouse.sol";

contract CollateralToken is
  Auth,
  ERC721,
  IERC721Receiver,
  ICollateralToken,
  ZoneInterface
{
  using SafeTransferLib for ERC20;
  using CollateralLookup for address;
  using FixedPointMathLib for uint256;
  uint256 private constant COLLATERAL_TOKEN_SLOT =
    uint256(keccak256("xyz.astaria.CollateralToken.storage.location")) - 1;

  constructor(
    Authority AUTHORITY_,
    ITransferProxy TRANSFER_PROXY_,
    ILienToken LIEN_TOKEN_,
    ConsiderationInterface SEAPORT_,
    IRoyaltyEngine ROYALTY_REGISTRY_
  )
    Auth(msg.sender, Authority(AUTHORITY_))
    ERC721("Astaria Collateral Token", "ACT")
  {
    CollateralStorage storage s = _loadCollateralSlot();
    s.TRANSFER_PROXY = TRANSFER_PROXY_;
    s.LIEN_TOKEN = LIEN_TOKEN_;
    s.SEAPORT = SEAPORT_;
    s.OS_FEE_PAYEE = address(0x8De9C5A032463C561423387a9648c5C7BCC5BC90);
    s.osFeeNumerator = uint16(250);
    s.osFeeDenominator = uint16(10000);
    s.ROYALTY_ENGINE = ROYALTY_REGISTRY_;
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

  function SEAPORT() public view returns (ConsiderationInterface) {
    return _loadCollateralSlot().SEAPORT;
  }

  function liquidatorNFTClaim(OrderParameters memory params) external {
    CollateralStorage storage s = _loadCollateralSlot();

    uint256 collateralId = params.offer[0].token.computeId(
      params.offer[0].identifierOrCriteria
    );
    address liquidator = s.LIEN_TOKEN.getAuctionLiquidator(collateralId);
    if (
      s.collateralIdToAuction[collateralId] == bytes32(0) ||
      liquidator == address(0)
    ) {
      //revert no auction
      revert InvalidCollateralState(InvalidCollateralStates.NO_AUCTION);
    }
    if (
      s.collateralIdToAuction[collateralId] != keccak256(abi.encode(params))
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

    Asset storage underlying = s.idToUnderlying[collateralId];
    address tokenContract = underlying.tokenContract;
    uint256 tokenId = underlying.tokenId;
    ClearingHouse CH = ClearingHouse(payable(s.clearingHouse[collateralId]));
    CH.settleLiquidatorNFTClaim();
    _releaseToAddress(tokenContract, tokenId, liquidator);
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

  function isValidOrder(
    bytes32 orderHash,
    address caller,
    address offerer,
    bytes32 zoneHash
  ) external view returns (bytes4 validOrderMagicValue) {
    CollateralStorage storage s = _loadCollateralSlot();
    return
      s.collateralIdToAuction[uint256(zoneHash)] == orderHash
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
      s.collateralIdToAuction[uint256(order.parameters.zoneHash)] == orderHash
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

  function fileBatch(File[] calldata files) external requiresAuth {
    uint256 i;
    for (; i < files.length; ) {
      _file(files[i]);
      unchecked {
        ++i;
      }
    }
  }

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
    } else if (what == FileType.SecurityHook) {
      (address target, address hook) = abi.decode(data, (address, address));
      s.securityHooks[target] = hook;
    } else if (what == FileType.FlashEnabled) {
      (address target, bool enabled) = abi.decode(data, (address, bool));
      s.flashEnabled[target] = enabled;
    } else if (what == FileType.OpenSeaFees) {
      (address target, uint16 numerator, uint16 denominator) = abi.decode(
        data,
        (address, uint16, uint16)
      );
      s.osFeeNumerator = numerator;
      s.osFeeDenominator = denominator;
      s.OS_FEE_PAYEE = target;
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

  modifier releaseCheck(uint256 collateralId) {
    CollateralStorage storage s = _loadCollateralSlot();

    if (s.LIEN_TOKEN.getCollateralState(collateralId) != bytes32(0)) {
      revert InvalidCollateralState(InvalidCollateralStates.ACTIVE_LIENS);
    }
    if (s.collateralIdToAuction[collateralId] != bytes32(0)) {
      revert InvalidCollateralState(InvalidCollateralStates.AUCTION_ACTIVE);
    }
    _;
  }

  modifier onlyOwner(uint256 collateralId) {
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

    if (!s.flashEnabled[addr]) {
      revert InvalidCollateralState(InvalidCollateralStates.FLASH_DISABLED);
    }

    if (
      s.LIEN_TOKEN.getCollateralState(collateralId) == bytes32("ACTIVE_AUCTION")
    ) {
      revert InvalidCollateralState(InvalidCollateralStates.AUCTION_ACTIVE);
    }

    IERC721 nft = IERC721(addr);

    bytes32 preTransferState;
    //look to see if we have a security handler for this asset

    address securityHook = s.securityHooks[addr];
    if (securityHook != address(0)) {
      preTransferState = ISecurityHook(securityHook).getState(
        addr,
        tokenId
      );
    }
    // transfer the NFT to the destination optimistically

    nft.safeTransferFrom(address(this), address(receiver), tokenId);

    //trigger the flash action on the receiver
    if (
      receiver.onFlashAction(IFlashAction.Underlying(addr, tokenId), data) !=
      keccak256("FlashAction.onFlashAction")
    ) {
      revert FlashActionCallbackFailed();
    }

    if (
      securityHook != address(0) &&
      preTransferState !=
      ISecurityHook(securityHook).getState(addr, tokenId)
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
    onlyOwner(collateralId)
  {
    CollateralStorage storage s = _loadCollateralSlot();

    if (msg.sender != ownerOf(collateralId)) {
      revert InvalidSender();
    }
    Asset storage underlying = s.idToUnderlying[collateralId];
    address tokenContract = underlying.tokenContract;
    uint256 tokenId = underlying.tokenId;
    _burn(collateralId);
    delete s.idToUnderlying[collateralId];
    _releaseToAddress(tokenContract, tokenId, releaseTo);
  }

  /**
   * @dev Transfers locked collateral to a specified address and deletes the reference to the CollateralToken for that NFT.
   * @param releaseTo The address to send the NFT to.
   */
  function _releaseToAddress(
    address underlyingAsset,
    uint256 assetId,
    address releaseTo
  ) internal {
    IERC721(underlyingAsset).safeTransferFrom(
      address(this),
      releaseTo,
      assetId
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

  function getClearingHouse(uint256 collateralId)
    external
    view
    returns (address)
  {
    return (_loadCollateralSlot().clearingHouse[collateralId]);
  }

  function _generateValidOrderParameters(
    CollateralStorage storage s,
    uint256 collateralId,
    uint256 startingPrice,
    uint256 endingPrice,
    uint256 maxDuration
  ) internal returns (OrderParameters memory orderParameters) {
    OfferItem[] memory offer = new OfferItem[](1);

    Asset memory underlying = s.idToUnderlying[collateralId];

    offer[0] = OfferItem(
      ItemType.ERC721,
      underlying.tokenContract,
      underlying.tokenId,
      1,
      1
    );

    address payable[] memory recipients;
    uint256[] memory royaltyStartingAmounts;
    uint256[] memory royaltyEndingAmounts;

    try
      s.ROYALTY_ENGINE.getRoyaltyView(
        underlying.tokenContract,
        underlying.tokenId,
        startingPrice
      )
    returns (
      address payable[] memory foundRecipients,
      uint256[] memory foundAmounts
    ) {
      if (foundRecipients.length > 0) {
        recipients = foundRecipients;
        royaltyStartingAmounts = foundAmounts;
        (, royaltyEndingAmounts) = s.ROYALTY_ENGINE.getRoyaltyView(
          underlying.tokenContract,
          underlying.tokenId,
          endingPrice
        );
      }
    } catch {
      //do nothing
    }
    ConsiderationItem[] memory considerationItems = new ConsiderationItem[](
      recipients.length > 0 ? 3 : 2
    );
    considerationItems[0] = ConsiderationItem(
      ItemType.NATIVE,
      address(0),
      uint256(0),
      startingPrice,
      endingPrice,
      payable(address(s.clearingHouse[collateralId]))
    );
    considerationItems[1] = ConsiderationItem(
      ItemType.NATIVE,
      address(0),
      uint256(0),
      startingPrice.mulDivDown(uint256(s.osFeeNumerator), s.osFeeDenominator),
      endingPrice.mulDivDown(uint256(s.osFeeNumerator), s.osFeeDenominator),
      payable(s.OS_FEE_PAYEE)
    );

    if (recipients.length > 0) {
      considerationItems[2] = ConsiderationItem(
        ItemType.NATIVE,
        address(0),
        uint256(0),
        royaltyStartingAmounts[0],
        royaltyEndingAmounts[0],
        payable(recipients[0]) // royalties
      );
    }
    //put in royalty considerationItems

    orderParameters = OrderParameters({
      offerer: address(this),
      zone: address(this), // 0x20
      offer: offer,
      consideration: considerationItems,
      orderType: OrderType.FULL_OPEN,
      startTime: uint256(block.timestamp),
      endTime: uint256(block.timestamp + maxDuration),
      zoneHash: bytes32(collateralId),
      salt: uint256(blockhash(block.number)),
      conduitKey: s.CONDUIT_KEY, // 0x120
      totalOriginalConsiderationItems: considerationItems.length
    });
  }

  function auctionVault(AuctionVaultParams calldata params)
    external
    requiresAuth
    returns (OrderParameters memory orderParameters)
  {
    CollateralStorage storage s = _loadCollateralSlot();

    orderParameters = _generateValidOrderParameters(
      s,
      params.collateralId,
      params.startingPrice,
      params.endingPrice,
      params.maxDuration
    );

    _listUnderlyingOnSeaport(
      s,
      params.collateralId,
      Order(orderParameters, new bytes(0))
    );
  }

  function getOpenSeaData()
    external
    view
    returns (
      address,
      uint16,
      uint16
    )
  {
    CollateralStorage storage s = _loadCollateralSlot();
    return (s.OS_FEE_PAYEE, s.osFeeNumerator, s.osFeeDenominator);
  }

  function _listUnderlyingOnSeaport(
    CollateralStorage storage s,
    uint256 collateralId,
    Order memory listingOrder
  ) internal {
    //get total Debt and ensure its being sold for more than that

    if (listingOrder.parameters.conduitKey != s.CONDUIT_KEY) {
      revert InvalidConduitKey();
    }
    if (listingOrder.parameters.zone != address(this)) {
      revert InvalidZone();
    }

    IERC721(listingOrder.parameters.offer[0].token).approve(
      s.CONDUIT,
      listingOrder.parameters.offer[0].identifierOrCriteria
    );
    Order[] memory listings = new Order[](1);
    listings[0] = listingOrder;
    s.SEAPORT.validate(listings);
    emit ListedOnSeaport(collateralId, listingOrder);

    s.collateralIdToAuction[collateralId] = keccak256(
      abi.encode(listingOrder.parameters)
    );
  }

  function settleAuction(uint256 collateralId) public requiresAuth {
    CollateralStorage storage s = _loadCollateralSlot();
    if (s.collateralIdToAuction[collateralId] == bytes32(0)) {
      revert InvalidCollateralState(InvalidCollateralStates.NO_AUCTION);
    }
    _settleAuction(s, collateralId);
    delete s.idToUnderlying[collateralId];
    _burn(collateralId);
  }

  function _settleAuction(CollateralStorage storage s, uint256 collateralId)
    internal
  {
    delete s.collateralIdToAuction[collateralId];
  }

  /**
   * @dev Mints a new CollateralToken wrapping an NFT.
   * @param from_ the owner of the collateral deposited
   * @param tokenId_ The NFT token ID
   * @return a static return of the receive signature
   */
  function onERC721Received(
    address, /* operator_ */
    address from_,
    uint256 tokenId_,
    bytes calldata // calldata data_
  ) external override whenNotPaused returns (bytes4) {
    CollateralStorage storage s = _loadCollateralSlot();
    uint256 collateralId = msg.sender.computeId(tokenId_);

    if (s.clearingHouse[collateralId] == address(0)) {
      address clearingHouse = ClonesWithImmutableArgs.clone(
        s.ASTARIA_ROUTER.BEACON_PROXY_IMPLEMENTATION(),
        abi.encodePacked(
          address(s.ASTARIA_ROUTER),
          uint8(IAstariaRouter.ImplementationType.ClearingHouse),
          collateralId
        )
      );

      s.clearingHouse[collateralId] = clearingHouse;
    }
    Asset memory incomingAsset = s.idToUnderlying[collateralId];
    if (incomingAsset.tokenContract == address(0)) {
      require(ERC721(msg.sender).ownerOf(tokenId_) == address(this));

      if (msg.sender == address(this) || msg.sender == address(s.LIEN_TOKEN)) {
        revert InvalidCollateral();
      }

      _mint(from_, collateralId);

      s.idToUnderlying[collateralId] = Asset({
        tokenContract: msg.sender,
        tokenId: tokenId_
      });

      emit Deposit721(msg.sender, tokenId_, collateralId, from_);
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
