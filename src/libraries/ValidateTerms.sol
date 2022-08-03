pragma solidity ^0.8.15;
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IBrokerRouter} from "../interfaces/IBrokerRouter.sol";

library ValidateTerms {
    function validateTerms(IBrokerRouter.NewObligationRequest memory params)
        internal
        pure
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

            leaf = keccak256(
                abi.encodePacked(
                    uint8(1), // 1 is the version of the structure
                    cd.token, // token address
                    cd.tokenId, // token id
                    cd.borrower, // borrower address
                    cd.lien.maxAmount, // max amount
                    cd.lien.maxSeniorDebt, // max senior debt
                    cd.lien.rate, // rate
                    cd.lien.duration, // duration
                    cd.lien.schedule // schedule
                )
                //                abi.encode(cd)
            );
            ld = cd.lien;
        } else if (
            params.obligationType ==
            uint8(IBrokerRouter.ObligationType.COLLECTION)
        ) {
            IBrokerRouter.CollectionDetails memory cd = abi.decode(
                params.obligationDetails,
                (IBrokerRouter.CollectionDetails)
            );

            //[
            //      BigNumber.from(1).toString(), // type
            //      getAddress(tokenAddress), // token
            //      BigNumber.from(tokenId).toString(), // tokenId
            //      getAddress(args.shift()), // borrower
            //      solidityPack(["bytes"], [args.shift()]), // lien
            //    ]

            leaf = keccak256(abi.encode(cd));
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
