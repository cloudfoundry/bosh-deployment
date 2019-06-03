#!/bin/bash

set -euxo pipefail

URL=$(cat cpi/url)
SHA=$(cat cpi/sha1)
VERSION=$(cat cpi/version)

UPDATE_CPI_OPS_FILE=update-cpi-ops.yml

ls -al

git clone bosh-deployment bosh-deployment-output

cat << EOF > $UPDATE_CPI_OPS_FILE
---
- type: replace
  path: /name=cpi/value
  value:
    name: ${CPI_NAME}
    sha1: ${SHA}
    url: ${URL}
    version: ${VERSION}
EOF

bosh int bosh-deployment/${CPI_OPS_FILE} -o update-cpi-ops.yml > bosh-deployment-output/${CPI_OPS_FILE}

pushd $PWD/bosh-deployment-output
  git diff | cat
  git add -A
  git config --global user.email "ci@localhost"
  git config --global user.name "CI Bot"
  git commit -m "Bumping CPI $CPI_NAME to version $VERSION"
popd
