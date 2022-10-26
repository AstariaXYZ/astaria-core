pragma solidity ^0.8.17;

interface IVaultImplementation {
  enum InvalidRequestReason {
    INVALID_SIGNATURE,
    INVALID_STRATEGIST,
    INVALID_COMMITMENT,
    INVALID_AMOUNT,
    INSUFFICIENT_FUNDS,
    INVALID_RATE,
    INVALID_POTENTIAL_DEBT
  }

  error InvalidRequest(InvalidRequestReason);
}
