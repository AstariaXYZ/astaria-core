#!/usr/bin/env bash
# takes in a deployment file and the chain id verifies on etherscan
# needs to have ETHERSCAN_API_KEY set in the environment
set -e
INPUT_FILE=$1
ARG_FILE="$(dirname $INPUT_FILE)/arguments.json"
CHAIN_ID=$(jq -r '.chain' < $INPUT_FILE)
COMPILER_VERSION="0.8.17"
for row in $(jq -c '.transactions[]' < ${INPUT_FILE}); do
    _jq() {
     echo ${row} | jq -r ${1}
    }

    if [[ $(_jq '.transactionType') == "CREATE" ]]; then

      args=$(_jq '.arguments')
      CONSTRUCTOR_ARGS_PATH=""
      if [[ ${args} != "null" ]]; then
        echo ${args} > "${ARG_FILE}"
        CONSTRUCTOR_ARGS_PATH=--constructor-args-path=${ARG_FILE}
      fi
      if ! forge verify-contract "$(_jq '.contractAddress')" "$(_jq '.contractName')" ${ETHERSCAN_API_KEY} --chain ${CHAIN_ID} --compiler-version ${COMPILER_VERSION} ${CONSTRUCTOR_ARGS_PATH}
          then
              echo "failed to verify $(_jq '.contractName')"
              continue
          fi

    fi
done
rm -f ${ARG_FILE}