#!/bin/bash

set -euxo pipefail

. $(dirname $0)/utils.sh

URL=$(cat stemcell/url)
SHA=$(cat stemcell/sha1)
VERSION=$(cat stemcell/version)

git clone bosh-deployment bosh-deployment-output

UPDATE_STEMCELL_OPSFILE=$(make_stemcell_opsfile $URL $SHA)

bosh int bosh-deployment/${CPI_OPS_FILE} -o $UPDATE_STEMCELL_OPSFILE > bosh-deployment-output/${CPI_OPS_FILE}

pushd $PWD/bosh-deployment-output
  git_commit "Bumping Stemcell $STEMCELL_NAME to version $VERSION"
popd
