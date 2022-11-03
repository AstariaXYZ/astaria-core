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
import {CollateralLookup} from "core/libraries/CollateralLookup.sol";
import {ERC721} from "gpl/ERC721.sol";

import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {IERC165} from "core/interfaces/IERC165.sol";
import {IERC721} from "core/interfaces/IERC721.sol";
import {IERC721Receiver} from "core/interfaces/IERC721Receiver.sol";
import {IFlashAction} from "core/interfaces/IFlashAction.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {ISecurityHook} from "core/interfaces/ISecurityHook.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";

import {VaultImplementation} from "core/VaultImplementation.sol";

contract CollateralToken is Auth, ERC721, IERC721Receiver, ICollateralToken {
  using SafeTransferLib for ERC20;
  using CollateralLookup for address;

  bytes32 constant COLLATERAL_TOKEN_SLOT =
    keccak256("xyz.astaria.collateral.token.storage.location");

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
    if (what == "setAstariaRouter") {
      address addr = abi.decode(data, (address));
      s.ASTARIA_ROUTER = IAstariaRouter(addr);
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

    if (s.LIEN_TOKEN.getCollateralState(collateralId) != bytes32(0)) {
      revert InvalidCollateralState(InvalidCollateralStates.ACTIVE_LIENS);
    }
    if (s.ASTARIA_ROUTER.AUCTION_HOUSE().auctionExists(collateralId)) {
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
    if (
      msg.sender != address(s.ASTARIA_ROUTER) &&
      msg.sender != ownerOf(collateralId)
    ) {
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
    IERC721(underlyingAsset).transferFrom(address(this), releaseTo, assetId);
    emit ReleaseTo(underlyingAsset, assetId, releaseTo);
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
    Asset memory underlying = s.idToUnderlying[collateralId];
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
}
