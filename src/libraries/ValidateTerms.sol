pragma solidity ^0.8.15;
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IBrokerRouter} from "../interfaces/IBrokerRouter.sol";

library ValidateTerms {
    event LogCollateral(IBrokerRouter.CollateralDetails);
    event LogCollection(IBrokerRouter.CollectionDetails);
    event LogBytes32(bytes32);

    event LogNOR(IBrokerRouter.NewObligationRequest);

    function validateTerms(IBrokerRouter.NewObligationRequest memory params)
        internal
        returns (bool, IBrokerRouter.LienDetails memory ld)
    {
        bytes32 leaf;
        if (
            params.obligationType ==
            uint8(IBrokerRouter.ObligationType.STANDARD)
        ) {
            IBrokerRouter.CollateralDetails memory cd = abi.decode(
                params.obligationDetails,
                (IBrokerRouter.CollateralDetails)
            );
            // borrower based so check on msg sender
            //new structure, of borrower based
            emit LogCollateral(cd);
            emit LogNOR(params);

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
        } else if (
            params.obligationType ==
            uint8(IBrokerRouter.ObligationType.COLLECTION)
        ) {
            IBrokerRouter.CollectionDetails memory cd = abi.decode(
                params.obligationDetails,
                (IBrokerRouter.CollectionDetails)
            );

            leaf = keccak256(
                abi.encode(
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

        return (
            MerkleProof.verify(
                params.obligationProof,
                params.obligationRoot,
                leaf
            ),
            ld
        );
    }
}
