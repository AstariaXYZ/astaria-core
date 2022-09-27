pragma solidity ^0.8.17;

import {IAstariaRouter} from "../interfaces/IAstariaRouter.sol";
import {IStrategyValidator} from "../interfaces/IStrategyValidator.sol";

interface IStrategyValidator {
    function validateAndParse(
        IAstariaRouter.NewLienRequest memory params,
        address borrower,
        address collateralTokenContract,
        uint256 collateralTokenId
    ) external virtual returns (bytes32[] memory, IAstariaRouter.LienDetails memory);
}
