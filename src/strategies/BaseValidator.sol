pragma solidity ^0.8.17;

import {IAstariaRouter} from "../interfaces/IAstariaRouter.sol";
import {IStrategyValidator} from "../interfaces/IStrategyValidator.sol";

abstract contract BaseValidatorV1 is IStrategyValidator {
    event LogStrategy(IAstariaRouter.StrategyDetails);

    function assembleStrategyLeaf(IAstariaRouter.StrategyDetails memory params) internal returns (bytes memory) {
        emit LogStrategy(params);
        return abi.encode(params);
    }
}
