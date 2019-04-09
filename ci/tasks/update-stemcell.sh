#!/bin/bash

set -euxo pipefail

URL=$(cat stemcell/url)
SHA=$(cat stemcell/sha1)
VERSION=$(cat stemcell/version)

UPDATE_STEMCELL_OPS_FILE=update-stemcell-ops.yml

ls -al

git clone bosh-deployment bosh-deployment-output

cat << EOF > $UPDATE_STEMCELL_OPS_FILE
---
- type: replace
  path: /name=stemcell/value
  value:
    sha1: ${SHA}
    url: ${URL}
EOF

bosh int bosh-deployment/${CPI_OPS_FILE} -o update-stemcell-ops.yml > bosh-deployment-output/${CPI_OPS_FILE}

pushd $PWD/bosh-deployment-output
  git diff | cat
  git add -A
  git config --global user.email "ci@localhost"
  git config --global user.name "CI Bot"
  git commit -m "Bumping Stemcell $STEMCELL_NAME to version $VERSION"
popd
