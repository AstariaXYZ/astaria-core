pragma solidity ^0.8.16;

import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IAstariaRouter} from "../interfaces/IAstariaRouter.sol";
import {IV3PositionManager} from "../interfaces/IV3PositionManager.sol";

library ValidateTerms {
    function validateTerms(
        IAstariaRouter.NewLienRequest memory params,
        address borrower,
        address collateralTokenContract,
        uint256 collateralTokenId
    )
        internal
        returns (bool, IAstariaRouter.LienDetails memory ld)
    {
        bytes32 leaf;

        if (params.obligationType == uint8(IAstariaRouter.LienRequestType.STANDARD)) {
            IAstariaRouter.CollateralDetails memory cd =
                abi.decode(params.obligationDetails, (IAstariaRouter.CollateralDetails));

            if (cd.borrower != address(0)) {
                require(borrower == cd.borrower, "invalid borrower requesting commitment");
            }

            require(cd.token == collateralTokenContract, "invalid token contract");

            if (cd.tokenId != 0) {
                require(cd.tokenId == collateralTokenId, "invalid token id");
            }

            leaf = keccak256(_encodeCollateralDetails(cd));

            ld = cd.lien;
        } else if (params.obligationType == uint8(IAstariaRouter.LienRequestType.COLLECTION)) {
            IAstariaRouter.CollectionDetails memory cd =
                abi.decode(params.obligationDetails, (IAstariaRouter.CollectionDetails));

            if (cd.borrower != address(0)) {
                require(borrower == cd.borrower, "invalid borrower requesting commitment");
            }
            require(cd.token == collateralTokenContract, "invalid token contract");

            leaf = keccak256(_encodeCollectionDetails(cd));
            ld = cd.lien;
        } else if (params.obligationType == uint8(IAstariaRouter.LienRequestType.UNIV3_LIQUIDITY)) {
            IAstariaRouter.UNIV3LiquidityDetails memory details =
                abi.decode(params.obligationDetails, (IAstariaRouter.UNIV3LiquidityDetails));

            if (details.borrower != address(0)) {
                require(borrower == details.borrower, "invalid borrower requesting commitment");
            }

            require(details.token == collateralTokenContract, "invalid token contract");

            IV3PositionManager v3Manager = IV3PositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
            (,, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
                v3Manager.positions(collateralTokenId);

            if (details.fee != uint24(0)) {
                require(fee == details.fee, "fee mismatch");
            }
            require(details.assets[0] == token0 && details.assets[1] == token1, "invalid pair");
            require(details.tickUpper == tickUpper && details.tickLower == tickLower, "invalid range");

            require(details.minLiquidity <= liquidity, "insufficient liquidity");

            leaf = keccak256(_encodeUNIV3LiquidityDetails(details));
            ld = details.lien;
        }

        return (MerkleProof.verify(params.obligationProof, params.obligationRoot, leaf), ld);
    }

    function _encodeCollateralDetails(IAstariaRouter.CollateralDetails memory details)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            details.version,
            details.token,
            details.tokenId,
            details.borrower,
            details.lien.maxAmount,
            details.lien.maxSeniorDebt,
            details.lien.rate,
            details.lien.maxInterestRate,
            details.lien.duration
        );
    }

    function _encodeCollectionDetails(IAstariaRouter.CollectionDetails memory details)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            details.version, // 1 is the version of the structure
            details.token, // token address
            details.borrower, // borrower address
            details.lien.maxAmount, // max amount
            details.lien.maxSeniorDebt, // max senior debt
            details.lien.rate, // rate
            details.lien.maxInterestRate, // max implied rate
            details.lien.duration // duration
        );
    }

    function _encodeUNIV3LiquidityDetails(IAstariaRouter.UNIV3LiquidityDetails memory details)
        internal
        pure
        returns (bytes memory)
    {
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
            details.lien.maxSeniorDebt,
            details.lien.rate,
            details.lien.maxInterestRate,
            details.lien.duration
        );
    }

    //decode obligationData into structs
    function getLienDetails(IAstariaRouter.NewLienRequest memory params)
        internal
        pure
        returns (IAstariaRouter.LienDetails memory lienDetails)
    {
        if (params.obligationType == uint8(IAstariaRouter.LienRequestType.STANDARD)) {
            lienDetails = (getCollateralDetails(params.obligationDetails).lien);
        } else if (params.obligationType == uint8(IAstariaRouter.LienRequestType.COLLECTION)) {
            lienDetails = (getCollectionDetails(params.obligationDetails).lien);
        } else if (params.obligationType == uint256(IAstariaRouter.LienRequestType.UNIV3_LIQUIDITY)) {
            lienDetails = (getUNIV3LiquidityDetails(params.obligationDetails).lien);
        } else {
            revert("unknown obligation type");
        }
    }

    //decode obligationData into structs
    function getCollateralDetails(bytes memory obligationData)
        internal
        pure
        returns (IAstariaRouter.CollateralDetails memory)
    {
        return abi.decode(obligationData, (IAstariaRouter.CollateralDetails));
    }

    //decode obligationData into structs
    function getUNIV3LiquidityDetails(bytes memory obligationData)
        internal
        pure
        returns (IAstariaRouter.UNIV3LiquidityDetails memory)
    {
        return abi.decode(obligationData, (IAstariaRouter.UNIV3LiquidityDetails));
    }

    function getCollectionDetails(bytes memory obligationData)
        internal
        pure
        returns (IAstariaRouter.CollectionDetails memory)
    {
        return abi.decode(obligationData, (IAstariaRouter.CollectionDetails));
    }
}
