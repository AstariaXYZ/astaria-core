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
// import {ERC721} from "solmate/tokens/ERC721.sol";
import {ERC721} from "gpl/ERC721.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";

interface IFlashAction {
    function onFlashAction(bytes calldata data) external returns (bytes32);
}

interface ISecurityHook {
    function getState(address, uint256) external view returns (bytes memory);
}

contract CollateralToken is Auth, ERC721, IERC721Receiver, ICollateralBase, IERC1155Receiver {
    using SafeTransferLib for ERC20;

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

    event DepositERC721(address indexed from, address indexed tokenContract, uint256 tokenId);
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

    function supportsInterface(bytes4 interfaceId) public view override (IERC165, ERC721) returns (bool) {
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

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    )
        external
        returns (bytes4)
    {
        require(ids.length == values.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            _onERC1155Received(operator, from, ids[i], values[i], data);
        }
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function _onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data)
        internal
    {
        // require(isValidatorAsset(msg.sender), "address must be from a validator contract we care about");
        ILienToken.Lien memory lien = LIEN_TOKEN.getLien(id, uint256(0));

        require(ERC20(lien.token).balanceOf(address(this)) >= value, "not enough balance to make this payment");
        uint256 totalDebt = LIEN_TOKEN.getTotalDebtForCollateralToken(id);

        require(value >= totalDebt, "cannot be less than total obligation");
        ERC20(lien.token).safeApprove(address(TRANSFER_PROXY), totalDebt);
        LIEN_TOKEN.makePayment(id, value);

        if (value > totalDebt) {
            ERC20(lien.token).safeTransfer(ownerOf(id), value - totalDebt);
        }

        delete idToUnderlying[id];
        _burn(id);
    }

    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data)
        external
        returns (bytes4)
    {
        _onERC1155Received(operator, from, id, value, data);
        return IERC1155Receiver.onERC1155Received.selector;
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
        pure
        override
        returns (bytes4)
    {
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

        emit DepositERC721(depositFor_, tokenContract_, tokenId_);
    }

    function auctionVault(uint256 collateralId, address liquidator, uint256 liquidationFee)
        external
        whenNotPaused
        requiresAuth
        returns (uint256 reserve)
    {
        require(!AUCTION_HOUSE.auctionExists(collateralId), "auctionVault: auction already exists");
        reserve = AUCTION_HOUSE.createAuction(
            collateralId,
            AUCTION_WINDOW,
            liquidator,
            liquidationFee
        );
    }

    function cancelAuction(uint256 tokenId) external onlyOwner(tokenId) {
        require(AUCTION_HOUSE.auctionExists(tokenId), "Auction doesn't exist");

        AUCTION_HOUSE.cancelAuction(tokenId, msg.sender);
    }

    function endAuction(uint256 tokenId) external {
        require(AUCTION_HOUSE.auctionExists(tokenId), "Auction doesn't exist");

        address winner = AUCTION_HOUSE.endAuction(tokenId);
        //        _transfer(ownerOf(tokenId), winner, tokenId);
        _releaseToAddress(tokenId, winner);
    }
}
