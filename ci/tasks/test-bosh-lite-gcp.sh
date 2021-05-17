#!/bin/bash -ex

URL=$(cat stemcell/url)
SHA1=$(cat stemcell/sha1)

pushd "${PWD}/bbl-state"
  set +x
  eval "$(bbl print-env)"
  set -x

  bosh upload-stemcell --sha1 "$SHA1" "$URL"

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
