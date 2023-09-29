#!/bin/env zsh

# 11 is updating implementations

# enum ImplementationType {
  #    PrivateVault,
  #    PublicVault,
  #    WithdrawProxy,
  #    ClearingHouse
  #  }


IMPL=$1
ADDRESS=$2
cast calldata 'fileGuardian((uint8,bytes)[])' "[(11,000000000000000000000000000000000000000000000000000000000000000${IMPL}000000000000000000000000${ADDRESS:2})]"