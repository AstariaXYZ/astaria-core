#!/bin/env zsh

# 10 is updating implementations

# enum ImplementationType {
  #    PrivateVault,
  #    PublicVault,
  #    WithdrawProxy,
  #    ClearingHouse
  #  }


IMPL=$1
ADDRESS=$2
cast calldata 'fileGuardian((uint8,bytes)[])' "[(10,000000000000000000000000000000000000000000000000000000000000000${IMPL}000000000000000000000000${ADDRESS:2})]"