// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";


contract SafeNFT is ERC721, IERC721Receiver {

    mapping(ERC721 => bool) underlyingNFTsEnabled;

    mapping(ERC721 => address) utilityHooks;

    mapping(ERC721 => mapping(uint => address)) assetToDepositor;

    mapping(ERC721 => mapping(uint => address[])) assetToBondVaults; //leins

    mapping(uint => mapping(ERC721 => uint)) starToUnderlying;

    address public NFTBondController;

    event Deposit(address from, address underlyingNFT, uint256 tokenId);

    constructor(
        address bondController_
    ) ERC721("Astaria NFT Wrapper", "Star NFT") {
        NFTBondController = bondController_;
    }

    modifier onlyDepositor(address underlyingNFT, uint assetId) {
        require(msg.sender == assetToDepositor[underlyingNFT][assetId], "only depositor can call this");
        _;
    }

    modifier noLeins(address underlyingNFT, uint assetId) {
        require(uint(0) == assetToDepositor[underlyingNFT][assetId].length, "must be no liens to call this");
        _;
    }

    function releaseToAddress(address underlyingNFT, uint assetId, address releaseTo) public noLeins(underlyingNFT, assetId) onlyDepositor(underlyingNFT, assetId) { //call back from the fractional contract when you release the nft back in
        //check leins
        ERC721(underlyingNFT).safeTransferFrom(address(this), releaseTo, assetId);
        emit ReleaseTo(releaseTo);
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        (ERC721 asset, uint assetId) = starToUnderlying[tokenId]; // I think i can do this
        return asset.tokenURI(assetId);
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) override external returns (bytes4) {
        require(ERC721(msg.sender).ownerOf(tokenId) == address(this));
        emit Deposit(from, address(msg.sender), tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    function auctionUnderlyingAsset() public {
        //stub
    }

    //utility hooks are custom contracts that let you interact with different parts of the underlying ecosystem
    //claim airdrops etc/
    //potentially chainable?
    function utilityHook(address underlyingNFT, uint tokenId, bytes calldata hookData) onlyDepositor(underlyingNFT, tokenId) public {
        //scrub data here or in the hook? if here the hook cannot ever be done in a malicious way since we can prevent actions that would destroy custody
        address(utilityHooks[underlyingNFT]).delegatecall(hookData);
    }

    //receive hook on the bond vault to setup leins
}