pragma solidity ^0.8.17;

import {IAstariaRouter} from "../interfaces/IAstariaRouter.sol";
import {IStrategyValidator} from "../interfaces/IStrategyValidator.sol";

abstract contract BaseValidatorV1 is IStrategyValidator {
    function assembleStrategyLeaf(IAstariaRouter.StrategyDetails memory params)
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodePacked(
                params.version,
                params.strategist,
                params.nonce,
                params.deadline,
                params.vault
            );
    }
}
