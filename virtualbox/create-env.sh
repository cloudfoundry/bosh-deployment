#!/bin/bash

set -eu

echo "This will create BOSH using VirtualBox with a default configuration."
echo

read -p "Continue? [yN] "
[[ $REPLY =~ ^[Yy]$ ]] || exit 1

echo
echo
echo "===> Creating BOSH Director ===="
echo

bosh create-env bosh-deployment/bosh.yml \
  --state state.json \
  --ops-file bosh-deployment/virtualbox/cpi.yml \
  --ops-file bosh-deployment/virtualbox/outbound-network.yml \
  --ops-file bosh-deployment/bosh-lite.yml \
  --ops-file bosh-deployment/bosh-lite-runc.yml \
  --ops-file bosh-deployment/jumpbox-user.yml \
  --vars-store creds.yml \
  --var director_name=bosh-lite \
  --var internal_ip=192.168.50.6 \
  --var internal_gw=192.168.50.1 \
  --var internal_cidr=192.168.50.0/24 \
  --var outbound_network_name=NatNetwork

echo
echo
echo "===> Adding Network Routes (sudo is required) ===="
echo

if [ `uname` = "Darwin" ]; then
  sudo route add -net 10.244.0.0/16 192.168.50.6
elif [ `uname` = "Linux" ]; then
  if type ip > /dev/null 2>&1; then
    sudo ip route add 10.244.0.0/16 via 192.168.50.6
  elif type route > /dev/null 2>&1; then
    sudo route add -net 10.244.0.0/16 gw  192.168.50.6
  else
    echo "ERROR adding route"
    exit 1
  fi
fi


echo
echo
echo "===> Generating .envrc"
echo

cat > .envrc <<"EOF"
export BOSH_ENVIRONMENT=vbox
export BOSH_CA_CERT=$( bosh interpolate creds.yml --path /director_ssl/ca )
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=$( bosh interpolate creds.yml --path /admin_password )
EOF

source .envrc

echo Succeeded


echo
echo
echo "===> Configuring Environment Alias"
echo

bosh \
  --environment 192.168.50.6 \
  --ca-cert <( bosh interpolate creds.yml --path /director_ssl/ca ) \
  alias-env vbox


echo
echo
echo "===> Updating Cloud Config"
echo

bosh -n update-cloud-config bosh-deployment/warden/cloud-config.yml \
  > /dev/null

echo Succeeded

echo
echo
echo "===> Completed"
echo

echo "Credentials for your environment have been generated and stored in creds.yml."
echo "Details about the state of your VM have been stored in state.json."
echo "You should keep these files for future updates and to destroy your environment."
echo
echo "BOSH Director is now running. You may need to run the following before using"
echo "bosh commands."
echo
echo "    source .envrc"
echo

if which direnv > /dev/null 2>&1; then
  echo "Alternatively, run `direnv allow` to automatically load your .envrc settings."
  echo
fi
