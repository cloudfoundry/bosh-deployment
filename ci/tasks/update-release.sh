#!/bin/bash -eux

. $(dirname $0)/utils.sh

tar -xzf compiled-release/*.tgz "./release.MF"

RELEASE_NAME="$( bosh int release.MF --path /name )"
VERSION="$( bosh int release.MF --path /version )"
TARBALL_NAME="$(basename compiled-release/*.tgz)"
SHA1="$(sha1sum compiled-release/*.tgz | cut -d' ' -f1)"
URL="https://s3.amazonaws.com/bosh-compiled-release-tarballs/${TARBALL_NAME}"

if [[ $UPDATING_OPS_FILE == "true" ]]; then
  UPDATE_RELEASE_OPSFILE=$(make_release_opsfile $RELEASE_NAME $VERSION $URL $SHA1)
else
  UPDATE_RELEASE_OPSFILE=$(make_base_manifest_release_opsfile $RELEASE_NAME $VERSION $URL $SHA1)
fi

git clone bosh-deployment bosh-deployment-output

bosh int bosh-deployment/${FILE_TO_UPDATE} -o $UPDATE_RELEASE_OPSFILE > bosh-deployment-output/${FILE_TO_UPDATE}

pushd $PWD/bosh-deployment-output
  git_commit "Bumping $RELEASE_NAME to version $VERSION"
popd
