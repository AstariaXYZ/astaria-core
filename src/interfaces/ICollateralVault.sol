pragma solidity ^0.8.0;
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IBrokerRouter} from "../BrokerRouter.sol";

interface ICollateralVault is IERC721 {
    function auctionVault(
        uint256 collateralVault,
        address initiator,
        uint256 initiatorFee
    ) external returns (uint256);

    function getUnderlyingFromStar(uint256 starId_)
        external
        view
        returns (address, uint256);
}
