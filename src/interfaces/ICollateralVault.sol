pragma solidity ^0.8.13;
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";

interface ICollateralVault is IERC721 {
    function auctionVault(
        uint256 collateralVault,
        address initiator,
        uint256 initiatorFee
    ) external returns (uint256);

    function getUnderlying(uint256 starId_)
        external
        view
        returns (address, uint256);

    function depositERC721(
        address depositFor_,
        address tokenContract_,
        uint256 tokenId_,
        bytes32[] calldata proof_
    ) external;
}
