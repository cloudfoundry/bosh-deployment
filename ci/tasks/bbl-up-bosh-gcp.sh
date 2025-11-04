#!/bin/bash -ex

bbl_up() {
  bbl plan
  rm -rf bosh-deployment
  cp -rfp "${bosh_deployment}" .

  cp -R "${bosh_deployment}/plan-patches/spot-gcp/*" .

  bbl --debug up
}

bosh_deployment="$PWD/bosh-deployment"

pushd "${PWD}/bbl-state"
  bbl_up
popd
