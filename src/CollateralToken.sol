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
import {IERC721} from "gpl/interfaces/IERC721.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";

import {CollateralLookup} from "./libraries/CollateralLookup.sol";

import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {
  ICollateralBase,
  ICollateralToken
} from "./interfaces/ICollateralToken.sol";
import {IERC165} from "./interfaces/IERC721.sol";
import {IERC721Receiver} from "./interfaces/IERC721Receiver.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";

import {VaultImplementation} from "./VaultImplementation.sol";

interface IFlashAction {
  struct Underlying {
    address token;
    uint256 tokenId;
  }

  function onFlashAction(Underlying calldata, bytes calldata)
    external
    returns (bytes32);
}

interface ISecurityHook {
  function getState(address, uint256) external view returns (bytes memory);
}

contract CollateralToken is Auth, ERC721, IERC721Receiver, ICollateralToken {
  using SafeTransferLib for ERC20;
  using CollateralLookup for address;

  struct Asset {
    address tokenContract;
    uint256 tokenId;
  }

  //mapping of the collateralToken ID and its underlying asset
  mapping(uint256 => Asset) idToUnderlying;
  //mapping of a security token hook for an nft's token contract address
  mapping(address => address) public securityHooks;

  ITransferProxy public TRANSFER_PROXY;
  ILienToken public LIEN_TOKEN;
  IAuctionHouse public AUCTION_HOUSE;
  IAstariaRouter public ASTARIA_ROUTER;
  uint256 public auctionWindow;

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
  event File(bytes32 indexed what, bytes data);

  constructor(
    Authority AUTHORITY_,
    ITransferProxy TRANSFER_PROXY_,
    ILienToken LIEN_TOKEN_
  )
    Auth(msg.sender, Authority(AUTHORITY_))
    ERC721("Astaria Collateral Token", "ACT")
  {
    TRANSFER_PROXY = TRANSFER_PROXY_;
    LIEN_TOKEN = LIEN_TOKEN_;

    auctionWindow = uint256(2 days);
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
   * @notice Sets addresses for the AuctionHouse, CollateralToken, and AstariaRouter contracts to use, as well as the securityHook.
   * @param what The identifier for what is being filed.
   * @param data The encoded address data to be decoded and filed.
   */
  function file(bytes32 what, bytes calldata data) external requiresAuth {
    if (what == "setAuctionWindow") {
      uint256 value = abi.decode(data, (uint256));
      auctionWindow = value;
    } else if (what == "setAstariaRouter") {
      address addr = abi.decode(data, (address));
      ASTARIA_ROUTER = IAstariaRouter(addr);
    } else if (what == "setAuctionHouse") {
      address addr = abi.decode(data, (address));
      AUCTION_HOUSE = IAuctionHouse(addr);
    } else if (what == "setSecurityHook") {
      (address target, address hook) = abi.decode(data, (address, address));
      securityHooks[target] = hook;
    } else {
      revert("unsupported/file");
    }
    emit File(what, data);
  }

  modifier releaseCheck(uint256 collateralId) {
    require(
      uint256(0) == LIEN_TOKEN.getLiens(collateralId).length &&
        !AUCTION_HOUSE.auctionExists(collateralId),
      "must be no liens or auctions to call this"
    );
    _;
  }

  modifier onlyOwner(uint256 collateralId) {
    require(ownerOf(collateralId) == msg.sender, "onlyOwner: only the owner");
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
    IERC721 nft = IERC721(addr);

    bytes memory preTransferState;
    //look to see if we have a security handler for this asset

    if (securityHooks[addr] != address(0)) {
      preTransferState = ISecurityHook(securityHooks[addr]).getState(
        addr,
        tokenId
      );
    }
    // transfer the NFT to the destination optimistically

    nft.transferFrom(address(this), address(receiver), tokenId);
    // invoke the call passed by the msg.sender
    require(
      receiver.onFlashAction(IFlashAction.Underlying(addr, tokenId), data) ==
        keccak256("FlashAction.onFlashAction"),
      "flashAction: callback failed"
    );

    if (securityHooks[addr] != address(0)) {
      require(
        keccak256(preTransferState) ==
          keccak256(ISecurityHook(securityHooks[addr]).getState(addr, tokenId)),
        "flashAction: Data must be the same"
      );
    }

    // validate that the NFT returned after the call
    require(
      nft.ownerOf(tokenId) == address(this),
      "flashAction: NFT not returned"
    );
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
    require(
      msg.sender == ownerOf(collateralId),
      "You don't have permission to call this"
    );
    _releaseToAddress(collateralId, releaseTo);
  }

  /**
   * @dev Transfers locked collateral to a specified address and deletes the reference to the CollateralToken for that NFT.
   * @param collateralId The ID for the CollateralToken of the NFT to unlock.
   * @param releaseTo The address to send the NFT to.
   */
  function _releaseToAddress(uint256 collateralId, address releaseTo) internal {
    (address underlyingAsset, uint256 assetId) = getUnderlying(collateralId);
    IERC721(underlyingAsset).transferFrom(address(this), releaseTo, assetId);
    delete idToUnderlying[collateralId];
    _burn(collateralId);
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
    Asset memory underlying = idToUnderlying[collateralId];
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
    override
    returns (string memory)
  {
    (address underlyingAsset, uint256 assetId) = getUnderlying(collateralId);
    return ERC721(underlyingAsset).tokenURI(assetId);
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

    (address underlyingAsset, ) = getUnderlying(collateralId);
    if (underlyingAsset == address(0)) {
      if (msg.sender == address(this) || msg.sender == address(LIEN_TOKEN)) {
        revert("system assets are not valid collateral");
      }

      address depositFor = operator_;

      if (operator_ != from_) {
        depositFor = from_;
      }

      _mint(depositFor, collateralId);

      idToUnderlying[collateralId] = Asset({
        tokenContract: msg.sender,
        tokenId: tokenId_
      });

      emit Deposit721(msg.sender, tokenId_, collateralId, depositFor);
    }
    return IERC721Receiver.onERC721Received.selector;
  }

  modifier whenNotPaused() {
    if (ASTARIA_ROUTER.paused()) {
      revert("protocol is paused");
    }
    _;
  }

  /**
   * @notice Begins an auction for the NFT of a liquidated CollateralToken.
   * @param collateralId The ID of the CollateralToken being liquidated.
   * @param liquidator The address of the user that triggered the liquidation.
   */
  function auctionVault(
    uint256 collateralId,
    address liquidator,
    uint256 liquidatorFee
  ) external whenNotPaused requiresAuth returns (uint256 reserve) {
    require(
      !AUCTION_HOUSE.auctionExists(collateralId),
      "auctionVault: auction already exists"
    );
    reserve = AUCTION_HOUSE.createAuction(
      collateralId,
      auctionWindow,
      liquidator,
      liquidatorFee
    );
  }

  /**
   * @notice Cancels the auction for a CollateralToken and returns the NFT to the borrower.
   * @param tokenId The ID of the CollateralToken to cancel the auction for.
   */
  function cancelAuction(uint256 tokenId) external onlyOwner(tokenId) {
    require(AUCTION_HOUSE.auctionExists(tokenId), "Auction doesn't exist");

    AUCTION_HOUSE.cancelAuction(tokenId, msg.sender);
  }

  /**
   * @notice Ends the auction for a CollateralToken.
   * @param tokenId The ID of the CollateralToken to stop the auction for.
   */
  function endAuction(uint256 tokenId) external {
    require(AUCTION_HOUSE.auctionExists(tokenId), "Auction doesn't exist");

    address winner = AUCTION_HOUSE.endAuction(tokenId);
    _releaseToAddress(tokenId, winner);
  }
}
