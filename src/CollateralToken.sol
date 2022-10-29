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
import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {ERC721} from "gpl/ERC721.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {IERC721} from "core/interfaces/IERC721.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";

import {CollateralLookup} from "core/libraries/CollateralLookup.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "./interfaces/ICollateralToken.sol";
import {IERC165} from "core/interfaces/IERC165.sol";
import {IERC721Receiver} from "core/interfaces/IERC721Receiver.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";

import {VaultImplementation} from "core/VaultImplementation.sol";

import {IFlashAction} from "core/interfaces/IFlashAction.sol";
import {ISecurityHook} from "core/interfaces/ISecurityHook.sol";
import "./interfaces/IAstariaRouter.sol";

contract CollateralToken is Auth, ERC721, IERC721Receiver, ICollateralToken {
  using SafeTransferLib for ERC20;
  using CollateralLookup for address;

  bytes32 constant COLLATERAL_TOKEN_SLOT =
    keccak256("xyz.astaria.collateral.token.storage.location");

  struct Asset {
    address tokenContract;
    uint256 tokenId;
  }

  struct CollateralStorage {
    mapping(address => bool) flashEnabled;
    //mapping of the collateralToken ID and its underlying asset
    mapping(uint256 => Asset) idToUnderlying;
    //mapping of a security token hook for an nft's token contract address
    mapping(address => address) securityHooks;
    ITransferProxy TRANSFER_PROXY;
    ILienToken LIEN_TOKEN;
    IAuctionHouse AUCTION_HOUSE;
    IAstariaRouter ASTARIA_ROUTER;
    uint256 auctionWindow;
  }

  //  mapping(address => bool) public flashEnabled;
  //  //mapping of the collateralToken ID and its underlying asset
  //  mapping(uint256 => Asset) idToUnderlying;
  //  //mapping of a security token hook for an nft's token contract address
  //  mapping(address => address) public securityHooks;
  //
  //  ITransferProxy public TRANSFER_PROXY;
  //  ILienToken public LIEN_TOKEN;
  //  IAuctionHouse public AUCTION_HOUSE;
  //  IAstariaRouter public ASTARIA_ROUTER;
  //  uint256 public auctionWindow;

  event Deposit721(
    address indexed tokenContract,
    uint256 indexed tokenId,
    uint256 indexed collateralId,
    address depositedFor
  );
  event ReleaseTo(
    address indexed underlyingAsset,
    uint256 assetId,
    address indexed to
  );
  event FileUpdated(bytes32 indexed what, bytes data);

  constructor(
    Authority AUTHORITY_,
    ITransferProxy TRANSFER_PROXY_,
    ILienToken LIEN_TOKEN_
  )
    Auth(msg.sender, Authority(AUTHORITY_))
    ERC721("Astaria Collateral Token", "ACT")
  {
    CollateralStorage storage s = _loadCollateralSlot();
    s.TRANSFER_PROXY = TRANSFER_PROXY_;
    s.LIEN_TOKEN = LIEN_TOKEN_;

    s.auctionWindow = uint256(2 days);
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

  struct File {
    bytes32 what;
    bytes data;
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

    bytes32 what = incoming.what;
    bytes memory data = incoming.data;
    if (what == "setAuctionWindow") {
      uint256 value = abi.decode(data, (uint256));
      s.auctionWindow = value;
    } else if (what == "setAstariaRouter") {
      address addr = abi.decode(data, (address));
      s.ASTARIA_ROUTER = IAstariaRouter(addr);
    } else if (what == "setAuctionHouse") {
      address addr = abi.decode(data, (address));
      s.AUCTION_HOUSE = IAuctionHouse(addr);
    } else if (what == "setSecurityHook") {
      (address target, address hook) = abi.decode(data, (address, address));
      s.securityHooks[target] = hook;
    } else if (what == "setFlashEnabled") {
      (address target, bool enabled) = abi.decode(data, (address, bool));
      s.flashEnabled[target] = enabled;
    } else {
      revert("unsupported/file");
    }
    emit FileUpdated(what, data);
  }

  modifier releaseCheck(uint256 collateralId) {
    CollateralStorage storage s = _loadCollateralSlot();

    if (s.LIEN_TOKEN.getLienCount(collateralId) > 0) {
      revert InvalidCollateralState(InvalidCollateralStates.ACTIVE_LIENS);
    }
    if (s.AUCTION_HOUSE.auctionExists(collateralId)) {
      revert InvalidCollateralState(InvalidCollateralStates.AUCTION);
    }
    _;
  }

  modifier onlyOwner(uint256 collateralId) {
    CollateralStorage storage s = _loadCollateralSlot();

    require(ownerOf(collateralId) == msg.sender);
    _;
  }

  /**
   * @notice Executes a FlashAction using locked collateral. A valid FlashAction performs a specified action with the collateral within a single transaction and must end with the collateral being returned to the Vault it was locked in.
   * @param receiver The FlashAction to execute.
   * @param collateralId The ID of the CollateralToken to temporarily unwrap.
   * @param data Input data used in the FlashAction.
   */
  function flashAction(
    IFlashAction receiver,
    uint256 collateralId,
    bytes calldata data
  ) external onlyOwner(collateralId) {
    address addr;
    uint256 tokenId;
    (addr, tokenId) = getUnderlying(collateralId);
    CollateralStorage storage s = _loadCollateralSlot();

    require(s.flashEnabled[addr]);
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
    //    require(
    //      ,
    //      "flashAction: callback failed"
    //    );

    if (
      s.securityHooks[addr] != address(0) &&
      (keccak256(preTransferState) !=
        keccak256(ISecurityHook(s.securityHooks[addr]).getState(addr, tokenId)))
    ) {
      revert FlashActionSecurityCheckFailed();
      //      require(
      //        ,
      //        "flashAction: Data must be the same"
      //      );
    }

    // validate that the NFT returned after the call

    if (nft.ownerOf(tokenId) != address(this)) {
      revert FlashActionNFTNotReturned();
    }
    //    require(
    //      ,
    //      "flashAction: NFT not returned"
    //    );
  }

  /**
   * @notice Unlocks the NFT for a CollateralToken and sends it to a specified address.
   * @param collateralId The ID for the CollateralToken of the NFT to unlock.
   * @param releaseTo The address to send the NFT to.
   */
  function releaseToAddress(uint256 collateralId, address releaseTo)
    public
    releaseCheck(collateralId)
  {
    //check liens
    if (msg.sender != ownerOf(collateralId)) {
      revert InvalidSender();
    }
    //    require(
    //      ,
    //      "You don't have permission to call this"
    //    );
    _releaseToAddress(_loadCollateralSlot(), collateralId, releaseTo);
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
    IERC721(underlyingAsset).transferFrom(address(this), releaseTo, assetId);
    emit ReleaseTo(underlyingAsset, assetId, releaseTo);
  }

  function auctionWindow() public view returns (uint256) {
    return _loadCollateralSlot().auctionWindow;
  }

  function AUCTION_HOUSE() public view returns (IAuctionHouse) {
    return _loadCollateralSlot().AUCTION_HOUSE;
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

  function ASTARIA_ROUTER() public view returns (IAstariaRouter) {
    return _loadCollateralSlot().ASTARIA_ROUTER;
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
  ) external override returns (bytes4) {
    uint256 collateralId = msg.sender.computeId(tokenId_);

    CollateralStorage storage s = _loadCollateralSlot();

    (address underlyingAsset, ) = getUnderlying(collateralId);
    if (underlyingAsset == address(0)) {
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
    }
    return IERC721Receiver.onERC721Received.selector;
  }

  modifier whenNotPaused() {
    if (_loadCollateralSlot().ASTARIA_ROUTER.paused()) {
      revert ProtocolPaused();
    }
    _;
  }

  /**
   * @notice Begins an auction for the NFT of a liquidated CollateralToken.
   * @param collateralId The ID of the CollateralToken being liquidated.
   * @param liquidator The address of the user that triggered the liquidation.
   * @param reserve The address of the user that triggered the liquidation.
   */
  function auctionVault(
    uint256 collateralId,
    address liquidator,
    uint256 reserve,
    uint256[] calldata stack
  ) external whenNotPaused requiresAuth {
    CollateralStorage storage s = _loadCollateralSlot();

    //    if (s.AUCTION_HOUSE.auctionExists(collateralId)) {
    //      revert InvalidCollateralState(InvalidCollateralStates.AUCTION);
    //    }
    //    require(
    //      !,
    //      "auctionVault: auction already exists"
    //    );

    //TODO: fix permission
    s.AUCTION_HOUSE.createAuction(
      collateralId,
      s.auctionWindow,
      liquidator,
      reserve,
      stack
    );
  }

  /**
   * @notice Cancels the auction for a CollateralToken and returns the NFT to the borrower.
   * @param tokenId The ID of the CollateralToken to cancel the auction for.
   */
  function cancelAuction(uint256 tokenId) external onlyOwner(tokenId) {
    CollateralStorage storage s = _loadCollateralSlot();

    if (!s.AUCTION_HOUSE.auctionExists(tokenId)) {
      revert InvalidCollateralState(InvalidCollateralStates.NO_AUCTION);
    }

    s.AUCTION_HOUSE.cancelAuction(tokenId, msg.sender);
    _releaseToAddress(s, tokenId, msg.sender);
  }

  /**
   * @notice Ends the auction for a CollateralToken.
   * @param tokenId The ID of the CollateralToken to stop the auction for.
   */
  function endAuction(uint256 tokenId) external {
    CollateralStorage storage s = _loadCollateralSlot();

    if (!s.AUCTION_HOUSE.auctionExists(tokenId)) {
      revert InvalidCollateralState(InvalidCollateralStates.NO_AUCTION);
    }

    address winner = s.AUCTION_HOUSE.endAuction(tokenId);
    _releaseToAddress(s, tokenId, winner);
  }
}
