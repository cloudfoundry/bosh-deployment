#!/bin/bash

set -eu

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
bosh_deployment="${PWD}/bosh-deployment"
rm -rf "/usr/local/bosh-deployment"
cp -r "${PWD}/bosh-deployment" "/usr/local/bosh-deployment"

. start-bosh -o ${bosh_deployment}/uaa.yml \
  -o ${bosh_deployment}/credhub.yml
. /tmp/local-bosh/director/env

URL=$(cat stemcell/url)
SHA1=$(cat stemcell/sha1)

bosh upload-stemcell --sha1 "$SHA1" "$URL"

bosh -n update-runtime-config "${bosh_deployment}/runtime-configs/dns.yml"

echo "-----> `date`: Deploy"
bosh -n -d zookeeper deploy "${script_dir}/../assets/zookeeper.yml"

echo "-----> `date`: Exercise deployment"
bosh -n -d zookeeper run-errand smoke-tests

echo "-----> `date`: Exercise deployment"
bosh -n -d zookeeper recreate

echo "-----> `date`: Clean up disks, etc."
bosh -n -d zookeeper clean-up --all
