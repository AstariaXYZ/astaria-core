pragma solidity ^0.8.15;

import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";

interface ICollateralVault is IERC721 {
    function auctionVault(
        uint256 collateralVault,
        address initiator,
        uint256 initiatorFee
    ) external returns (uint256);

    function AUCTION_HOUSE() external view returns (IAuctionHouse);

    function getUnderlying(uint256) external view returns (address, uint256);

    function depositERC721(
        address depositFor_,
        address tokenContract_,
        uint256 tokenId_,
        bytes32[] calldata proof_
    ) external;
}
