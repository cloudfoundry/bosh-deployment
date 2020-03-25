#!/bin/bash

set -eu -o pipefail

if [ ! -f "${PWD}/creds.yml" ]; then
  echo "Couldn't find 'creds.yml'."
  echo "You are not running this within the bosh-lite deployment folder or you didn't deploy bosh-lite yet."
  echo

  exit 1
fi

bosh int  "${PWD}/creds.yml" --path /jumpbox_ssh/private_key > "${PWD}/ssh_key"
chmod 600 "${PWD}/ssh_key"
ssh -i "${PWD}/ssh_key" jumpbox@192.168.50.6
