pragma solidity ^0.8.16;

import {IAstariaRouter} from "../interfaces/IAstariaRouter.sol";
import {BaseValidatorV1} from "./BaseValidator.sol";
import {IV3PositionManager} from "../interfaces/IV3PositionManager.sol";

interface IUNI_V3Validator {
    struct Details {
        uint8 version;
        address token;
        address[] assets;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 minLiquidity;
        address borrower;
        IAstariaRouter.LienDetails lien;
    }
}

contract UNI_V3Validator is BaseValidatorV1, IUNI_V3Validator {
    IV3PositionManager V3_NFT_POSITION_MGR = IV3PositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    function assembleLeaf(IUNI_V3Validator.Details memory details) internal pure returns (bytes memory) {
        return abi.encodePacked(
            details.version,
            details.token,
            details.fee,
            details.assets[0],
            details.assets[1],
            details.tickLower,
            details.tickUpper,
            details.minLiquidity,
            details.borrower,
            details.lien.maxAmount,
            details.lien.rate,
            details.lien.duration,
            details.lien.maxPotentialDebt
        );
    }

    //decode obligationData into structs
    function getLeafDetails(bytes memory nlrDetails) internal pure returns (IUNI_V3Validator.Details memory) {
        return abi.decode(nlrDetails, (IUNI_V3Validator.Details));
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
        if (params.nlrType == uint8(IAstariaRouter.LienRequestType.UNIV3_LIQUIDITY)) {
            IUNI_V3Validator.Details memory details = getLeafDetails(params.nlrDetails);

            if (details.borrower != address(0)) {
                require(borrower == details.borrower, "invalid borrower requesting commitment");
            }

            //ensure its also the correct token
            require(details.token == collateralTokenContract, "invalid token contract");

            (,, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
                V3_NFT_POSITION_MGR.positions(collateralTokenId);

            if (details.fee != uint24(0)) {
                require(fee == details.fee, "fee mismatch");
            }
            require(details.assets[0] == token0 && details.assets[1] == token1, "invalid pair");
            require(details.tickUpper == tickUpper && details.tickLower == tickLower, "invalid range");

            require(details.minLiquidity <= liquidity, "insufficient liquidity");

            leaves[0] = keccak256(assembleStrategyLeaf(params.strategy));

            leaves[1] = keccak256(assembleLeaf(details));
            ld = details.lien;
        } else {
            revert("unsupported/strategy");
        }
    }
}
