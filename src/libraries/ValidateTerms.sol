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
                    uint256(0),
                    cd.token,
                    cd.tokenId,
                    cd.borrower,
                    abi.encode(
                        cd.lien.token,
                        cd.lien.maxAmount,
                        cd.lien.maxSeniorDebt,
                        cd.lien.rate,
                        cd.lien.duration,
                        cd.lien.schedule
                    )
                )
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
            // borrower based so check on msg sender
            bytes memory collateral = cd.borrower != address(0)
                ? abi.encodePacked(cd.token, cd.borrower)
                : abi.encodePacked(cd.token);

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
