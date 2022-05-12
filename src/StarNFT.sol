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

//import {NFTBondController} from "./NFTBondController.sol";

/*
 TODO: registry proxies for selling across the different networks(opensea)
    - setup the wrapper contract to verify erc1271 signatures so that it can work with looks rare
    - lien support against the asset, so that it can be removed only when its been purchased successfully, the auction is for the star NFT
    - on successful auction, unwrap and deliver the underlying.
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

    mapping(address => address) utilityHooks;

    mapping(uint256 => address) starIdDepositor;

    mapping(uint256 => bytes) starToUnderlying;

    mapping(uint256 => bytes32[]) liens; // tokenId to bondvaults hash

    mapping(bytes32 => uint256) lienPositions;

    mapping(uint256 => uint256) lienCount;

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

    modifier onlyDepositor(uint256 assetId) {
        //decode the asset based on its type
        require(
            msg.sender == starIdDepositor[assetId],
            "only depositor can call this"
        );
        _;
    }

    modifier noActiveLiens(uint256 assetId) {
        require(
            uint256(0) == lienCount[assetId],
            "must be no liens to call this"
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
    function flashAction(uint256 starId, address destination, bytes calldata data) external onlyOwner(starId) {
        address addr;
        uint256 tokenId;
        (addr, tokenId) = getUnderlyingFromStar(starId);
        IERC721 nft = IERC721(addr);
        // transfer the NFT to the desitnation optimistically
        nft.safeTransferFrom(address(this), destination, tokenId);
        // invoke the call passed by the msg.sender
        destination.call(data);
        // validate that the NFT returned after the call
        require(nft.ownerOf(tokenId) == address(this), "flashAction: NFT not returned");
    }

    function setBondController(address _bondController) external requiresAuth {
        bondController = _bondController;
    }

    //this is prob so dirty
    function listUnderlyingForBuyNow(bytes32 listHash_, uint256 assetId_)
        public
        onlyDepositor(assetId_)
    {
        (address underlyingAsset, uint256 underlyingId) = getUnderlyingFromStar(
            assetId_
        );
        listHashes[listHash_] = assetId_;
        listHashes[bytes32(assetId_)] = uint256(listHash_);
        //so we can reverse quickly
        ERC721(underlyingAsset).approve(LOOKS_TRANSFER_MGR, underlyingId);
    }

    //this is prob so dirty
    function deListUnderlyingForBuyNow(uint256 assetId_)
        public
        onlyDepositor(assetId_)
    {
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
            recovered == starIdDepositor[listHashes[hash_]] ||
            recovered == liquidationOperator
        ) {
            return 0x1626ba7e;
        } else {
            return 0xffffffff;
        }
    }

    function manageLien(
        uint256 tokenId_,
        bytes32 lienHash,
        LienAction action
    ) public {
        require(
            msg.sender == address(bondController),
            "Can only be sent from the BondController and there "
        );

        bytes32 positionHash = keccak256(abi.encodePacked(tokenId_, lienHash));

        if (action == LienAction.ENCUMBER) {
            liens[tokenId_].push(lienHash);
            lienPositions[positionHash] = liens[tokenId_].length - 1;
            unchecked {
                lienCount[tokenId_]++;
            }
        } else if (action == LienAction.UN_ENCUMBER) {
            lienPositions[positionHash] = 0;
            unchecked {
                lienCount[tokenId_]--;
            }
            delete liens[tokenId_][lienPositions[positionHash]];
        } else {
            revert("Invalid Action");
        }
    }

    function releaseToAddress(uint256 starTokenId, address releaseTo)
        public
        noActiveLiens(starTokenId)
    {
        //check liens
        require(
            msg.sender == starIdDepositor[starTokenId] ||
                msg.sender == address(this),
            "You don't have permission to call this"
        );
        (address underlyingAsset, uint256 assetId) = getUnderlyingFromStar(
            starTokenId
        );
        ERC721(underlyingAsset).transferFrom(address(this), releaseTo, assetId);
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
        starIdDepositor[starId] = depositFor_;
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

    function handleEndAuction(uint256 _tokenId) external {
        require(
            starIdToAuctionId[_tokenId] > uint256(0),
            "Auction doesn't exist"
        );

        (uint256 amountRecovered, address winner) = AUCTION_HOUSE.endAuction(
            starIdToAuctionId[_tokenId]
        );
        //clean up all storage around the underlying asset, listings, liens, deposit information
        delete liens[_tokenId];
        delete lienCount[_tokenId];
        delete starIdDepositor[_tokenId];
        delete starToUnderlying[_tokenId];
        bytes32 listHashMap = bytes32(_tokenId);
        bytes32 listHashMapInverse = bytes32(listHashes[listHashMap]);
        delete listHashes[listHashMap];
        delete listHashes[listHashMapInverse];
        _burn(_tokenId);
        //release

        releaseToAddress(_tokenId, winner);
    }

    //utility hooks are custom contracts that let you interact with different parts of the underlying ecosystem
    //claim airdrops etc/
    //potentially chainable?
    function utilityHook(uint256 starTokenId, bytes calldata hookData_)
        external
        onlyDepositor(starTokenId) //move to anyone who holds a flash pass.
    {
        //scrub data here or in the hook? if here the hook cannot ever be done in a malicious way since we can prevent actions that would destroy custody
        (address underlyingAsset, uint256 assetId) = getUnderlyingFromStar(
            starTokenId
        );

        bytes memory hookData = abi.encodePacked(
            underlyingAsset,
            assetId,
            hookData_
        );
        //hook takes asset, id, and uder defined call data
        //TODO: push it into a proxy for flashing.
        address(utilityHooks[underlyingAsset]).delegatecall(hookData);
        //check to ensure that the assets have come back to this contracts context after the delegate call
        require(
            ERC721(underlyingAsset).ownerOf(assetId) == address(this),
            "Wrapper must retain control of the asset after the utility operation"
        );
    }
}
