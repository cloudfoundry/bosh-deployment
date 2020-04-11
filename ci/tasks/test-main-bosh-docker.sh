#!/bin/bash

set -eu

rm -rf "/usr/local/bosh-deployment"
cp -r "${PWD}/bosh-deployment" "/usr/local/bosh-deployment"

. start-bosh
. /tmp/local-bosh/director/env

bosh upload-stemcell --sha1 35297b197426db1c9ead4d66afff47dab63a26ab \
  "https://bosh.io/d/stemcells/bosh-warden-boshlite-ubuntu-xenial-go_agent?v=315.41"

echo "-----> `date`: Deploy"
bosh -n -d zookeeper deploy <(wget -O- https://raw.githubusercontent.com/cppforlife/zookeeper-release/master/manifests/zookeeper.yml)

echo "-----> `date`: Exercise deployment"
bosh -n -d zookeeper run-errand smoke-tests

echo "-----> `date`: Exercise deployment"
bosh -n -d zookeeper recreate

echo "-----> `date`: Clean up disks, etc."
bosh -n -d zookeeper clean-up --all
