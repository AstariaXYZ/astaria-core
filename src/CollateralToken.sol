// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

pragma experimental ABIEncoderV2;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {IERC721, IERC165} from "gpl/interfaces/IERC721.sol";
import {IERC721Receiver} from "openzeppelin/token/ERC721/IERC721Receiver.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";
import {ICollateralBase, ICollateralToken} from "./interfaces/ICollateralToken.sol";
import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {VaultImplementation} from "./VaultImplementation.sol";
import {IERC1155Receiver} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "gpl/ERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";
import {CollateralLookup} from "./libraries/CollateralLookup.sol";

interface IFlashAction {
    function onFlashAction(bytes calldata data) external returns (bytes32);
}

interface ISecurityHook {
    function getState(address, uint256) external view returns (bytes memory);
}

contract CollateralToken is Auth, ERC721, IERC721Receiver, ICollateralBase {
    using SafeTransferLib for ERC20;
    using CollateralLookup for address;

    struct Asset {
        address tokenContract;
        uint256 tokenId;
    }

    mapping(uint256 => Asset) idToUnderlying;
    mapping(address => address) public securityHooks;

    ITransferProxy public TRANSFER_PROXY;
    ILienToken public LIEN_TOKEN;
    IAuctionHouse public AUCTION_HOUSE;
    IAstariaRouter public ASTARIA_ROUTER;
    uint256 public AUCTION_WINDOW;

    event Deposit721(address indexed from, address indexed tokenContract, uint256 tokenId);
    event ReleaseTo(address indexed underlyingAsset, uint256 assetId, address indexed to);

    error AssetNotSupported(address);
    error AuctionStartedForCollateral(uint256);

    constructor(Authority AUTHORITY_, address TRANSFER_PROXY_, address LIEN_TOKEN_)
        Auth(msg.sender, Authority(AUTHORITY_))
        ERC721("Astaria Collateral Token", "ACT")
    {
        TRANSFER_PROXY = ITransferProxy(TRANSFER_PROXY_);
        LIEN_TOKEN = ILienToken(LIEN_TOKEN_);

        AUCTION_WINDOW = uint256(2 days);
    }

    function supportsInterface(bytes4 interfaceId) public view override (ERC721) returns (bool) {
        return interfaceId == type(ICollateralToken).interfaceId || super.supportsInterface(interfaceId);
    }

    function file(bytes32 what, bytes calldata data) external requiresAuth {
        if (what == "AUCTION_WINDOW") {
            uint256 window = abi.decode(data, (uint256));
            AUCTION_WINDOW = window;
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
    }

    modifier releaseCheck(uint256 collateralId) {
        require(
            uint256(0) == LIEN_TOKEN.getLiens(collateralId).length && !AUCTION_HOUSE.auctionExists(collateralId),
            "must be no liens or auctions to call this"
        );
        _;
    }

    modifier onlyOwner(uint256 collateralId) {
        require(ownerOf(collateralId) == msg.sender, "onlyOwner: only the owner");
        _;
    }

    function flashAction(IFlashAction receiver, uint256 collateralId, bytes calldata data)
        external
        onlyOwner(collateralId)
    {
        address addr;
        uint256 tokenId;
        (addr, tokenId) = getUnderlying(collateralId);
        IERC721 nft = IERC721(addr);
        // transfer the NFT to the desitnation optimistically

        //look to see if we have a security handler for this asset

        bytes memory preTransferState;

        if (securityHooks[addr] != address(0)) {
            preTransferState = ISecurityHook(securityHooks[addr]).getState(addr, tokenId);
        }

        nft.transferFrom(address(this), address(receiver), tokenId);
        // invoke the call passed by the msg.sender
        require(receiver.onFlashAction(data) == keccak256("FlashAction.onFlashAction"), "flashAction: callback failed");

        if (securityHooks[addr] != address(0)) {
            bytes memory postTransferState = ISecurityHook(securityHooks[addr]).getState(addr, tokenId);
            require(keccak256(preTransferState) == keccak256(postTransferState), "flashAction: Data must be the same");
        }

        // validate that the NFT returned after the call
        require(nft.ownerOf(tokenId) == address(this), "flashAction: NFT not returned");
    }

    function releaseToAddress(uint256 collateralId, address releaseTo) public releaseCheck(collateralId) {
        //check liens
        require(msg.sender == ownerOf(collateralId), "You don't have permission to call this");
        _releaseToAddress(collateralId, releaseTo);
    }

    function _releaseToAddress(uint256 collateralId, address releaseTo) internal {
        (address underlyingAsset, uint256 assetId) = getUnderlying(collateralId);
        IERC721(underlyingAsset).transferFrom(address(this), releaseTo, assetId);
        delete idToUnderlying[collateralId];
        emit ReleaseTo(underlyingAsset, assetId, releaseTo);
    }

    function getUnderlying(uint256 collateralId) public view returns (address, uint256) {
        Asset memory underlying = idToUnderlying[collateralId];
        return (underlying.tokenContract, underlying.tokenId);
    }

    function tokenURI(uint256 collateralId) public view virtual override returns (string memory) {
        (address underlyingAsset, uint256 assetId) = getUnderlying(collateralId);
        return ERC721(underlyingAsset).tokenURI(assetId);
    }

    function onERC721Received(address operator_, address from_, uint256 tokenId_, bytes calldata data_)
        external
        override
        returns (bytes4)
    {
        uint256 collateralId = msg.sender.computeId(tokenId_);

        address depositFor = operator_;

        if (operator_ != from_) {
            depositFor = from_;
        }

        _mint(depositFor, collateralId);

        idToUnderlying[collateralId] = Asset({tokenContract: msg.sender, tokenId: tokenId_});

        emit Deposit721(depositFor, msg.sender, tokenId_);

        return IERC721Receiver.onERC721Received.selector;
    }

    modifier whenNotPaused() {
        if (ASTARIA_ROUTER.paused()) {
            revert("protocol is paused");
        }
        _;
    }

    function depositERC721(address depositFor_, address tokenContract_, uint256 tokenId_) external whenNotPaused {
        uint256 collateralId = uint256(keccak256(abi.encodePacked(tokenContract_, tokenId_)));

        ERC721(tokenContract_).safeTransferFrom(depositFor_, address(this), tokenId_, "");

        _mint(depositFor_, collateralId);
        idToUnderlying[collateralId] = Asset({tokenContract: tokenContract_, tokenId: tokenId_});

        emit Deposit721(depositFor_, tokenContract_, tokenId_);
    }

    function auctionVault(uint256 collateralId, address liquidator, uint256 liquidationFee, uint256 epochCap)
        external
        whenNotPaused
        requiresAuth
        returns (uint256 reserve)
    {
        require(!AUCTION_HOUSE.auctionExists(collateralId), "auctionVault: auction already exists");
        reserve = AUCTION_HOUSE.createAuction(collateralId, AUCTION_WINDOW, liquidator, liquidationFee, epochCap);
    }

    function cancelAuction(uint256 tokenId) external onlyOwner(tokenId) {
        require(AUCTION_HOUSE.auctionExists(tokenId), "Auction doesn't exist");

        AUCTION_HOUSE.cancelAuction(tokenId, msg.sender);
    }

    function endAuction(uint256 tokenId) external {
        require(AUCTION_HOUSE.auctionExists(tokenId), "Auction doesn't exist");

        address winner = AUCTION_HOUSE.endAuction(tokenId);
        _releaseToAddress(tokenId, winner);
    }
}
