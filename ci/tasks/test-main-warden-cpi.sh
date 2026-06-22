#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${DEBUG-}" ]]; then
  set -x
fi

bosh_deployment="${PWD}/bosh-deployment"

rm -rf "/usr/local/bosh-deployment"
cp -r "${PWD}/bosh-deployment" "/usr/local/bosh-deployment"

export USE_LOCAL_RELEASES=false

# shellcheck source=/dev/null
source start-bosh
# shellcheck source=/dev/null
source /tmp/local-bosh/director/env

URL=$(cat stemcell/url)
SHA1=$(cat stemcell/sha1)

bosh upload-stemcell --sha1 "$SHA1" "$URL"

bosh -n update-runtime-config "${bosh_deployment}/runtime-configs/dns.yml" \
  --ops-file "${bosh_deployment}/warden/noble-dns.yml"

echo "-----> $(date): Deploy"
bosh -n -d zookeeper deploy "${bosh_deployment}/ci/assets/zookeeper.yml"

echo "-----> $(date): Exercise deployment"
bosh -n -d zookeeper run-errand smoke-tests

echo "-----> $(date): Exercise deployment"
bosh -n -d zookeeper recreate

echo "-----> $(date): Clean up disks, etc."
bosh -n -d zookeeper clean-up --all
