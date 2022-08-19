pragma solidity ^0.8.16;

import {IERC721} from "gpl/interfaces/IERC721.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";

interface IEscrowBase {
    function auctionVault(uint256 escrowId, address initiator, uint256 initiatorFee) external returns (uint256);

    function AUCTION_HOUSE() external view returns (IAuctionHouse);

    function getUnderlying(uint256) external view returns (address, uint256);

    function depositERC721(address depositFor_, address tokenContract_, uint256 tokenId_) external;
}

interface IEscrowToken is IERC721, IEscrowBase {}
