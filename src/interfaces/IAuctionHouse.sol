pragma solidity ^0.8.13;
pragma experimental ABIEncoderV2;

interface IAuctionHouse {
    function createAuction(
        uint256 tokenId,
        uint256 duration,
        uint256 reservePrice,
        bytes32 bondVault
    ) external returns (uint256);

    function setAuctionReservePrice(uint256 auctionId, uint256 reservePrice)
        external;

    function createBid(uint256 auctionId, uint256 amount) external payable;

    function endAuction(uint256 auctionId) external returns (uint256, address);
}
