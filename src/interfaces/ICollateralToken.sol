pragma solidity ^0.8.15;

import {IERC721} from "gpl/interfaces/IERC721.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";

interface ICollateralBase {
    function auctionVault(uint256 collateralId, address initiator) external returns (uint256);

    function AUCTION_HOUSE() external view returns (IAuctionHouse);

    function AUCTION_WINDOW() external view returns (uint256);

    function getUnderlying(uint256) external view returns (address, uint256);
}

interface ICollateralToken is ICollateralBase, IERC721 {}
