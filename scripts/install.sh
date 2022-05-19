#!/bin/bash

# forge install
if [ -f "~/.foundry/bin/forge" ]; then
  read -p "Forge not detected, do you want to install [y/n]" FORGE_INSTALL
  if [ $FORGE_INSTALL -e "y"]; then
      curl -L https://foundry.paradigm.xyz | bash
  else
    echo "You must install forge to use this repo, visit https://getfoundry.sh"
    exit 1;
  fi
fi

YARN_VERSION=$(yarn version)

# if no yarn install via npm
if [ ! $(which yarn) ]; then

  read -p "Yarn not detected, do you want to install [y/n]" YARN_INSTALL
  if [ $YARN_INSTALL -e "y" ]; then
    npm install -g
  else
     echo "You must install yarn to use workspaces"
    exit 1;
  fi
fi

forge install

yarn