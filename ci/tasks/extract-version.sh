#!/bin/bash
set -e

git clone bosh-deployment bosh-deployment-output

tar -xzf compiled-release/*.tgz $( tar -tzf compiled-release/*.tgz | grep 'release.MF' )
RELEASE_NAME=$( grep -E '^name: ' release.MF | awk '{print $2}' | tr -d "\"'" )
# ''"
RELEASE_VERSION=$( grep -E '^version: ' release.MF | awk '{print $2}' | tr -d "\"'" )
# ''"
SHA=($(sha1sum compiled-release/*.tgz))
URL="https://s3.amazonaws.com/bosh-compiled-release-tarballs/${SHA[1]}"

VERSION_FILE=bosh-deployment-output/ci/intermediate-vars/${RELEASE_NAME}-vars.yml

cat << EOF > $VERSION_FILE
---
- name: $RELEASE_NAME
  version: $RELEASE_VERSION
  url: $URL
  sha: ${SHA[0]}
EOF

pushd $PWD/bosh-deployment-output
  git diff
  git add -A
  git config --global user.email "ci@localhost"
  git config --global user.name "CI Bot"
  git commit -m "Bumping ${RELEASE_NAME} to version ${RELEASE_VERSION}"
popd
