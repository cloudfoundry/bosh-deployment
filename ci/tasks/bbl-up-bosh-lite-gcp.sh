#!/bin/bash -ex

bbl_up() {
  bbl plan
  rm -rf bosh-deployment
  cp -rfp "${bosh_deployment}" .
  cp "${bosh_deployment}/ci/assets/bosh-lite-gcp/create-director.sh" ./create-director.sh

  rm cloud-config/*
  cp "${bosh_deployment}/warden/cloud-config.yml" cloud-config/cloud-config.yml
  touch cloud-config/ops.yml
  bbl --debug up
}

bosh_deployment="$PWD/bosh-deployment"

pushd "${PWD}/bbl-state"
  bbl_up
popd
