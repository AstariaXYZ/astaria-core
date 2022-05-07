// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import {ECDSA} from "openzeppelin/utils/cryptography/ECDSA.sol";
import "openzeppelin/token/ERC721/ERC721.sol";
import "openzeppelin/token/ERC721/IERC721Receiver.sol";
import "openzeppelin/utils/cryptography/MerkleProof.sol";
import "openzeppelin/interfaces/IERC1271.sol";
import {NFTBondController} from "./NFTBondController.sol";

/*
 TODO: registry proxies for selling across the different networks(opensea)
    - setup the wrapper contract to verify erc1271 signatures so that it can work with looks rare

 */
contract StarNFT is ERC721, IERC721Receiver, IERC1271 {

    enum BondControllerAction {
        ENCUMBER,
        UN_ENCUMBER
    }

    bytes32 supportedAssetsRoot;

    mapping(address => address) utilityHooks;

    mapping(uint256 => address) starIdDepositor;

    mapping(uint256 => bytes32[]) liens; // tokenId to bondvaults hash

    mapping(bytes32 => uint256) lienPositions;

    mapping(uint256 => bytes) starToUnderlying;

    mapping(bytes32 => uint256) listHashes;

    NFTBondController public bondController;
    address LOOKS_TRANSFER_MGR = address(0x123456);
    uint tokenCount;
    address liquidationOperator;
    event DepositERC721(address indexed from, address indexed tokenContract, uint256 tokenId);
    event ReleaseTo(address indexed underlyingAsset, uint256 assetId, address indexed to);

    error AssetNotSupported();

    constructor(
        bytes32 supportedAssetsRoot_,
        address liquidationOperator_
    ) ERC721("Astaria NFT Wrapper", "Star NFT") {
        supportedAssetsRoot = supportedAssetsRoot_;
        liquidationOperator = liquidationOperator_;
    }

    modifier onlyDepositor(uint256 assetId) {
        //decode the asset based on its type
        require(msg.sender == starIdDepositor[assetId], "only depositor can call this");
        _;
    }

    modifier noActiveLeins(uint assetId) {
        require(uint(0) == liens[assetId].length, "must be no liens to call this");
        _;
    }

    modifier onlySupportedAssets(
        address tokenContract_,
        bytes32[] calldata proof_
    ) {
        bytes32 leaf = keccak256(abi.encodePacked(tokenContract_));
        bool isValidLeaf = MerkleProof.verify(proof_, supportedAssetsRoot, leaf);
        if (!isValidLeaf) revert AssetNotSupported();
        _;
    }

    //this is prob so dirty
    function listUnderlyingForBuyNow(
        bytes32 listHash_,
        uint assetId_
    ) onlyDepositor(assetId_) public {
        (address underlyingAsset, uint256 underlyingId) = getUnderlyingFromStar(assetId_);
        listHashes[listHash_] = assetId_;
        listHashes[bytes32(assetId_)] = uint256(listHash_);//so we can reverse quickly
        ERC721(underlyingAsset).approve(LOOKS_TRANSFER_MGR, underlyingId);
    }

    //this is prob so dirty
    function deListUnderlyingForBuyNow(
        uint256 assetId_
    ) onlyDepositor(assetId_) public {
        bytes32 digest = bytes32(listHashes[bytes32(assetId_)]);
        listHashes[digest] = uint(0);
        listHashes[bytes32(assetId_)] = uint(0);
    }


    //LIQUIDATION Operator is a server that runs an EOA to sign messages for auction
    function isValidSignature(
        bytes32 hash_,
        bytes calldata signature_
    ) external override view returns (bytes4) {
        // Validate signatures
        address recovered = ECDSA.recover(hash_, signature_);
        //needs a check to ensure the asset isn't in liquidation(if the order coming through is a buy now order)
        if ( recovered == starIdDepositor[listHashes[hash_]]  || recovered == liquidationOperator) { //TODO: consider a better approach
            return 0x1626ba7e;
        } else {
            return 0xffffffff;
        }
    }


    function manageEncumberance(uint tokenId_, bytes32 leinHash, BondControllerAction action) external {
        require(msg.sender == address(bondController), "Can only be sent from BondController");
        bytes32 positionHash = keccak256(abi.encodePacked(tokenId_, leinHash));
        if (action == BondControllerAction.ENCUMBER) {
            liens[tokenId_].push(leinHash);
            lienPositions[positionHash] = liens[tokenId_].length - 1;
        } else if (action == BondControllerAction.UN_ENCUMBER) {
            delete liens[tokenId_][lienPositions[positionHash]];
        } else {
            revert("Invalid Action");
        }

    }

    function releaseToAddress(
        uint starTokenId,
        address releaseTo
    )
    noActiveLeins(starTokenId)
    onlyDepositor(starTokenId)
    public
    {
        //check leins
        (address underlyingAsset, uint256 assetId) = getUnderlyingFromStar(starTokenId);
        ERC721(underlyingAsset).safeTransferFrom(address(this), releaseTo, assetId);
        emit ReleaseTo(underlyingAsset, assetId, releaseTo);
    }

    function getUnderlyingFromStar(
        uint256 starId_
    ) public view returns (address, uint) {
        bytes memory assetData = starToUnderlying[starId_];
        return abi.decode(assetData, (address, uint));
    }

    function tokenURI(
        uint256 starTokenId
    )
    view
    virtual
    override
    public
    returns (string memory) {
        (address underlyingAsset, uint256 assetId) = getUnderlyingFromStar(starTokenId);
        return ERC721(underlyingAsset).tokenURI(assetId);
    }

    function onERC721Received(
        address operator_,
        address from_,
        uint256 tokenId_,
        bytes calldata data_
    ) override pure external returns (bytes4) {
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
    ) onlySupportedAssets(tokenContract_, proof_) external {
        ERC721(tokenContract_).transferFrom(depositFor_, address(this), tokenId_);
        bytes memory starMap = abi.encodePacked(tokenContract_, tokenId_);
        uint starId = uint256(keccak256(starMap));
        _mint(depositFor_, starId);
        starToUnderlying[starId] = starMap;
        starIdDepositor[starId] = depositFor_;
        emit DepositERC721(depositFor_, tokenContract_, tokenId_);
    }

    function auctionUnderlyingAsset() public {
        //stub
    }

    //utility hooks are custom contracts that let you interact with different parts of the underlying ecosystem
    //claim airdrops etc/
    //potentially chainable?
    function utilityHook(
        uint256 starTokenId,
        bytes calldata hookData_
    )
    onlyDepositor(starTokenId)
    external {

        //scrub data here or in the hook? if here the hook cannot ever be done in a malicious way since we can prevent actions that would destroy custody
        (address underlyingAsset, uint256 assetId) = getUnderlyingFromStar(starTokenId);

        bytes memory hookData = abi.encodePacked(underlyingAsset, assetId, hookData_);//hook takes asset, id, and uder defined call data

        address(utilityHooks[underlyingAsset]).delegatecall(hookData);
        //check to ensure that the assets have come back to this contracts context after the delegate call
        require(ERC721(underlyingAsset).ownerOf(assetId) == address(this), "Wrapper must retain control of the asset after the utility operation");
    }

}