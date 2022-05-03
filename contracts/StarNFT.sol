// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";


contract SafeNFT is ERC721, IERC721Receiver {


    enum AssetType {
        ERC20,
        ERC721,
        ERC1155
    }

    bytes32 public supportedAssetsRoot;

    mapping(address => address) utilityHooks;

    mapping(uint256 => address) starIdDepositor;

    mapping(uint256 => bytes32[]) liens;

    mapping(uint => bytes) public starToUnderlying;

    address immutable NFTBondController;

    uint public tokenCount;

    event DepositERC20(address indexed from, address indexed tokenContract, uint256 amount);
    event DepositERC721(address indexed from, address indexed tokenContract, uint256 tokenId);
    event DepositERC1155(address indexed from, address indexed tokenContract, uint256 amount);
    event ReleaseTo(address indexed underlyingAsset, uint256 assetId, address indexed to);

    error AssetNotSupported();

    constructor(
        address bondController_
    ) ERC721("Astaria NFT Wrapper", "Star NFT") {
        NFTBondController = bondController_;
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

    modifier onlySupportedAssets(address tokenContract_, bytes32[] calldata proof_) {
        bytes32 leaf = keccak256(abi.encodePacked(tokenContract_));
        bool isValidLeaf = MerkleProof.verify(proof_, supportedAssetsRoot, leaf);
        if (!isValidLeaf) revert AssetNotSupported();
        _;
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
        require(ERC721(msg.sender).ownerOf(tokenId_) == address(this));
        uint starId = uint256(keccak256(abi.encodePacked(address(msg.sender), tokenId_)));
        _mint(from_, starId);
        starToUnderlying[starId] = abi.encodePacked(address(msg.sender), tokenId_);
        starIdDepositor[starId] = from_;
        return IERC721Receiver.onERC721Received.selector;
    }


    function depositERC721(
        address depositFor_,
        address tokenContract_,
        address tokenId_,
        bytes32[] calldata proof_
    ) onlySupportedAssets(tokenContract_, proof_) external {
        require(ERC721(msg.sender).ownerOf(tokenId_) == address(this));
        bytes memory starMap = abi.encodePacked(tokenContract_, tokenId_);
        uint starId = uint256(keccak256(starMap));
        _mint(depositFor_, starId);
        starToUnderlying[starId] = starMap;
        starIdDepositor[starId] = depositFor_;
        emit DepositERC721(depositFor_, tokenContract_, tokenId_);
    }

    function depositERC20(
        address depositFor_,
        address tokenContract_,
        address tokenAmount_,
        bytes32[] calldata proof_
    ) onlySupportedAssets(tokenContract_, proof_) external {
        emit DepositERC20(depositFor_, tokenContract_, tokenAmount_);
    }

    function depositERC1155(
        address depositFor_,
        address tokenContract_,
        address tokenAmount_,
        bytes32[] calldata proof_
    ) onlySupportedAssets(tokenContract_, proof_) external {
        emit DepositERC1155(depositFor_, tokenContract_, tokenAmount_);
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