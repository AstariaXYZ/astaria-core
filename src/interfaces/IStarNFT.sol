pragma solidity ^0.8.0;
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";

interface IStarNFT is IERC721 {
    enum LienAction {
        ENCUMBER,
        UN_ENCUMBER,
        SWAP_VAULT
    }

    function liens(uint256) external returns (uint8);

    function getTotalLiens(uint256) external returns (uint256);

    function getLien(uint256 _starId, uint256 _position)
        external
        view
        returns (
            address,
            uint256,
            uint256
        );

    function getLiens(uint256 _starId)
        external
        view
        returns (
            address[] memory,
            uint256[] memory,
            uint256[] memory
        );

    function manageLien(
        uint256 _tokenId,
        LienAction _action,
        bytes calldata _lienData
    ) external;

    function auctionVault(
        uint256 tokenId,
        uint256 reservePrice,
        address initiator,
        uint256 initiatorFee
    ) external;

    function getUnderlyingFromStar(uint256 starId_)
        external
        view
        returns (address, uint256);
}
