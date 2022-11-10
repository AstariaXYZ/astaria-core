#!/usr/bin/env bash
NPX="npx"

cd lib/astaria-sdk && yarn && yarn build && cd ../..

if [[ -z $CI ]] ; then
  NPX=
fi
SCRIPT="${NPX-:""} tsc"

${SCRIPT}