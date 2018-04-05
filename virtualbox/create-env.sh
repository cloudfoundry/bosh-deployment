#!/bin/bash

set -eu

STEP() { echo ; echo ; echo "==\\" ; echo "===>" "$@" ; echo "==/" ; echo ; }


if [ ! -e bosh-deployment ]; then
  ####
  STEP "Cloning cloudfoundry/bosh-deployment"
  ####

  if [ -e virtualbox/create-env.sh ] || [ -e ../virtualbox/create-env.sh ]; then
    echo "It looks like you are running this within the bosh-deployment repository."
    echo "To avoid secrets ending up in this repo, run this from your parent directory."
    echo

    exit 1
  fi

  git clone https://github.com/cloudfoundry/bosh-deployment.git

  echo
fi


####
STEP "Creating BOSH Director"
####

bosh create-env bosh-deployment/bosh.yml \
  --state state.json \
  --ops-file bosh-deployment/virtualbox/cpi.yml \
  --ops-file bosh-deployment/virtualbox/outbound-network.yml \
  --ops-file bosh-deployment/bosh-lite.yml \
  --ops-file bosh-deployment/bosh-lite-runc.yml \
  --ops-file bosh-deployment/uaa.yml \
  --ops-file bosh-deployment/credhub.yml \
  --ops-file bosh-deployment/jumpbox-user.yml \
  --vars-store creds.yml \
  --var director_name=bosh-lite \
  --var internal_ip=192.168.50.6 \
  --var internal_gw=192.168.50.1 \
  --var internal_cidr=192.168.50.0/24 \
  --var outbound_network_name=NatNetwork


####
STEP "Adding Network Routes (sudo is required)"
####

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


####
STEP "Generating .envrc"
####

cat > .envrc <<"EOF"
export BOSH_ENVIRONMENT=vbox
export BOSH_CA_CERT=$( bosh interpolate creds.yml --path /director_ssl/ca )
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=$( bosh interpolate creds.yml --path /admin_password )

export CREDHUB_SERVER=https://192.168.50.6:8844
export CREDHUB_CA_CERT="$( bosh interpolate creds.yml --path=/credhub_tls/ca )
$( bosh interpolate creds.yml --path=/uaa_ssl/ca )"
export CREDHUB_CLIENT=credhub-admin
export CREDHUB_SECRET=$( bosh interpolate creds.yml --path=/credhub_admin_client_secret )
EOF

source .envrc

echo Succeeded


####
STEP "Configuring Environment Alias"
####

bosh \
  --environment 192.168.50.6 \
  --ca-cert <( bosh interpolate creds.yml --path /director_ssl/ca ) \
  alias-env vbox


####
STEP "Updating Cloud Config"
####

bosh -n update-cloud-config bosh-deployment/warden/cloud-config.yml \
  > /dev/null

echo Succeeded


####
STEP "Completed"
####

echo "Credentials for your environment have been generated and stored in creds.yml."
echo "Details about the state of your VM have been stored in state.json."
echo "You should keep these files for future updates and to destroy your environment."
echo
echo "BOSH Director is now running. You may need to run the following before using bosh commands:"
echo
echo "    source .envrc"
echo
