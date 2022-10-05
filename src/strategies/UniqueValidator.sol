pragma solidity ^0.8.17;

import {IAstariaRouter} from "../interfaces/IAstariaRouter.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {IStrategyValidator} from "../interfaces/IStrategyValidator.sol";

interface IUniqueValidator is IStrategyValidator {
    struct Details {
        uint8 version;
        address token;
        uint256 tokenId;
        address borrower;
        IAstariaRouter.LienDetails lien;
    }
}

contract UniqueValidator is IUniqueValidator {
    //decode obligationData into structs

    event LogLeaf(bytes32 leaf);
    event LogDetails(Details);

    function getLeafDetails(bytes memory nlrDetails) public pure returns (Details memory) {
        return abi.decode(nlrDetails, (Details));
    }

    function assembleLeaf(Details memory details) public returns (bytes memory) {
        emit LogDetails(details);
        return abi.encode(details);
    }

    function validateAndParse(
        IAstariaRouter.NewLienRequest memory params,
        address borrower,
        address collateralTokenContract,
        uint256 collateralTokenId
    ) external override returns (bytes32 leaf, IAstariaRouter.LienDetails memory ld) {
        Details memory cd = getLeafDetails(params.nlrDetails);

        if (cd.borrower != address(0)) {
            require(borrower == cd.borrower, "invalid borrower requesting commitment");
        }

        require(cd.token == collateralTokenContract, "invalid token contract");

        require(cd.tokenId == collateralTokenId, "invalid token id");
        leaf = keccak256(assembleLeaf(cd));
        ld = cd.lien;
    }
}
