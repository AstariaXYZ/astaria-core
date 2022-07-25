pragma solidity ^0.8.15;
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IBrokerRouter} from "../interfaces/IBrokerRouter.sol";

library ValidateTerms {
    function validateTerms(IBrokerRouter.Terms memory params, bytes32 root)
        internal
        pure
        returns (bool)
    {
        bytes32 leaf;
        if (params.strategyType == uint256(0)) {
            // borrower based so check on msg sender
            //new structure, of borrower based
            leaf = keccak256(
                params.collateralVault,
                params.bondVaults[0],
                msg.sender,
                params.indexes[0],
                params.amounts[0]
            );
        } else {
            leaf = leaf = keccak256(
                //current structure
                abi.encode(
                    bytes32(params.collateralVault),
                    params.maxAmount,
                    params.maxDebt,
                    params.rate,
                    params.maxRate,
                    params.duration,
                    params.schedule
                )
            );
        }

        //        bytes32 leaf = keccak256(
        //            abi.encode(
        //                bytes32(params.collateralVault),
        //                params.maxAmount,
        //                params.maxDebt,
        //                params.rate,
        //                params.maxRate,
        //                params.duration,
        //                params.schedule
        //            )
        //        );
        return MerkleProof.verify(params.proof, root, leaf);
    }
}
