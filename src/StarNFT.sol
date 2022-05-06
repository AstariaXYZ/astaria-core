// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "openzeppelin/access/Ownable.sol";
import "openzeppelin/token/ERC721/ERC721.sol";
import "openzeppelin/token/ERC721/IERC721Receiver.sol";
import "openzeppelin/utils/cryptography/MerkleProof.sol";
import { NFTBondController} from "./NFTBondController.sol";


contract StarNFT is ERC721, IERC721Receiver {

    bytes32 public supportedAssetsRoot;

    mapping(address => address) utilityHooks;

    mapping(uint256 => address) starIdDepositor;

    mapping(uint256 => bytes32[]) liens; // tokenId to bondvaults hash

    mapping(bytes32 => uint256) lienPositions; //hash the tokenId wih the vault hash and save position in array

    mapping(uint => bytes) public starToUnderlying;

    NFTBondController public bondController;

    uint public tokenCount;

    event DepositERC721(address indexed from, address indexed tokenContract, uint256 tokenId);
    event ReleaseTo(address indexed underlyingAsset, uint256 assetId, address indexed to);

    error AssetNotSupported();

    constructor(
        bytes32 supportedAssetsRoot_
    ) ERC721("Astaria NFT Wrapper", "Star NFT") {
        supportedAssetsRoot = supportedAssetsRoot_;
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

    function encumberAsset(uint tokenId_, bytes32 leinHash) external {
        require(msg.sender == address (bondController), "Can only be sent from BondController");
        bytes32 positionHash = keccak256(abi.encodePacked(tokenId_, leinHash));
        liens[tokenId_].push(leinHash);
        lienPositions[positionHash] = liens[tokenId_].length - 1;
    }
    function unEncumberAsset(uint tokenId_, bytes32 leinHash) external {
        require(msg.sender == address (bondController), "Can only be sent from BondController");
        bytes32 positionHash = keccak256(abi.encodePacked(tokenId_, leinHash));
        delete liens[tokenId_][lienPositions[positionHash]];
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
        bytes memory assetData = starToUnderlying[starTokenId];
        (address underlyingAsset, uint256 assetId) = abi.decode(assetData, (address, uint));
        ERC721(underlyingAsset).safeTransferFrom(address(this), releaseTo, assetId);
        emit ReleaseTo(underlyingAsset, assetId, releaseTo);
    }

    function tokenURI(
        uint256 starTokenId
    )
    view
    virtual
    override
    public
    returns (string memory) {
        bytes memory assetData = starToUnderlying[starTokenId];
        (address underlyingAsset, uint256 assetId) = abi.decode(assetData, (address, uint));
        return ERC721(underlyingAsset).tokenURI(assetId);
    }

    function onERC721Received(
        address operator_,
        address from_,
        uint256 tokenId_,
        bytes calldata data_
    ) override external returns (bytes4) {
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

        //decode the asset data, hash it, get the matching hook
        //scrub data here or in the hook? if here the hook cannot ever be done in a malicious way since we can prevent actions that would destroy custody
        bytes memory assetData = starToUnderlying[starTokenId];
        (address underlyingAsset, uint256 assetId) = abi.decode(assetData, (address, uint));
        //encode underlyingasset and assetId into hook call

        bytes memory hookData = abi.encodePacked(underlyingAsset, assetId, hookData_);

        address(utilityHooks[underlyingAsset]).delegatecall(hookData);
        //check to ensure that the assets have come back to this contracts context after the delegate call
    }

    //receive hook on the bond vault to setup leins
}