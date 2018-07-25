#!/bin/bash -ex

delete_deployment() {
  echo "-----> `date`: Delete deployment"
  set +e
  bosh -n -d zookeeper delete-deployment
  set -e
}

bbl_down() {
  set +e
  bbl --debug down
  set -e
}

clean_up() {
  delete_deployment
  bbl_down
}

mkdir bbl-state
pushd bbl-state
  bbl plan
  rm -rf bosh-deployment
  cp -rfp ../bosh-deployment .
  bbl --debug up

  trap "clean_up" EXIT

  set +x
  eval "$(bbl print-env)"
  set -x

  bosh -n upload-stemcell --sha1 9c8676e1606d9b7135560547bed1d32aee4bb175 \
    "https://bosh.io/d/stemcells/bosh-google-kvm-ubuntu-trusty-go_agent?v=3586.26"

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
