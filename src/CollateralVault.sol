// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {ECDSA} from "openzeppelin/utils/cryptography/ECDSA.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "openzeppelin/token/ERC721/IERC721Receiver.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IERC1271} from "openzeppelin/interfaces/IERC1271.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {IBrokerRouter} from "./BrokerRouter.sol";
import {BrokerImplementation} from "./BrokerImplementation.sol";

interface IFlashAction {
    function onFlashAction(bytes calldata data) external returns (bytes32);
}

interface ISecurityHook {
    function getState(address, uint256) external view returns (bytes memory);
}

/*
 TODO: registry proxies for selling across the different networks(opensea)
    - setup the wrapper contract to verify erc1271 signatures so that it can work with looks rare
    - setup cancel auction flow(owner must repay reserve of auction)
 */
contract CollateralVault is Auth, ERC721, IERC721Receiver, ICollateralVault {
    struct Asset {
        address tokenContract;
        uint256 tokenId;
    }

    mapping(uint256 => Asset) starToUnderlying;
    mapping(address => address) public securityHooks;
    mapping(uint256 => uint256) public starIdToAuctionId;

    bytes32 SUPPORTED_ASSETS_ROOT;

    ITransferProxy TRANSFER_PROXY;
    ILienToken LIEN_TOKEN;
    IAuctionHouse AUCTION_HOUSE;
    IBrokerRouter BROKER_ROUTER;

    event DepositERC721(
        address indexed from,
        address indexed tokenContract,
        uint256 tokenId
    );
    event ReleaseTo(
        address indexed underlyingAsset,
        uint256 assetId,
        address indexed to
    );

    //    event LienUpdated(LienAction action, bytes lienData);

    error AssetNotSupported(address);
    error AuctionStartedForCollateral(uint256);

    constructor(
        Authority AUTHORITY_,
        address TRANSFER_PROXY_,
        address LIEN_TOKEN_
    )
        Auth(msg.sender, Authority(AUTHORITY_))
        ERC721("Astaria Collateral Vault", "VAULT")
    {
        TRANSFER_PROXY = ITransferProxy(TRANSFER_PROXY_);
        LIEN_TOKEN = ILienToken(LIEN_TOKEN_);
    }

    modifier releaseCheck(uint256 assetId) {
        require(
            uint256(0) == LIEN_TOKEN.getLiens(assetId).length &&
                starIdToAuctionId[assetId] == uint256(0),
            "must be no liens or auctions to call this"
        );
        _;
    }

    modifier onlySupportedAssets(
        address tokenContract_,
        bytes32[] calldata proof_
    ) {
        bytes32 leaf = keccak256(abi.encodePacked(tokenContract_));
        bool isValidLeaf = MerkleProof.verify(
            proof_,
            SUPPORTED_ASSETS_ROOT,
            leaf
        );
        if (!isValidLeaf) revert AssetNotSupported(tokenContract_);
        _;
    }

    modifier onlyOwner(uint256 starId) {
        require(ownerOf(starId) == msg.sender, "onlyOwner: only the owner");
        _;
    }

    function flashAction(
        IFlashAction receiver,
        uint256 starId,
        bytes calldata data
    ) external onlyOwner(starId) {
        address addr;
        uint256 tokenId;
        (addr, tokenId) = getUnderlyingFromStar(starId);
        IERC721 nft = IERC721(addr);
        // transfer the NFT to the desitnation optimistically

        //look to see if we have a security handler for this asset

        bytes memory preTransferState;

        if (securityHooks[addr] != address(0))
            preTransferState = ISecurityHook(securityHooks[addr]).getState(
                addr,
                tokenId
            );

        nft.transferFrom(address(this), address(receiver), tokenId);
        // invoke the call passed by the msg.sender
        require(
            receiver.onFlashAction(data) ==
                keccak256("FlashAction.onFlashAction"),
            "flashAction: callback failed"
        );

        if (securityHooks[addr] != address(0)) {
            bytes memory postTransferState = ISecurityHook(securityHooks[addr])
                .getState(addr, tokenId);
            require(
                keccak256(preTransferState) == keccak256(postTransferState),
                "flashAction: Data must be the same"
            );
        }

        // validate that the NFT returned after the call
        require(
            nft.ownerOf(tokenId) == address(this),
            "flashAction: NFT not returned"
        );
    }

    function setBondController(address _brokerRouter) external requiresAuth {
        BROKER_ROUTER = IBrokerRouter(_brokerRouter);
    }

    function setSupportedRoot(bytes32 _supportedAssetsRoot)
        external
        requiresAuth
    {
        SUPPORTED_ASSETS_ROOT = _supportedAssetsRoot;
    }

    function setAuctionHouse(address _AUCTION_HOUSE) external requiresAuth {
        AUCTION_HOUSE = IAuctionHouse(_AUCTION_HOUSE);
    }

    function setSecurityHook(address _hookTarget, address _securityHook)
        external
        requiresAuth
    {
        securityHooks[_hookTarget] = _securityHook;
    }

    function releaseToAddress(uint256 starTokenId, address releaseTo)
        public
        releaseCheck(starTokenId)
    {
        //check liens
        require(
            msg.sender == ownerOf(starTokenId) ||
                (msg.sender == address(this) &&
                    starIdToAuctionId[starTokenId] == uint256(0)),
            "You don't have permission to call this"
        );
        (address underlyingAsset, uint256 assetId) = getUnderlyingFromStar(
            starTokenId
        );
        IERC721(underlyingAsset).transferFrom(
            address(this),
            releaseTo,
            assetId
        );
        emit ReleaseTo(underlyingAsset, assetId, releaseTo);
    }

    function getUnderlyingFromStar(uint256 starId_)
        public
        view
        returns (address, uint256)
    {
        Asset memory underlying = starToUnderlying[starId_];
        return (underlying.tokenContract, underlying.tokenId);
    }

    function tokenURI(uint256 starTokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        (address underlyingAsset, uint256 assetId) = getUnderlyingFromStar(
            starTokenId
        );
        return ERC721(underlyingAsset).tokenURI(assetId);
    }

    function onERC721Received(
        address operator_,
        address from_,
        uint256 tokenId_,
        bytes calldata data_
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function depositERC721(
        address depositFor_,
        address tokenContract_,
        uint256 tokenId_,
        bytes32[] calldata proof_
    ) external onlySupportedAssets(tokenContract_, proof_) {
        ERC721(tokenContract_).transferFrom(
            depositFor_,
            address(this),
            tokenId_
        );
        uint256 starId = uint256(
            keccak256(abi.encodePacked(tokenContract_, tokenId_))
        );
        _mint(depositFor_, starId);
        starToUnderlying[starId] = Asset({
            tokenContract: tokenContract_,
            tokenId: tokenId_
        });

        emit DepositERC721(depositFor_, tokenContract_, tokenId_);
    }

    function auctionVault(
        IBrokerRouter.Terms memory terms,
        address liquidator,
        uint256 liquidationFee
    ) external requiresAuth returns (uint256 reserve) {
        require(
            !AUCTION_HOUSE.auctionExists(terms.collateralVault),
            "auctionVault: auction already exists"
        );
        reserve = AUCTION_HOUSE.createAuction(
            terms.collateralVault,
            uint256(7 days),
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
        releaseToAddress(tokenId, winner);
    }
}
