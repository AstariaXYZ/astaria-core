pragma solidity ^0.8.16;

import {IAstariaRouter} from "../interfaces/IAstariaRouter.sol";
import {BaseValidatorV1} from "./BaseValidator.sol";

interface IUniqueValidator {
    //decode obligationData into structs

    struct Details {
        uint8 version;
        address token;
        uint256 tokenId;
        address borrower;
        IAstariaRouter.LienDetails lien;
    }
}

contract UniqueValidator is BaseValidatorV1, IUniqueValidator {
    //decode obligationData into structs

    function getLeafDetails(bytes memory nlrDetails) public pure returns (Details memory) {
        return abi.decode(nlrDetails, (Details));
    }

    function assembleLeaf(Details memory details) public pure returns (bytes memory) {
        return abi.encodePacked(
            details.version,
            details.token,
            details.tokenId,
            details.borrower,
            details.lien.maxAmount,
            details.lien.rate,
            details.lien.duration,
            details.lien.maxPotentialDebt
        );
    }

    function validateAndParse(
        IAstariaRouter.NewLienRequest memory params,
        address borrower,
        address collateralTokenContract,
        uint256 collateralTokenId
    )
        external
        view
        override
        returns (bytes32[] memory leaves, IAstariaRouter.LienDetails memory ld)
    {
        leaves = new bytes32[](2);
        if (params.nlrType == uint8(IAstariaRouter.LienRequestType.UNIQUE)) {
            Details memory cd = getLeafDetails(params.nlrDetails);

            if (cd.borrower != address(0)) {
                require(borrower == cd.borrower, "invalid borrower requesting commitment");
            }

            require(cd.token == collateralTokenContract, "invalid token contract");

            require(cd.tokenId == collateralTokenId, "invalid token id");
            leaves[0] = keccak256(assembleStrategyLeaf(params.strategy));

            leaves[1] = keccak256(assembleLeaf(cd));

            ld = cd.lien;
        } else {
            revert("unsupported/strategy");
        }
    }
}
