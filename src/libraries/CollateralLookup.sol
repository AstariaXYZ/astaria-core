pragma solidity ^0.8.15;

import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";

library CollateralLookup {
    function computeId(address token, uint256 tokenId)
        internal
        view
        returns (uint256)
    {
        require(
            IERC721(token).supportsInterface(type(IERC721).interfaceId),
            "must support erc721"
        );
        return uint256(keccak256(abi.encodePacked(token, tokenId)));
    }
}
