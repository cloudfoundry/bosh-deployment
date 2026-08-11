#!/bin/bash -ex

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
URL=$(cat stemcell/url)
SHA1=$(cat stemcell/sha1)

pushd "${PWD}/bbl-state"
  set +x
  eval "$(bbl print-env)"
  set -x

  bosh upload-stemcell --sha1 "$SHA1" "$URL"

  # bbl applies its own runtime config named "dns", built from the bosh-deployment
  # revision vendored into bbl. That revision predates newer stemcells, so bosh-dns
  # is not installed on them. Re-apply this repo's dns.yml under the same name to
  # replace it -- the nats deployment needs bosh-dns to resolve its DNS aliases.
  bosh -n update-runtime-config --name dns "${script_dir}/../../runtime-configs/dns.yml"

  echo "-----> `date`: Deploy"
  bosh -n -d nats deploy "${script_dir}/../assets/nats.yml" \
    -o bosh-deployment/tests/cred-test.yml \
    -v stemcell_os="${STEMCELL_OS}"

  echo "-----> `date`: Exercise deployment"
  bosh -n -d nats run-errand smoke-tests

  echo "-----> `date`: Exercise deployment"
  bosh -n -d nats recreate

  echo "-----> `date`: Clean up disks, etc."
  bosh -n -d nats delete-deployment

  echo "-----> `date`: Clean up disks, etc."
  bosh -n clean-up --all
popd
