pragma solidity ^0.8.17;

import {IAstariaRouter} from "../interfaces/IAstariaRouter.sol";
import {BaseValidatorV1} from "./BaseValidator.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";

interface ICollectionValidator {
    struct Details {
        uint8 version;
        address token;
        address borrower;
        IAstariaRouter.LienDetails lien;
    }
}

contract CollectionValidator is BaseValidatorV1, ICollectionValidator {
    uint16 public constant MAX_TOKENS = 100;

    function getLeafDetails(bytes memory nlrDetails) internal pure returns (ICollectionValidator.Details memory) {
        return abi.decode(nlrDetails, (ICollectionValidator.Details));
    }

    function assembleLeaf(ICollectionValidator.Details memory details) internal pure returns (bytes memory) {
        return abi.encode(details);
    }

    function validateAndParse(
        IAstariaRouter.NewLienRequest memory params,
        address borrower,
        address collateralTokenContract,
        uint256 collateralTokenId
    ) external returns (bytes32[] memory leaves, IAstariaRouter.LienDetails memory ld) {
        leaves = new bytes32[](2);
        ICollectionValidator.Details memory cd = getLeafDetails(params.nlrDetails);

        if (cd.borrower != address(0)) {
            require(borrower == cd.borrower, "invalid borrower requesting commitment");
        }
        require(cd.token == collateralTokenContract, "invalid token contract");

        leaves[0] = keccak256(assembleStrategyLeaf(params.strategy));

        leaves[1] = keccak256(assembleLeaf(cd));
        ld = cd.lien;
    }
}
