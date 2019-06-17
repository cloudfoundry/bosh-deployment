#!/bin/bash

set -euxo pipefail

. $(dirname $0)/utils.sh

URL=$(cat cpi/url)
SHA=$(cat cpi/sha1)
VERSION=$(cat cpi/version)

git clone bosh-deployment bosh-deployment-output

UPDATE_CPI_OPS_FILE=$(make_cpi_opsfile $CPI_NAME $VERSION $URL $SHA)

bosh int bosh-deployment/${CPI_OPS_FILE} -o $UPDATE_CPI_OPS_FILE > bosh-deployment-output/${CPI_OPS_FILE}

pushd $PWD/bosh-deployment-output
  git_commit "Bumping CPI $CPI_NAME to version $VERSION"
popd
