#!/bin/bash -ex

bbl_down() {
  pushd ${BUILD_DIR}/bbl-state
    bbl --debug down --no-confirm
  popd
}

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

export BUILD_DIR=$PWD

bosh_deployment="$PWD/bosh-deployment"

mkdir bbl-state
pushd bbl-state
  bbl_up

  trap "bbl_down" EXIT

  set +x
  eval "$(bbl print-env)"
  set -x

  bosh upload-stemcell --sha1 69163bcf21ae6d5ffeb92f099644d295b289b63e \
    "https://bosh.io/d/stemcells/bosh-warden-boshlite-ubuntu-trusty-go_agent?v=3586.36"

  echo "-----> `date`: Deploy"
  bosh -n -d zookeeper deploy <(wget -O- https://raw.githubusercontent.com/cppforlife/zookeeper-release/master/manifests/zookeeper.yml) \
    -o bosh-deployment/tests/cred-test.yml

  echo "-----> `date`: Exercise deployment"
  bosh -n -d zookeeper run-errand smoke-tests

  echo "-----> `date`: Exercise deployment"
  bosh -n -d zookeeper recreate

  echo "-----> `date`: Clean up disks, etc."
  bosh -n -d zookeeper clean-up --all
popd
