#!/bin/bash -eux

. $(dirname $0)/utils.sh

tar -xzf release/*.tgz $(tar -tzf release/*.tgz | grep 'release.MF')
RELEASE_NAME="$(bosh int release.MF --path /name)"
VERSION="$(bosh int release.MF --path /version)"
SHA="$(sha1sum release/*.tgz | cut -d' ' -f1)"

git clone bosh-deployment bosh-deployment-output

if [[ `grep compiled_packages release.MF` ]]; then
  TARBALL_NAME="$(basename release/*.tgz)"
  URL="https://s3.amazonaws.com/bosh-compiled-release-tarballs/${TARBALL_NAME}"
else
  URL="https://bosh.io/d/github.com/${BOSH_IO_RELEASE}?v=${VERSION}"
  test_bosh_io_release_exists $URL
fi

if [[ $UPDATING_BASE_MANIFEST == "true" ]]; then
  UPDATE_RELEASE_OPSFILE=$(make_base_manifest_release_opsfile $RELEASE_NAME $VERSION $URL $SHA)
else
  UPDATE_RELEASE_OPSFILE=$(make_release_opsfile $RELEASE_NAME $VERSION $URL $SHA)
fi

bosh int bosh-deployment/${FILE_TO_UPDATE} -o $UPDATE_RELEASE_OPSFILE > bosh-deployment-output/${FILE_TO_UPDATE}

pushd $PWD/bosh-deployment-output
  git_commit "Bumping $RELEASE_NAME to version $VERSION"
popd
