#!/usr/bin/env bash
NPX="npx"

if [[ -z $CI ]] ; then
  NPX=
fi
SCRIPT="${NPX-:""} tsc"

${SCRIPT}