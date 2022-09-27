pragma solidity ^0.8.16;

import {IAstariaRouter} from "../interfaces/IAstariaRouter.sol";
import {BaseValidatorV1} from "./BaseValidator.sol";

interface ICollectionValidator {
    struct Details {
        uint8 version;
        address token;
        address borrower;
        IAstariaRouter.LienDetails lien;
    }
}

contract CollectionValidator is BaseValidatorV1, ICollectionValidator {
    function getLeafDetails(bytes memory nlrDetails) internal pure returns (ICollectionValidator.Details memory) {
        return abi.decode(nlrDetails, (ICollectionValidator.Details));
    }

    function assembleLeaf(ICollectionValidator.Details memory details) internal pure returns (bytes memory) {
        return abi.encodePacked(
            details.version, // 1 is the version of the structure
            details.token, // token address
            details.borrower, // borrower address
            details.lien.maxAmount, // max amount
            details.lien.rate, // rate
            details.lien.duration, // duration
            details.lien.maxPotentialDebt
        );
    }

    function validateAndParse(
        IAstariaRouter.NewLienRequest memory params,
        address borrower,
        address collateralTokenContract,
        uint256 collateralTokenId
    ) external view override returns (bytes32[] memory leaves, IAstariaRouter.LienDetails memory ld) {
        leaves = new bytes32[](2);
        if (params.nlrType == uint8(IAstariaRouter.LienRequestType.COLLECTION)) {
            ICollectionValidator.Details memory cd = getLeafDetails(params.nlrDetails);

            if (cd.borrower != address(0)) {
                require(borrower == cd.borrower, "invalid borrower requesting commitment");
            }
            require(cd.token == collateralTokenContract, "invalid token contract");

            leaves[0] = keccak256(assembleStrategyLeaf(params.strategy));

            leaves[1] = keccak256(assembleLeaf(cd));
            ld = cd.lien;
        } else {
            revert("unsupported/strategy");
        }
    }
}
