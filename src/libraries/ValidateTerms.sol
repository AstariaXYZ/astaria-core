pragma solidity ^0.8.16;

import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IAstariaRouter} from "../interfaces/IAstariaRouter.sol";

interface V3PositionManager {
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

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

            leaf = keccak256(
                abi.encodePacked(
                    cd.version,
                    cd.token,
                    cd.tokenId,
                    cd.borrower,
                    cd.lien.maxAmount,
                    cd.lien.maxSeniorDebt,
                    cd.lien.rate,
                    cd.lien.maxInterestRate,
                    cd.lien.duration
                )
            );

            ld = cd.lien;
        } else if (params.obligationType == uint8(IAstariaRouter.LienRequestType.COLLECTION)) {
            IAstariaRouter.CollectionDetails memory cd =
                abi.decode(params.obligationDetails, (IAstariaRouter.CollectionDetails));

            if (cd.borrower != address(0)) {
                require(borrower == cd.borrower, "invalid borrower requesting commitment");
            }
            require(cd.token == collateralTokenContract, "invalid token contract");

            leaf = keccak256(
                abi.encodePacked(
                    cd.version, // 1 is the version of the structure
                    cd.token, // token address
                    cd.borrower, // borrower address
                    cd.lien.maxAmount, // max amount
                    cd.lien.maxSeniorDebt, // max senior debt
                    cd.lien.rate, // rate
                    cd.lien.maxInterestRate, // max implied rate
                    cd.lien.duration // duration
                )
            );
            ld = cd.lien;
        } else if (params.obligationType == uint8(IAstariaRouter.LienRequestType.UNIV3_LIQUIDITY)) {
            IAstariaRouter.UNIV3LiquidityDetails memory details =
                abi.decode(params.obligationDetails, (IAstariaRouter.UNIV3LiquidityDetails));

            if (details.borrower != address(0)) {
                require(borrower == details.borrower, "invalid borrower requesting commitment");
            }

            require(details.token == collateralTokenContract, "invalid token contract");

            V3PositionManager v3Manager = V3PositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
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
        returns (IAstariaRouter.LienDetails memory)
    {
        if (params.obligationType == uint8(IAstariaRouter.LienRequestType.STANDARD)) {
            IAstariaRouter.CollateralDetails memory cd =
                abi.decode(params.obligationDetails, (IAstariaRouter.CollateralDetails));
            return (cd.lien);
        } else if (params.obligationType == uint8(IAstariaRouter.LienRequestType.COLLECTION)) {
            IAstariaRouter.CollectionDetails memory cd =
                abi.decode(params.obligationDetails, (IAstariaRouter.CollectionDetails));
            return (cd.lien);
        } else {
            revert("unknown obligation type");
        }
    }

    //decode obligationData into structs
    function getCollateralDetails(uint8 obligationType, bytes memory obligationData)
        internal
        pure
        returns (IAstariaRouter.CollateralDetails memory)
    {
        if (obligationType == uint8(IAstariaRouter.LienRequestType.STANDARD)) {
            IAstariaRouter.CollateralDetails memory cd = abi.decode(obligationData, (IAstariaRouter.CollateralDetails));
            return (cd);
        } else {
            revert("unknown obligation type");
        }
    }

    function getCollectionDetails(uint8 obligationType, bytes memory obligationData)
        internal
        pure
        returns (IAstariaRouter.CollectionDetails memory)
    {
        if (obligationType == uint8(IAstariaRouter.LienRequestType.COLLECTION)) {
            IAstariaRouter.CollectionDetails memory cd = abi.decode(obligationData, (IAstariaRouter.CollectionDetails));
            return (cd);
        } else {
            revert("unknown obligation type");
        }
    }
}
