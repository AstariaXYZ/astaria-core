pragma solidity ^0.8.15;

import {IERC721} from "gpl/interfaces/IERC721.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";

interface ICollateralBase {
    function auctionVault(uint256 collateralId, address initiator, uint256 initiatorFee, uint256 epochCap)
        external
        returns (uint256);

    function AUCTION_HOUSE() external view returns (IAuctionHouse);

    function AUCTION_WINDOW() external view returns (uint256);

    function getUnderlying(uint256) external view returns (address, uint256);

    function depositERC721(address depositFor_, address tokenContract_, uint256 tokenId_) external;
}

interface ICollateralToken is ICollateralBase, IERC721 {}
