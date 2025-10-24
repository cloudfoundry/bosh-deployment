#!/bin/bash -ex

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
URL=$(cat stemcell/url)
SHA1=$(cat stemcell/sha1)

pushd "${PWD}/bbl-state"
  set +x
  eval "$(bbl print-env)"
  set -x

  bosh upload-stemcell --sha1 "$SHA1" "$URL"

  echo "-----> `date`: Deploy"
  bosh -n -d zookeeper deploy "${script_dir}/../assets/zookeeper.yml" \
    -o bosh-deployment/tests/cred-test.yml

  echo "-----> `date`: Exercise deployment"
  bosh -n -d zookeeper run-errand smoke-tests

  echo "-----> `date`: Exercise deployment"
  bosh -n -d zookeeper recreate

  echo "-----> `date`: Clean up disks, etc."
  bosh -n -d zookeeper delete-deployment

  echo "-----> `date`: Clean up disks, etc."
  bosh -n clean-up --all
popd
