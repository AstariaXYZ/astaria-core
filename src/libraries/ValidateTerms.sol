pragma solidity ^0.8.16;

import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IAstariaRouter} from "../interfaces/IAstariaRouter.sol";

library ValidateTerms {
    event LogCollateral(IAstariaRouter.CollateralDetails);
    event LogCollection(IAstariaRouter.CollectionDetails);
    event LogBytes32(bytes32);
    event LogLien(IAstariaRouter.LienDetails);

    event LogNOR(IAstariaRouter.NewLienRequest);

    function validateTerms(IAstariaRouter.NewLienRequest memory params, address borrower)
        internal
        returns (bool, IAstariaRouter.LienDetails memory ld)
    {
        bytes32 leaf;
        if (params.obligationType == uint8(IAstariaRouter.ObligationType.STANDARD)) {
            IAstariaRouter.CollateralDetails memory cd =
                abi.decode(params.obligationDetails, (IAstariaRouter.CollateralDetails));
            // borrower based so check on msg sender
            //new structure, of borrower based
            emit LogCollateral(cd);
            emit LogNOR(params);
            emit LogLien(cd.lien);

            //[
            //    'uint8',   'address',
            //    'uint256', 'address',
            //    'uint256', 'uint256',
            //    'uint256', 'uint256',
            //    'uint256'
            //  ],
            //  [
            //    '1',
            //    '0xCC61bD887b6695f0C65390931e3e641406dCBb67',
            //    '1',
            //    '0x0000000000000000000000000000000000000000',
            //    '10000000000000000000',
            //    '1000000000000000000',
            //    '50000000000000',
            //    '75000000000000',
            //    '601'
            //  ]

            if (cd.borrower != address(0)) {
                require(borrower == cd.borrower, "invalid borrower requesting commitment");
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

            emit LogBytes32(leaf);
            ld = cd.lien;
        } else if (params.obligationType == uint8(IAstariaRouter.ObligationType.COLLECTION)) {
            IAstariaRouter.CollectionDetails memory cd =
                abi.decode(params.obligationDetails, (IAstariaRouter.CollectionDetails));

            if (cd.borrower != address(0)) {
                require(borrower == cd.borrower, "invalid borrower requesting commitment");
            }

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
        }

        return (MerkleProof.verify(params.obligationProof, params.obligationRoot, leaf), ld);
    }

    //decode obligationData into structs
    function getLienDetails(uint8 obligationType, bytes memory obligationData)
        internal
        view
        returns (IAstariaRouter.LienDetails memory)
    {
        if (obligationType == uint8(IAstariaRouter.ObligationType.STANDARD)) {
            IAstariaRouter.CollateralDetails memory cd = abi.decode(obligationData, (IAstariaRouter.CollateralDetails));
            return (cd.lien);
        } else if (obligationType == uint8(IAstariaRouter.ObligationType.COLLECTION)) {
            IAstariaRouter.CollectionDetails memory cd = abi.decode(obligationData, (IAstariaRouter.CollectionDetails));
            return (cd.lien);
        } else {
            revert("unknown obligation type");
        }
    }

    //decode obligationData into structs
    function getCollateralDetails(uint8 obligationType, bytes memory obligationData)
        internal
        view
        returns (IAstariaRouter.CollateralDetails memory)
    {
        if (obligationType == uint8(IAstariaRouter.ObligationType.STANDARD)) {
            IAstariaRouter.CollateralDetails memory cd = abi.decode(obligationData, (IAstariaRouter.CollateralDetails));
            return (cd);
        } else {
            revert("unknown obligation type");
        }
    }

    function getCollectionDetails(uint8 obligationType, bytes memory obligationData)
        internal
        view
        returns (IAstariaRouter.CollectionDetails memory)
    {
        if (obligationType == uint8(IAstariaRouter.ObligationType.COLLECTION)) {
            IAstariaRouter.CollectionDetails memory cd = abi.decode(obligationData, (IAstariaRouter.CollectionDetails));
            return (cd);
        } else {
            revert("unknown obligation type");
        }
    }
}
