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
import {IAuctionHouse} from "./interfaces/IAuctionHouse.sol";

interface IFlashAction {
    function onFlashAction(bytes calldata data) external returns (bytes32);
}

interface ISecurityHook {
    function getState(address, uint256) external returns (bytes memory);
}

/*
 TODO: registry proxies for selling across the different networks(opensea)
    - setup the wrapper contract to verify erc1271 signatures so that it can work with looks rare
    - setup cancel auction flow(owner must repay reserve of auction)
 */
contract StarNFT is Auth, ERC721, IERC721Receiver, IERC1271 {
    enum LienAction {
        ENCUMBER,
        UN_ENCUMBER
    }

    //    struct Asset {
    //        address tokenContract;
    //        uint256 tokenId;
    //    }
    //    mapping(uint256 => Asset) starToUnderlying;
    bytes32 supportedAssetsRoot;

    mapping(address => address) securityHooks;

    mapping(uint256 => bytes) starToUnderlying;

    mapping(uint256 => uint256) liens; // tokenId to bondvaults hash only can move up and down.

    mapping(uint256 => uint256) starIdToAuctionId;

    mapping(bytes32 => uint256) listHashes;

    IAuctionHouse AUCTION_HOUSE;
    address bondController;
    address LOOKS_TRANSFER_MGR = address(0x123456);
    uint256 tokenCount;
    address liquidationOperator;

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

    event LienUpdated(bytes32 bondVault, uint256 starId, LienAction action);

    error AssetNotSupported();

    constructor(
        Authority AUTHORITY_,
        address _AUCTION_HOUSE,
        bytes32 supportedAssetsRoot_,
        address liquidationOperator_
    )
        Auth(msg.sender, Authority(AUTHORITY_))
        ERC721("Astaria NFT Wrapper", "Star NFT")
    {
        AUCTION_HOUSE = IAuctionHouse(_AUCTION_HOUSE);
        supportedAssetsRoot = supportedAssetsRoot_;
        liquidationOperator = liquidationOperator_;
    }

    modifier noActiveLiens(uint256 assetId) {
        require(uint256(0) == liens[assetId], "must be no liens to call this");
        _;
    }

    modifier onlySupportedAssets(
        address tokenContract_,
        bytes32[] calldata proof_
    ) {
        bytes32 leaf = keccak256(abi.encodePacked(tokenContract_));
        bool isValidLeaf = MerkleProof.verify(
            proof_,
            supportedAssetsRoot,
            leaf
        );
        if (!isValidLeaf) revert AssetNotSupported();
        _;
    }

    modifier onlyOwner(uint256 starId) {
        require(ownerOf(starId) == msg.sender, "onlyOwner: only the owner");
        _;
    }

    // needs reentrancyGuard
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
                "Data must be the same"
            );
        }

        // validate that the NFT returned after the call
        require(
            nft.ownerOf(tokenId) == address(this),
            "flashAction: NFT not returned"
        );
    }

    function setBondController(address _bondController) external requiresAuth {
        bondController = _bondController;
    }

    function setSecurityHook(address _hookTarget, address _securityHook)
        external
        requiresAuth
    {
        securityHooks[_hookTarget] = _securityHook;
    }

    //this is prob so dirty
    function listUnderlyingForBuyNow(bytes32 listHash_, uint256 assetId_)
        public
    {
        require(
            msg.sender == ownerOf(assetId_),
            "Only the holder of the token can do this"
        );
        (address underlyingAsset, uint256 underlyingId) = getUnderlyingFromStar(
            assetId_
        );
        listHashes[listHash_] = assetId_;
        listHashes[bytes32(assetId_)] = uint256(listHash_);
        //so we can reverse quickly
        ERC721(underlyingAsset).approve(LOOKS_TRANSFER_MGR, underlyingId);
    }

    //this is prob so dirty
    function deListUnderlyingForBuyNow(uint256 assetId_) public {
        require(
            msg.sender == ownerOf(assetId_),
            "Only the holder of the token can do this"
        );

        bytes32 digest = bytes32(listHashes[bytes32(assetId_)]);
        listHashes[digest] = uint256(0);
        listHashes[bytes32(assetId_)] = uint256(0);
    }

    //LIQUIDATION Operator is a server that runs an EOA to sign messages for auction
    function isValidSignature(bytes32 hash_, bytes calldata signature_)
        external
        view
        override
        returns (bytes4)
    {
        // Validate signatures
        address recovered = ECDSA.recover(hash_, signature_);
        //needs a check to ensure the asset isn't in liquidation(if the order coming through is a buy now order)
        if (
            recovered == ownerOf(listHashes[hash_]) ||
            recovered == liquidationOperator
        ) {
            return 0x1626ba7e;
        } else {
            return 0xffffffff;
        }
    }

    function manageLien(
        uint256 tokenId_,
        bytes32 bondVault,
        LienAction action
    ) public {
        require(
            msg.sender == address(bondController),
            "Can only be sent from the BondController and there "
        );

        if (action == LienAction.ENCUMBER) {
            unchecked {
                liens[tokenId_]++;
            }
        } else if (action == LienAction.UN_ENCUMBER) {
            unchecked {
                liens[tokenId_]--;
            }
        } else {
            revert("Invalid Action");
        }
        emit LienUpdated(bondVault, tokenId_, action);
    }

    function releaseToAddress(uint256 starTokenId, address releaseTo)
        public
        noActiveLiens(starTokenId)
    {
        //check liens
        require(
            msg.sender == ownerOf(starTokenId) || msg.sender == address(this),
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
        bytes memory assetData = starToUnderlying[starId_];
        return abi.decode(assetData, (address, uint256));
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
        //        require(ERC721(msg.sender).ownerOf(tokenId_) == address(this));
        //        uint starId = uint256(keccak256(abi.encodePacked(address(msg.sender), tokenId_)));
        //        _mint(from_, starId);
        //        starToUnderlying[starId] = abi.encodePacked(address(msg.sender), tokenId_);
        //        starIdDepositor[starId] = from_;
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
        bytes memory starMap = abi.encodePacked(tokenContract_, tokenId_);
        uint256 starId = uint256(
            keccak256(abi.encodePacked(tokenContract_, tokenId_))
        );
        _mint(depositFor_, starId);
        starToUnderlying[starId] = starMap;
        emit DepositERC721(depositFor_, tokenContract_, tokenId_);
    }

    function auctionVault(
        bytes32 _bondVault,
        uint256 _tokenId,
        uint256 _reservePrice
    ) external {
        require(
            starIdToAuctionId[_tokenId] == uint256(0),
            "auction already exists"
        );
        uint256 auctionId = AUCTION_HOUSE.createAuction(
            _tokenId,
            uint256(7 days),
            _reservePrice,
            _bondVault
        );
        starIdToAuctionId[_tokenId] = auctionId;
    }

    function endAuction(uint256 _tokenId) external {
        require(
            starIdToAuctionId[_tokenId] > uint256(0),
            "Auction doesn't exist"
        );

        (uint256 amountRecovered, address winner) = AUCTION_HOUSE.endAuction(
            starIdToAuctionId[_tokenId]
        );
        //clean up all storage around the underlying asset, listings, liens, deposit information
        delete liens[_tokenId];
        //        delete lienCount[_tokenId];
        delete starToUnderlying[_tokenId];
        bytes32 listHashMap = bytes32(_tokenId);
        bytes32 listHashMapInverse = bytes32(listHashes[listHashMap]);
        delete listHashes[listHashMap];
        delete listHashes[listHashMapInverse];
        _burn(_tokenId);
        //release

        releaseToAddress(_tokenId, winner);
    }
}
