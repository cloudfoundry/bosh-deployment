#!/bin/bash -eux

tar -xzf compiled-release/*.tgz "./release.MF"

RELEASE_NAME="$( bosh int release.MF --path /name )"
VERSION="$( bosh int release.MF --path /version )"
TARBALL_NAME="$(basename compiled-release/*.tgz)"
SHA1="$(sha1sum compiled-release/*.tgz | cut -d' ' -f1)"
URL="https://s3.amazonaws.com/bosh-compiled-release-tarballs/${TARBALL_NAME}"

UPDATE_RELEASE_OPS_FILE=update-release-ops.yml

if [[ $UPDATING_OPS_FILE == "true" ]]; then

cat << EOF > $UPDATE_RELEASE_OPS_FILE
---
- type: replace
  path: /release=${RELEASE_NAME}/value
  value:
    name: ${RELEASE_NAME}
    version: ${VERSION}
    url: ${URL}
    sha1: ${SHA1}
EOF

else

cat << EOF > $UPDATE_RELEASE_OPS_FILE
---
- type: replace
  path: /releases/name=${RELEASE_NAME}
  value:
    sha1: ${SHA1}
    url: ${URL}
    version: ${VERSION}
    name: ${RELEASE_NAME}
EOF

fi

git clone bosh-deployment bosh-deployment-output

TMP=$(mktemp)
bosh int bosh-deployment/${FILE_TO_UPDATE} -o update-release-ops.yml > $TMP
mv $TMP bosh-deployment-output/${FILE_TO_UPDATE}

pushd $PWD/bosh-deployment-output
  git diff
  git add -A
  git config --global user.email "ci@localhost"
  git config --global user.name "CI Bot"
  git commit -m "Bumping $RELEASE_NAME to version $VERSION"
popd
