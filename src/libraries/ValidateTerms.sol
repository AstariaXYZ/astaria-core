pragma solidity ^0.8.13;
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IBrokerRouter} from "../interfaces/IBrokerRouter.sol";

library ValidateTerms {
    function validateTerms(IBrokerRouter.Terms memory params, bytes32 root)
        internal
        pure
        returns (bool)
    {
        bytes32 leaf = keccak256(
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
        return MerkleProof.verify(params.proof, root, leaf);
    }
}
